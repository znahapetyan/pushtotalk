import AVFoundation
import Foundation

/// Records microphone audio to a temporary AAC/m4a file at 16 kHz mono —
/// small and directly accepted by Whisper-class transcription APIs.
final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

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

    @discardableResult
    func start() -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("talk-\(UUID().uuidString).wav")
        // Lossless 16-bit mono PCM at 16 kHz — Whisper runs at 16 kHz natively,
        // so this is full quality for it while keeping the upload small/fast.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { return false }
            self.recorder = recorder
            self.currentURL = url
            return true
        } catch {
            return false
        }
    }

    /// Stops recording and returns the finalized file URL (nil if not recording).
    func stop() -> URL? {
        recorder?.stop()
        let url = currentURL
        recorder = nil
        currentURL = nil
        return url
    }
}
