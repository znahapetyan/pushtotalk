import Foundation
import Carbon

/// Maps human-friendly key names to macOS virtual key codes (US layout).
enum KeyCodes {
    static let map: [String: UInt32] = [
        "space": 49, "return": 36, "tab": 48, "escape": 53, "delete": 51,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    static func code(for key: String) -> UInt32? { map[key.lowercased()] }
}

struct Config {
    let provider: String
    let transcriptionKey: String
    let transcriptionModel: String
    let transcriptionEndpoint: URL
    let translationEndpoint: URL
    let translate: Bool
    let language: String?
    let transcriptionPrompt: String?
    let anthropicKey: String
    let anthropicModel: String
    let cleanup: Bool
    let whisperServerPath: String
    let whisperModelPath: String
    let useFnKey: Bool
    /// Modifier keys that act as push-to-talk (e.g. ["fn", "control"]). Holding
    /// any one of them records. Used only in fn / push-to-talk mode.
    let pushToTalkKeys: [String]
    let hotKeyModifiers: UInt32
    let hotKeyKeyCode: UInt32

    static func configFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".talk", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// Loads config from ~/.talk/config.json, falling back to environment
    /// variables (useful when running the raw binary from a terminal).
    /// Throws `TalkError.config` only if no transcription key is available.
    static func load() throws -> Config {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: configFileURL()),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = obj
        }
        let env = ProcessInfo.processInfo.environment

        let provider = (json["provider"] as? String ?? "groq").lowercased()

        let transcriptionKey: String
        let transcriptionEndpoint: URL
        let translationEndpoint: URL
        let defaultModel: String
        switch provider {
        case "local":
            // Local whisper.cpp server — no API key, model chosen at server start.
            transcriptionKey = ""
            let endpoint = (json["localEndpoint"] as? String) ?? "http://127.0.0.1:8080/inference"
            let url = URL(string: endpoint) ?? URL(string: "http://127.0.0.1:8080/inference")!
            transcriptionEndpoint = url
            translationEndpoint = url // whisper.cpp translates via a flag on /inference
            defaultModel = "whisper" // ignored by the local server
        case "openai":
            transcriptionKey = (json["openaiApiKey"] as? String) ?? env["OPENAI_API_KEY"] ?? ""
            transcriptionEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
            translationEndpoint = URL(string: "https://api.openai.com/v1/audio/translations")!
            defaultModel = "whisper-1"
        default: // "groq"
            transcriptionKey = (json["groqApiKey"] as? String) ?? env["GROQ_API_KEY"] ?? ""
            transcriptionEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
            translationEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/translations")!
            defaultModel = "whisper-large-v3" // full model — more accurate than turbo
        }
        let transcriptionModel = (json["transcriptionModel"] as? String) ?? defaultModel
        let translate = (json["translate"] as? Bool) ?? false
        let language = (json["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let transcriptionPrompt = (json["transcriptionPrompt"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        guard provider == "local" || !transcriptionKey.isEmpty else {
            throw TalkError.config("Missing transcription API key for provider '\(provider)'")
        }

        let anthropicKey = (json["anthropicApiKey"] as? String) ?? env["ANTHROPIC_API_KEY"] ?? ""
        let anthropicModel = (json["anthropicModel"] as? String) ?? "claude-haiku-4-5"
        // Cleanup is on by default, but only possible if we have an Anthropic key.
        let cleanup = (json["cleanup"] as? Bool ?? true) && !anthropicKey.isEmpty

        // Paths for the app-managed local whisper server (local provider only).
        let defaultWhisperServer = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/whisper-server"
        let whisperServerPath = (json["whisperServerPath"] as? String) ?? defaultWhisperServer
        let defaultWhisperModel = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".talk/models/ggml-large-v3-turbo.bin").path
        let whisperModelPath = (json["whisperModelPath"] as? String)
            .map { ($0 as NSString).expandingTildeInPath } ?? defaultWhisperModel

        let (mods, keyCode) = parseHotKey(json)

        // Push-to-talk modifier keys. Default: hold fn OR control to record.
        let pushToTalkKeys = (json["pushToTalkKeys"] as? [String])
            .map { $0.map { $0.lowercased() } }
            .flatMap { $0.isEmpty ? nil : $0 } ?? ["fn", "control"]

        return Config(
            provider: provider,
            transcriptionKey: transcriptionKey,
            transcriptionModel: transcriptionModel,
            transcriptionEndpoint: transcriptionEndpoint,
            translationEndpoint: translationEndpoint,
            translate: translate,
            language: language,
            transcriptionPrompt: transcriptionPrompt,
            anthropicKey: anthropicKey,
            anthropicModel: anthropicModel,
            cleanup: cleanup,
            whisperServerPath: whisperServerPath,
            whisperModelPath: whisperModelPath,
            useFnKey: usesFnKey(json),
            pushToTalkKeys: pushToTalkKeys,
            hotKeyModifiers: mods,
            hotKeyKeyCode: keyCode
        )
    }

    /// True when the fn (Globe) key should be used for push-to-talk. This is the
    /// default unless the user explicitly configures a Carbon key combo.
    static func usesFnKey(_ json: [String: Any]) -> Bool {
        let key = (json["hotKeyKey"] as? String)?.lowercased()
        if key == "fn" || key == "function" || key == "globe" {
            return true
        }
        let hasCustomCombo = (json["hotKeyKey"] != nil) || (json["hotKeyModifiers"] != nil)
        return !hasCustomCombo // default to fn when nothing is configured
    }

    /// Default hotkey: Control+Option+Command + Space.
    static func parseHotKey(_ json: [String: Any]) -> (UInt32, UInt32) {
        var mods = UInt32(controlKey | optionKey | cmdKey)
        var key: UInt32 = 49 // space

        if let modList = json["hotKeyModifiers"] as? [String] {
            var m: UInt32 = 0
            for entry in modList {
                switch entry.lowercased() {
                case "command", "cmd": m |= UInt32(cmdKey)
                case "option", "opt", "alt": m |= UInt32(optionKey)
                case "control", "ctrl": m |= UInt32(controlKey)
                case "shift": m |= UInt32(shiftKey)
                default: break
                }
            }
            if m != 0 { mods = m }
        }
        if let k = json["hotKeyKey"] as? String, let code = KeyCodes.code(for: k) {
            key = code
        }
        return (mods, key)
    }
}
