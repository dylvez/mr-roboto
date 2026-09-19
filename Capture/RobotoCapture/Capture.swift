import AVFoundation
import Foundation

/// One capture on disk: the file, and what its name says.
struct Capture: Identifiable, Hashable {
    var url: URL
    var song: String
    var section: String
    var pass: Int
    var stamp: String
    var seconds: Double

    var id: URL { url }
    var title: String { song.isEmpty ? "Idea" : "\(song) · \(section.isEmpty ? "take" : section) \(pass)" }
}

/// The file name the Mac's inbox reads: `roboto-capture--<song>--<section>--<pass>--<stamp>.m4a`.
/// Spaces travel as underscores; `--` is the separator and never appears in a field.
enum CaptureName {
    static let prefix = "roboto-capture"

    static func fileName(song: String, section: String, pass: Int, stamp: Date = Date()) -> String {
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "--", with: "-").replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(prefix)--\(clean(song))--\(clean(section))--\(pass)--\(formatter.string(from: stamp)).m4a"
    }

    static func parse(_ url: URL) -> Capture? {
        let base = url.deletingPathExtension().lastPathComponent
        guard base.hasPrefix(prefix) else { return nil }
        let fields = base.components(separatedBy: "--").dropFirst().map { $0.replacingOccurrences(of: "_", with: " ") }
        let seconds = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        return Capture(url: url,
                       song: fields.count > 0 ? fields[0] : "",
                       section: fields.count > 1 ? fields[1] : "",
                       pass: fields.count > 2 ? Int(fields[2]) ?? 1 : 1,
                       stamp: fields.count > 3 ? fields[3] : "",
                       seconds: seconds)
    }
}

/// Records to the app's Documents folder: visible in Files under "On My iPhone", and shareable
/// (AirDrop lands it in the Mac's Downloads, where the inbox watcher takes it by its name).
@MainActor
@Observable
final class Recorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var level: Float = 0
    private(set) var seconds: Double = 0
    private(set) var captures: [Capture] = []
    private(set) var lastError: String?
    var song: String { didSet { UserDefaults.standard.set(song, forKey: "song") } }
    var section: String { didSet { UserDefaults.standard.set(section, forKey: "section") } }

    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private var started: Date?

    override init() {
        song = UserDefaults.standard.string(forKey: "song") ?? ""
        section = UserDefaults.standard.string(forKey: "section") ?? ""
        super.init()
        reload()
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The next pass for this song and section: one more than the most recent capture's.
    var nextPass: Int {
        (captures.filter { $0.song.caseInsensitiveCompare(song) == .orderedSame && $0.section.caseInsensitiveCompare(section) == .orderedSame }
            .map(\.pass).max() ?? 0) + 1
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.documents, includingPropertiesForKeys: [.creationDateKey])) ?? []
        captures = files.compactMap(CaptureName.parse).sorted { $0.stamp > $1.stamp }
    }

    func toggle() async {
        if isRecording { stop() } else { await start() }
    }

    func start() async {
        lastError = nil
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            lastError = "The audio session would not start: \(error.localizedDescription)"
            return
        }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            lastError = "Microphone access was not granted. Settings › Roboto Capture › Microphone."
            return
        }
        let url = Self.documents.appendingPathComponent(CaptureName.fileName(song: song, section: section, pass: nextPass))
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                lastError = "The recorder would not start."
                return
            }
            self.recorder = recorder
            started = Date()
            isRecording = true
            meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            lastError = "Could not record: \(error.localizedDescription)"
        }
    }

    private func tick() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, (db + 50) / 50))
        seconds = started.map { Date().timeIntervalSince($0) } ?? 0
    }

    func stop() {
        meter?.invalidate()
        meter = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
        reload()
    }

    func delete(_ capture: Capture) {
        try? FileManager.default.removeItem(at: capture.url)
        reload()
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.lastError = error?.localizedDescription ?? "The encoder failed." }
    }
}
