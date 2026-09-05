import AVFoundation
import Foundation

/// Records the microphone to a temporary 16 kHz mono 16-bit PCM .wav — Whisper
/// runs at 16 kHz natively, so this is full quality for it while keeping the
/// upload small and fast.
///
/// Built on AVAudioEngine rather than AVAudioRecorder because only the engine
/// can be pinned to a chosen input device. AVAudioRecorder always follows the
/// system input, which is how connecting AirPods used to hijack dictation.
final class AudioRecorder: NSObject {
    /// Why `start` didn't begin recording, so the menu can say something
    /// specific instead of a generic failure.
    enum StartResult {
        case started
        /// The pinned device isn't connected right now.
        case deviceUnavailable
        case failed
    }

    struct Recording {
        let url: URL
        /// Seconds of audio actually captured — not how long the key was held.
        let duration: TimeInterval
        /// CoreAudio moved the input off the pinned device mid-recording. It does
        /// that silently when a device disappears, and keeps delivering audio
        /// from the system default instead, so the tail may be another mic.
        let deviceChanged: Bool
    }

    /// Whisper's native rate, and the rate of the file we write.
    private static let sampleRate = 16000.0

    private let engine = AVAudioEngine()
    /// The engine's device id when freshly built: a private aggregate that
    /// tracks macOS' input device. Setting it back is how "System default"
    /// resumes following the system rather than freezing on one device.
    private let followSystemDeviceID: AUAudioObjectID
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var currentURL: URL?
    private var pinnedDeviceID: AUAudioObjectID?
    /// The device the engine is currently set up for, and that device's native
    /// format, once `prime` has done the slow parts of the setup. Nil means the
    /// next `start` has to do them itself.
    private var primedDeviceID: AUAudioObjectID?
    private var primedFormat: AVAudioFormat?
    private var capturedFrames: AVAudioFramePosition = 0
    /// Signalled by the tap once it has handed over another buffer, so stop()
    /// can collect the one in flight instead of dropping it.
    private var tailSignal: DispatchSemaphore?
    /// Guards the file/converter against the tap thread while stop() finalizes.
    private let lock = NSLock()

    override init() {
        // Touching inputNode here builds the audio unit and connects to the
        // CoreAudio server, which costs ~100 ms once per process. Paying it at
        // launch keeps it off the first push-to-talk press.
        followSystemDeviceID = engine.inputNode.auAudioUnit.deviceID
        super.init()
    }

    /// Requests microphone access (macOS uses AVCaptureDevice, not AVAudioSession).
    /// Completion is always delivered on the main thread.
    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    /// Sets the engine up to record from `deviceUID` without opening the
    /// microphone, so a later `start` only has to spin up IO.
    ///
    /// Pinning the device, reading its format, installing the tap and preparing
    /// the graph cost ~80 ms together — most of a push-to-talk press, and all of
    /// it audio the user has already spoken. Doing it here instead (at launch,
    /// when the menu selection changes, and after each recording) leaves only
    /// `engine.start()` on the moment that matters. The recording indicator
    /// stays dark: only a running engine opens the device.
    ///
    /// - Returns: false if the device isn't connected.
    @discardableResult
    func prime(deviceUID: String?) -> Bool {
        guard !engine.isRunning else { return true }
        guard let target = deviceID(for: deviceUID) else {
            unprime()
            return false
        }
        let input = engine.inputNode
        do {
            // Re-asserting the device we already have is a no-op, so this costs
            // nothing on the common path — and it repairs a pin that CoreAudio
            // moved out from under us after an earlier disconnect.
            try input.auAudioUnit.setDeviceID(target)
        } catch {
            unprime()
            return false
        }

        // Read the format *after* pinning: outputFormat(forBus:) never catches up
        // with a device change, and a tap installed with that stale format either
        // refuses to start or starts and silently delivers nothing. Re-read every
        // time rather than cached, so the tap can never outlive the format it
        // was installed with by more than one recording.
        let native = input.inputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else {
            unprime()
            return false
        }
        if primedFormat != nil { input.removeTap(onBus: 0) }
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        // Re-preparing after every stop is what keeps the next start() at ~40 ms
        // instead of ~90 ms.
        engine.prepare()
        primedDeviceID = target
        primedFormat = native
        return true
    }

