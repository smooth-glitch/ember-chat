import AVFoundation
import Observation

/// Records a voice note to an m4a file (AAC, native AVAudioRecorder --
/// this app's equivalent of the web client's MediaRecorder). `.m4a` is one
/// of the extensions the server/other clients' AUDIO_RE already recognizes,
/// so no protocol changes are needed to interoperate with the web app.
@MainActor
@Observable
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var lastRecordingURL: URL?

    func requestPermissionAndStart() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard granted else { return }
                self?.start()
            }
        }
    }

    private func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default)
        try? session.setActive(true)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return }
        self.recorder = recorder
        recorder.delegate = self
        recorder.record()
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = self?.recorder?.currentTime ?? 0 }
        }
    }

    /// Returns the recorded file's URL, or nil if cancelled/too short.
    func stop(discard: Bool = false) -> URL? {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        isRecording = false
        let url = recorder?.url
        recorder = nil
        if discard, let url { try? FileManager.default.removeItem(at: url) }
        return discard ? nil : url
    }
}
