import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State {
        case idle, recording, processing, needsConfig
    }

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var providerMenuItem: NSMenuItem!
    private var languageMenu: NSMenu!
    private var activeLanguage: String? // nil = auto-detect
    private var microphoneMenuItem: NSMenuItem!
    private var microphoneMenu: NSMenu!
    /// Which mic to record from. Unlike the language/translate settings this is
    /// sticky: it survives quitting and is not re-seeded from config.json.
    private var micChoice: MicChoice = .systemDefault
    private var translateMenuItem: NSMenuItem!
    private var translateToEnglish = false
    private var hotKey: HotKey?
    private var fnMonitor: ModifierKeyMonitor?
    private let recorder = AudioRecorder()
    private let whisperServer = WhisperServer()
    private var config: Config?
    private var state: State = .idle
    private var fnHeld = false
    private var recordingStartedAt: Date?
    /// A message to show once the current dictation has been pasted, so it isn't
    /// wiped by the status updates the pipeline makes on its way there.
    private var pendingWarning: String?
    private let workQueue = DispatchQueue(label: "com.example.talk.work")

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        loadConfig(promptForPermissions: true)
        registerHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        whisperServer.stop()
    }

    // MARK: - Configuration

    private func loadConfig(promptForPermissions: Bool) {
        do {
            let loaded = try Config.load()
            config = loaded
            state = .idle
            if promptForPermissions {
                recorder.requestPermission { _ in }
                Paster.ensureAccessibility()
            }
        } catch {
            config = nil
            state = .needsConfig
        }
        updateUI()
        refreshProviderItem()

        // Start (or stop) the app-managed local Whisper server to match the provider.
        if let config = config, config.provider == "local" {
            whisperServer.ensureRunning(config: config)
        } else {
            whisperServer.stop()
        }

        // The microphone is deliberately NOT reset the way language/translate are
        // below: it is the user's sticky choice, and config.json only seeds it
        // while nothing has ever been picked from the menu.
        micChoice = resolveMicrophone()
        rebuildMicrophoneMenu()
        primeRecorder()

        // Reset the active dictation language / translate mode to the configured defaults.
        activeLanguage = config?.language
        updateLanguageChecks()
        translateToEnglish = config?.translate ?? false
        updateTranslateCheck()
    }

    private func registerHotKey() {
        hotKey = nil
        fnMonitor = nil

        // Default to the fn key (also used in the needs-config state so the
        // user can press it to get help).
        let useFn = config?.useFnKey ?? true
        if useFn {
            let keys = config?.pushToTalkKeys ?? ["fn", "control"]
            fnMonitor = ModifierKeyMonitor(
                keyNames: keys,
                onPress: { [weak self] in DispatchQueue.main.async { self?.handleFnDown() } },
                onRelease: { [weak self] in DispatchQueue.main.async { self?.handleFnUp() } }
            )
        } else if let config = config {
            hotKey = HotKey(keyCode: config.hotKeyKeyCode, modifiers: config.hotKeyModifiers) { [weak self] in
                DispatchQueue.main.async { self?.handleHotKey() }
            }
            if hotKey == nil {
                notify("could not register hotkey (it may be in use)")
            }
        }
    }

    // MARK: - fn key (push-to-talk)

    private func handleFnDown() {
        fnHeld = true
        switch state {
        case .needsConfig: showConfigHelp()
        case .idle: startRecording(pushToTalk: true)
        case .recording, .processing: break
        }
    }

    private func handleFnUp() {
        fnHeld = false
        guard state == .recording else { return }
        guard let recording = recorder.stop() else {
            state = .idle
            updateUI()
            return
        }
        // Ignore accidental quick taps.
        let elapsed = Date().timeIntervalSince(recordingStartedAt ?? Date())
        if elapsed < 0.4 {
            try? FileManager.default.removeItem(at: recording.url)
            state = .idle
            updateUI()
            return
        }
        process(recording)
        primeRecorder()
    }

    // MARK: - Carbon hotkey (toggle)

    private func handleHotKey() {
        switch state {
        case .needsConfig:
            showConfigHelp()
        case .idle:
            startRecording()
        case .recording:
            guard let recording = recorder.stop() else {
                state = .idle
                updateUI()
                return
            }
            process(recording)
            primeRecorder()
        case .processing:
            NSSound.beep() // busy — ignore
        }
    }

    // MARK: - Pipeline

    /// Phrases Whisper commonly hallucinates on silence/near-silence.
    private static let silenceArtifacts: Set<String> = [
        "you", "thank you", "thanks", "thank you very much", "thank you so much",
        "thanks for watching", "thank you for watching", "please subscribe",
        "subscribe", "bye", "goodbye", "see you next time",
    ]

    private static func isSilenceArtifact(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.,!?-\""))
        return silenceArtifacts.contains(normalized)
    }

    /// Telltale phrases of a cleanup model that replied conversationally instead
    /// of cleaning the transcript.
    private static let metaPhrases = [
        "speech-to-text", "transcript", "clean it up", "clean up",
        "go ahead", "i'm ready", "i am ready", "ready to clean",
        "ready to help", "paste the", "share your", "i'll clean", "i will clean",
        "provide the", "happy to help",
    ]

    /// True if `cleaned` looks like an assistant reply rather than a cleaned
    /// transcript. The raw-transcript fallback makes false positives harmless.
    private static func looksLikeMetaResponse(_ cleaned: String, original: String) -> Bool {
        let suspiciousLength = cleaned.count > original.count * 2 + 40
        let trivialOriginal = original.count < 30
        let lower = cleaned.lowercased()
        let containsMeta = metaPhrases.contains { lower.contains($0) }
        return suspiciousLength || (trivialOriginal && containsMeta)
    }

    private func startRecording(pushToTalk: Bool = false) {
        recorder.requestPermission { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.notify("microphone access denied (enable in System Settings)")
                return
            }
            // If the fn key was released before permission resolved, abort.
            if pushToTalk, !self.fnHeld { return }
            // Resolve the choice now rather than trusting what the menu last saw:
            // this is the only moment that matters, and it is one cheap lookup.
            self.micChoice = self.resolveMicrophone()
            switch self.recorder.start(deviceUID: self.micChoice.deviceUID) {
            case .started:
                break
            case .deviceUnavailable:
                // Deliberately no fallback to the system default: quietly
                // recording from whatever macOS switched to is the exact thing
                // pinning a microphone exists to prevent.
                self.notify("\(self.micChoice.displayName) is not connected — pick a mic in the menu")
                return
            case .failed:
                self.notify("could not start recording")
                return
            }
            self.state = .recording
            self.recordingStartedAt = Date()
            self.updateUI()
        }
    }

    private func process(_ recording: AudioRecorder.Recording) {
        let url = recording.url
        guard let config = config else {
            try? FileManager.default.removeItem(at: url)
            state = .idle
            updateUI()
            return
        }
        // Nothing arrived from the microphone at all — a revoked permission or a
        // device that stopped delivering, which is not the same as silence.
        guard recording.duration > 0 else {
            try? FileManager.default.removeItem(at: url)
            state = .idle
            updateUI()
            notify("no audio captured — check microphone access and the chosen mic")
            return
        }
        if recording.deviceChanged {
            pendingWarning = "the microphone changed mid-recording (device disconnected)"
        }
        state = .processing
        updateUI()

        // Captured on the main thread before going to the background queue.
        let language = activeLanguage
        let translate = translateToEnglish
        // The vocabulary prompt is English; apply it only for plain English dictation.
        let prompt = (!translate && language == "en") ? config.transcriptionPrompt : nil

        workQueue.async { [weak self] in
            guard let self = self else { return }
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                var text = try Transcriber(config: config).transcribe(url, language: language, prompt: prompt, translate: translate)
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)

                // Treat empty / punctuation-only output, or a known Whisper
                // silence hallucination ("You", "Thank you", …), as no speech.
                let hasSpeech = text.contains { $0.isLetter || $0.isNumber }
                if !hasSpeech || Self.isSilenceArtifact(text) {
                    DispatchQueue.main.async { self.finish(with: "") }
                    return
                }

                if config.cleanup, let cleaned = try? Cleaner(config: config).clean(text) {
                    let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        if Self.looksLikeMetaResponse(trimmed, original: text) {
                            // The cleanup model replied conversationally instead of
                            // cleaning — happens on content-free audio. If the input
                            // was trivial, treat it as no speech; otherwise fall back
                            // to the raw transcript.
                            if text.count < 30 {
                                DispatchQueue.main.async { self.finish(with: "") }
                                return
                            }
                        } else {
                            text = trimmed
                        }
                    }
                }
                let result = text
                DispatchQueue.main.async { self.finish(with: result) }
            } catch {
                let message = (error as? TalkError)?.description ?? error.localizedDescription
                DispatchQueue.main.async { self.finish(error: message) }
            }
        }
    }

    private func finish(with text: String) {
        state = .idle
        updateUI()
        let warning = pendingWarning
        pendingWarning = nil
        guard !text.isEmpty else {
            notify(warning ?? "no speech detected")
            return
        }
        if !Paster.paste(text) {
            // Text is on the clipboard, but auto-typing is blocked.
            notify("copied to clipboard — grant Accessibility to auto-type (⌘V to paste)")
            Paster.ensureAccessibility() // re-prompt / open Settings
        } else if let warning = warning {
            notify(warning)
        }
    }

    private func finish(error message: String) {
        state = .idle
        updateUI()
        pendingWarning = nil
        notify(String(message.prefix(120)))
    }

    // MARK: - Status item & menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        statusMenuItem = NSMenuItem(title: "Talk", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        providerMenuItem = NSMenuItem(title: "Source: —", action: nil, keyEquivalent: "")
        providerMenuItem.isEnabled = false
        menu.addItem(providerMenuItem)

        menu.addItem(.separator())

        // Microphone picker. Unlike Language below, this choice is remembered
        // across launches and pins Talk to that device even when macOS moves its
        // own input elsewhere (AirPods connecting, a USB interface waking up).
        // Populated in rebuildMicrophoneMenu(), which runs each time the menu opens.
        microphoneMenu = NSMenu()
        microphoneMenuItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneMenuItem.submenu = microphoneMenu
        menu.addItem(microphoneMenuItem)

        // Language picker (applies to the next dictation onward).
        languageMenu = NSMenu()
        let languageOptions: [(String, String)] = [
            ("English", "en"),
            ("Armenian", "hy"),
            ("Auto-detect", "auto"),
        ]
        for (name, code) in languageOptions {
            let item = NSMenuItem(title: name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            languageMenu.addItem(item)
        }
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        translateMenuItem = NSMenuItem(title: "Translate to English", action: #selector(toggleTranslate), keyEquivalent: "")
        translateMenuItem.target = self
        menu.addItem(translateMenuItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open config file…", action: #selector(openConfig), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let reloadItem = NSMenuItem(title: "Reload config", action: #selector(reloadConfig), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Talk", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Human-readable list of push-to-talk keys, e.g. "fn or control".
    private func pushToTalkLabel() -> String {
        let display: [String: String] = [
            "fn": "fn", "function": "fn", "globe": "fn",
            "control": "control", "ctrl": "control",
            "option": "option", "alt": "option",
            "command": "command", "cmd": "command", "shift": "shift",
        ]
        let names = (config?.pushToTalkKeys ?? ["fn", "control"])
            .map { display[$0.lowercased()] ?? $0 }
        // De-duplicate while preserving order (fn/globe collapse to one).
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.isEmpty ? "fn" : unique.joined(separator: " or ")
    }

    private func updateUI() {
        let useFn = config?.useFnKey ?? true
        let keyLabel = pushToTalkLabel()
        let symbol: String
        let tint: NSColor?
        let title: String

        switch state {
        case .idle:
            symbol = "mic"; tint = nil
            title = useFn ? "Talk — ready (hold \(keyLabel) and talk)" : "Talk — ready (press hotkey to dictate)"
        case .recording:
            symbol = "mic.fill"; tint = .systemRed
            title = useFn ? "Talk — recording… (release \(keyLabel))" : "Talk — recording… (press hotkey to stop)"
        case .processing:
            symbol = "waveform"; tint = .systemBlue
            title = "Talk — transcribing…"
        case .needsConfig:
            symbol = "exclamationmark.triangle"; tint = .systemOrange
            title = "Talk — needs an API key (see menu)"
        }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Talk")
            button.image?.isTemplate = (tint == nil)
            button.contentTintColor = tint
        }
        statusMenuItem.title = title
    }

    // MARK: - Provider indicator

    func menuWillOpen(_ menu: NSMenu) {
        refreshProviderItem()
        // Devices come and go constantly (AirPods, USB interfaces, meeting apps'
        // virtual mics), so the list is rebuilt every time the menu is shown.
        // That is also why Talk needs no CoreAudio device-change listener.
        rebuildMicrophoneMenu()
    }

    private func refreshProviderItem() {
        guard let config = config else {
            providerMenuItem.title = "Source: not configured"
            return
        }
        let cleanup = config.cleanup ? "Cleanup: Claude" : "Cleanup: off"
        let translate = translateToEnglish ? "  ·  Translate→EN" : ""
        switch config.provider {
        case "local":
            providerMenuItem.title = "Source: Local Whisper (checking…)  ·  \(cleanup)\(translate)"
            checkLocalServer { [weak self] running in
                let state = running ? "running" : "NOT running — start the server"
                self?.providerMenuItem.title = "Source: Local Whisper (\(state))  ·  \(cleanup)\(translate)"
            }
        case "openai":
            providerMenuItem.title = "Source: OpenAI (cloud)  ·  \(cleanup)\(translate)"
        default:
            providerMenuItem.title = "Source: Groq (cloud)  ·  \(cleanup)\(translate)"
        }
    }

    /// Pings the local transcription server's root URL with a short timeout.
    private func checkLocalServer(_ completion: @escaping (Bool) -> Void) {
        guard let config = config,
              var components = URLComponents(url: config.transcriptionEndpoint, resolvingAgainstBaseURL: false)
        else { completion(false); return }
        components.path = "/"
        components.query = nil
        guard let url = components.url else { completion(false); return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: request) { _, response, error in
            let running = (error == nil) && (response != nil)
            DispatchQueue.main.async { completion(running) }
        }.resume()
    }

    /// Shows a transient message in the menu, then restores the normal status.
    /// The icon goes orange for the same four seconds — the menu title alone is
    /// invisible during push-to-talk, when nobody has the menu open.
    private func notify(_ message: String) {
        let shown = "Talk — \(message)"
        statusMenuItem.title = shown
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                   accessibilityDescription: "Talk")
            button.image?.isTemplate = false
            button.contentTintColor = .systemOrange
        }
        NSSound.beep()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self else { return }
            if self.statusMenuItem.title == shown { self.updateUI() }
        }
    }

    private func showConfigHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Talk needs an API key"
        alert.informativeText = """
        Create the file:
          ~/.talk/config.json

        with at least a transcription key, e.g.:

        {
          "provider": "groq",
          "groqApiKey": "gsk_…",
          "anthropicApiKey": "sk-ant-…"
        }

        Then choose “Reload config” from the Talk menu.
        """
        alert.addButton(withTitle: "Open config file…")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            openConfig()
        }
    }

    // MARK: - Microphone

    /// Precedence: a mic picked from the menu (~/.talk/state.json) always wins,
    /// config.json's "microphone" seeds it for anyone who never touched the menu,
    /// and otherwise Talk follows the system input. The seed is matched afresh
    /// every time and never written to state.json, so naming a device that is
    /// currently disconnected still works once it comes back.
    private func resolveMicrophone() -> MicChoice {
        if let saved = AppState.load().microphone { return saved }
        guard let seed = config?.microphone else { return .systemDefault }
        if seed.caseInsensitiveCompare(MicChoice.systemToken) == .orderedSame { return .systemDefault }
        guard let device = AudioDevices.device(matching: seed) else {
            return .pinned(uid: seed, name: seed) // shown as "(not connected)"
        }
        return .pinned(uid: device.uid, name: device.name)
    }

    private func rebuildMicrophoneMenu() {
        guard microphoneMenu != nil else { return }
        microphoneMenu.removeAllItems()

        // Name the device "System default" currently resolves to, so what
        // following macOS actually means right now is visible without leaving
        // the menu.
        let current = AudioDevices.defaultInput()?.name ?? "none"
        let systemItem = NSMenuItem(title: "System default (\(current))",
                                    action: #selector(selectMicrophone(_:)), keyEquivalent: "")
        systemItem.target = self
        systemItem.representedObject = MicChoice.systemDefault
        microphoneMenu.addItem(systemItem)
        microphoneMenu.addItem(.separator())

        let devices = AudioDevices.inputs()
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = MicChoice.pinned(uid: device.uid, name: device.name)
            // The UID tells apart two devices sharing a name, and is the string
            // "microphone" in config.json accepts.
            item.toolTip = device.isBluetooth
                ? "\(device.uid)\nBluetooth — recording drops playback to call quality while it runs."
                : device.uid
            microphoneMenu.addItem(item)
        }

        // A pinned device that isn't here right now keeps its row, checked and
        // clickable. Greying it out would read as "your choice was lost" and
        // hiding it as "the pin silently reverted" — both are the worry pinning
        // exists to remove.
        if case .pinned(let uid, let name) = micChoice, !devices.contains(where: { $0.uid == uid }) {
            let item = NSMenuItem(title: "\(name) (not connected)",
                                  action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = micChoice
            item.toolTip = uid
            microphoneMenu.addItem(item)
        }

        updateMicrophoneChecks()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? MicChoice else { return }
        micChoice = choice
        var state = AppState.load()
        state.microphone = choice
        state.save()
        updateMicrophoneChecks()
        primeRecorder()
    }

    /// Gets the mic ready for the next press. Deferred so the ~80 ms it takes
    /// never lands on a key press or on redrawing the menu.
    private func primeRecorder() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recorder.prime(deviceUID: self.micChoice.deviceUID)
        }
    }

    private func updateMicrophoneChecks() {
        guard microphoneMenu != nil else { return }
        // Separators carry no representedObject, so they simply never match.
        for item in microphoneMenu.items {
            item.state = ((item.representedObject as? MicChoice) == micChoice) ? .on : .off
        }
        // Put the active mic on the parent row so it reads at a glance, the way
        // the Source line above it does.
        microphoneMenuItem?.title = "Microphone: \(microphoneLabel())"
    }

    /// The chosen mic's name, flagged when it isn't currently connected.
    private func microphoneLabel() -> String {
        guard let uid = micChoice.deviceUID else { return micChoice.displayName }
        return AudioDevices.device(uid: uid) == nil
            ? "\(micChoice.displayName) (not connected)"
            : micChoice.displayName
    }

    // MARK: - Menu actions

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        let code = sender.representedObject as? String
        activeLanguage = (code == nil || code == "auto") ? nil : code
        updateLanguageChecks()
    }

    @objc private func toggleTranslate() {
        translateToEnglish.toggle()
        updateTranslateCheck()
        refreshProviderItem()
    }

    private func updateTranslateCheck() {
        translateMenuItem?.state = translateToEnglish ? .on : .off
    }

    private func updateLanguageChecks() {
        guard languageMenu != nil else { return }
        let current = activeLanguage ?? "auto"
        for item in languageMenu.items {
            let code = (item.representedObject as? String) ?? "auto"
            item.state = (code == current) ? .on : .off
        }
    }

    @objc private func openConfig() {
        let url = Config.configFileURL()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            let template = """
            {
              "provider": "groq",
              "groqApiKey": "",
              "anthropicApiKey": "",
              "cleanup": true
            }

            """
            try? template.data(using: .utf8)?.write(to: url)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func reloadConfig() {
        loadConfig(promptForPermissions: true)
        registerHotKey()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