    /// - Parameter deviceUID: the microphone to record from, or nil to follow
    ///   whatever macOS' input device is.
    @discardableResult
    func start(deviceUID: String?) -> StartResult {
        discard()

        guard let target = deviceID(for: deviceUID) else { return .deviceUnavailable }
        if primedDeviceID != target || primedFormat == nil {
            guard prime(deviceUID: deviceUID) else { return .deviceUnavailable }
        }
        guard let native = primedFormat else { return .failed }
        pinnedDeviceID = target

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("talk-\(UUID().uuidString).wav")
        // Lossless 16-bit mono PCM at 16 kHz. AVAudioFile takes float buffers and
        // converts to 16-bit on write, so its processingFormat — not this one —
        // is what the converter has to produce.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let converter = AVAudioConverter(from: native, to: file.processingFormat)
        else {
            try? FileManager.default.removeItem(at: url)
            return .failed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.downmix = true // average a multi-channel device down, don't just take channel 0

        // The tap is already live, so the file has to exist before IO starts.
        self.file = file
        self.converter = converter
        self.currentURL = url
        self.capturedFrames = 0

        do {
            try engine.start()
        } catch {
            // The device changed its format under a tap primed for the old one.
            // Re-prime from scratch and give it one more go.
            unprime()
            guard prime(deviceUID: deviceUID), (try? engine.start()) != nil else {
                discard()
                return .failed
            }
        }
        return .started
    }

    /// Resolves a UID to a device usable right now. Device 0 is not a device:
    /// setDeviceID takes it without complaint and then captures nothing at all.
    private func deviceID(for uid: String?) -> AUAudioObjectID? {
        guard let uid = uid else { return followSystemDeviceID != 0 ? followSystemDeviceID : nil }
        guard let device = AudioDevices.device(uid: uid), device.id != 0 else { return nil }
        return AUAudioObjectID(device.id)
    }

    private func unprime() {
        if primedFormat != nil { engine.inputNode.removeTap(onBus: 0) }
        primedDeviceID = nil
        primedFormat = nil
    }

    /// Stops recording and returns the finished file (nil if not recording).
    func stop() -> Recording? {
        guard let url = currentURL else { return nil }
        let input = engine.inputNode
        let changed = pinnedDeviceID.map { $0 != input.auAudioUnit.deviceID } ?? false

        // A tap only delivers on 100 ms boundaries, so whatever it is holding
        // when the key comes up would be dropped — up to 100 ms off the end of
        // the last word. Waiting for one more hand-over recovers it. The wait is
        // bounded so a device that has stopped delivering can't hang anything,
        // and it is invisible next to the transcription request that follows.
        let tail = DispatchSemaphore(value: 0)
        lock.lock(); tailSignal = tail; lock.unlock()
        _ = tail.wait(timeout: .now() + 0.15)
        lock.lock(); tailSignal = nil; lock.unlock()

        // Stopping the engine ends the tap callbacks; the tap itself stays
        // installed for the next recording (see prime).
        engine.stop()

        lock.lock()
        // One flush at the end recovers the ~12 ms the resampler is holding in
        // its delay line; between buffers that would reset it instead.
        if let converter = converter, let file = file,
           let tail = convert(nil, with: converter, to: file.processingFormat) {
            try? file.write(from: tail)
            capturedFrames += AVAudioFramePosition(tail.frameLength)
        }
        let frames = capturedFrames
        // Releasing the file is what patches the real sizes into the WAV header,
        // so nothing may read the file until this happens.
        file = nil
        converter = nil
        currentURL = nil
        capturedFrames = 0
        pinnedDeviceID = nil
        lock.unlock()

        return Recording(url: url, duration: Double(frames) / Self.sampleRate, deviceChanged: changed)
    }

    // MARK: - Capture

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file = file, let converter = converter,
              let converted = convert(buffer, with: converter, to: file.processingFormat)
        else { return }
        try? file.write(from: converted)
        capturedFrames += AVAudioFramePosition(converted.frameLength)
        tailSignal?.signal()
    }

    /// Resamples one tap buffer to 16 kHz mono, or drains the resampler when
    /// `buffer` is nil. The block form is required for a rate change —
    /// `convert(to:from:)` traps on the output buffer size instead of erroring.
    private func convert(_ buffer: AVAudioPCMBuffer?,
                         with converter: AVAudioConverter,
                         to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = buffer.map { Double($0.frameLength) * format.sampleRate / $0.format.sampleRate } ?? 4096
        // Slack for the frames the resampler has been holding on to.
        let capacity = AVAudioFrameCount(frames.rounded(.up)) + 64
        guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            guard let buffer = buffer, !supplied else {
                // .noDataNow keeps the resampler's state across taps; .endOfStream
                // flushes it, which is only ever right at the very end.
                outStatus.pointee = buffer == nil ? .endOfStream : .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    /// Tears down a recording in progress and removes its half-written file.
    private func discard() {
        // Pinning a running engine silently stops it, so never leave one up.
        if engine.isRunning { engine.stop() }
        lock.lock()
        file = nil
        converter = nil
        capturedFrames = 0
        pinnedDeviceID = nil
        let url = currentURL
        currentURL = nil
        lock.unlock()
        if let url = url { try? FileManager.default.removeItem(at: url) }
    }
}
