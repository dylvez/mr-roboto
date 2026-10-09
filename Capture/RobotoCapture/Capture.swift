import AVFoundation
import Foundation

/// One capture on disk: the file, and what its name says.
struct Capture: Identifiable, Hashable {
    var url: URL
    var song: String
    var section: String
    var pass: Int
    var stamp: String
    /// Seconds of count-in at the head of the file, when it was sung to the guide.
    var lead: Double?
    var seconds: Double

    var id: URL { url }
    var title: String { song.isEmpty ? "Idea" : "\(song) · \(section.isEmpty ? "take" : section) \(pass)" }
}

/// The file name the Mac's inbox reads: `roboto-capture--<song>--<section>--<pass>--<stamp>.m4a`,
/// and `--<lead>` after the stamp when a guide played: the seconds of the file before the
/// section's first beat, which the Mac trims off. Spaces travel as underscores; `--` is the
/// separator and never appears in a field.
enum CaptureName {
    static let prefix = "roboto-capture"

    static func fileName(song: String, section: String, pass: Int, stamp: Date = Date(), lead: Double? = nil) -> String {
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "--", with: "-").replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let head = "\(prefix)--\(clean(song))--\(clean(section))--\(pass)--\(formatter.string(from: stamp))"
        let tail = lead.map { String(format: "--%.3f", $0) } ?? ""
        return "\(head)\(tail).m4a"
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
                       lead: fields.count > 4 ? Double(fields[4]) : nil,
                       seconds: seconds)
    }
}

/// Records to the app's Documents folder: visible in Files under "On My iPhone", and shareable
/// (AirDrop lands it in the Mac's Downloads, where the inbox watcher takes it by its name). With
/// the Mac folder chosen, a capture is copied into its Inbox as soon as it is stopped, and the
/// section's guide plays in the headphones while it is sung.
@MainActor
@Observable
final class Recorder: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    let mac = MacFolder()
    private(set) var isRecording = false
    private(set) var level: Float = 0
    private(set) var seconds: Double = 0
    private(set) var captures: [Capture] = []
    private(set) var lastError: String?
    /// True between the press and the count-in, while the guide comes down from the Mac folder.
    private(set) var fetchingGuide = false
    /// True while the guide sounds; false once it has played out, though the take goes on.
    private(set) var guidePlaying = false
    /// Said when the guide is coming out of the phone's speaker, and so into the take.
    private(set) var routeNote: String?
    /// Captures copied into the Mac folder's Inbox, by file name.
    private(set) var sent: Set<String>
    private(set) var sending: Set<String> = []
    var song: String { didSet { UserDefaults.standard.set(song, forKey: "song") } }
    var section: String { didSet { UserDefaults.standard.set(section, forKey: "section") } }
    /// Whether the section's guide plays while recording, when it has one. Remembered.
    var playGuide: Bool { didSet { UserDefaults.standard.set(playGuide, forKey: "playGuide") } }

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meter: Timer?
    private var started: Date?

    override init() {
        song = UserDefaults.standard.string(forKey: "song") ?? ""
        section = UserDefaults.standard.string(forKey: "section") ?? ""
        playGuide = UserDefaults.standard.object(forKey: "playGuide") as? Bool ?? true
        sent = Set(UserDefaults.standard.stringArray(forKey: "sent") ?? [])
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

    /// The song named, when it is one the Mac wrote guides for.
    var guidedSong: MacFolder.SongEntry? {
        mac.manifest?.songs.first { $0.title.caseInsensitiveCompare(song) == .orderedSame }
    }

    /// The guide for the section named, when the Mac wrote one.
    var guide: MacFolder.SectionEntry? {
        guidedSong?.sections.first { $0.name.caseInsensitiveCompare(section) == .orderedSame }
    }

    /// True when pressing Record plays the guide.
    var willPlayGuide: Bool { playGuide && guide != nil }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.documents, includingPropertiesForKeys: [.creationDateKey])) ?? []
        captures = files.compactMap(CaptureName.parse).sorted { $0.stamp > $1.stamp }
    }

    func toggle() async {
        if isRecording { stop() } else { await start() }
    }

    func start() async {
        lastError = nil
        routeNote = nil
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            lastError = "Microphone access was not granted. Settings › Roboto Capture › Microphone."
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            // A2DP, not the hands-free profile: the guide reaches Bluetooth headphones at full
            // quality, and the take comes in on the phone's own microphone. The hands-free
            // profile would switch to the headset's call microphone, at a phone call's bandwidth,
            // and the take with it.
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            lastError = "The audio session would not start: \(error.localizedDescription)"
            return
        }

        // The guide, whole, before anything starts: it may still be coming down from iCloud.
        var guideData: Data?
        var lead: Double?
        if playGuide, let guide {
            fetchingGuide = true
            defer { fetchingGuide = false }
            do {
                guideData = try await mac.guideData(for: guide)
            } catch {
                lastError = "The guide for \(guide.name) could not be fetched: \(error.localizedDescription) Try again, or turn the guide off."
                return
            }
            // What the Mac trims off: the count-in, and the way out and back in through the
            // audio device, so the first beat sung lands on the section's first beat.
            lead = guide.countInSeconds + session.outputLatency + session.inputLatency
            if session.currentRoute.outputs.allSatisfy({ $0.portType == .builtInSpeaker }) {
                routeNote = "No headphones: the guide is coming out of the speaker, and into the take."
            }
        }

        let url = Self.documents.appendingPathComponent(CaptureName.fileName(song: song, section: section, pass: nextPass, lead: lead))
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
            recorder.prepareToRecord()
            if let guideData {
                let player = try AVAudioPlayer(data: guideData)
                player.delegate = self
                player.prepareToPlay()
                // Both on the device's own clock, a moment from now: the guide's first click and
                // the file's first frame are the same instant, so the lead in the name is exact.
                let at = recorder.deviceCurrentTime + 0.3
                guard player.play(atTime: at), recorder.record(atTime: at) else {
                    player.stop()
                    recorder.stop()
                    lastError = "The recorder would not start with the guide."
                    return
                }
                self.player = player
                guidePlaying = true
                started = Date().addingTimeInterval(0.3)
            } else {
                guard recorder.record() else {
                    lastError = "The recorder would not start."
                    return
                }
                started = Date()
            }
            self.recorder = recorder
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
        seconds = started.map { max(0, Date().timeIntervalSince($0)) } ?? 0
    }

    func stop() {
        meter?.invalidate()
        meter = nil
        player?.stop()
        player = nil
        guidePlaying = false
        isRecording = false
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        reload()
        if let url, let capture = captures.first(where: { $0.url == url }) { send(capture) }
    }

    /// Into the Mac folder's Inbox, when there is one; otherwise the capture waits here to be shared.
    func send(_ capture: Capture) {
        let name = capture.url.lastPathComponent
        guard mac.inbox != nil, !sending.contains(name) else { return }
        sending.insert(name)
        Task {
            defer { sending.remove(name) }
            do {
                try await mac.send(capture.url)
                sent.insert(name)
                UserDefaults.standard.set(Array(sent), forKey: "sent")
            } catch {
                lastError = "\(capture.title) could not be put in the Mac's inbox: \(error.localizedDescription) Share it instead."
            }
        }
    }

    func isSent(_ capture: Capture) -> Bool { sent.contains(capture.url.lastPathComponent) }
    func isSending(_ capture: Capture) -> Bool { sending.contains(capture.url.lastPathComponent) }

    func delete(_ capture: Capture) {
        try? FileManager.default.removeItem(at: capture.url)
        sent.remove(capture.url.lastPathComponent)
        UserDefaults.standard.set(Array(sent), forKey: "sent")
        reload()
    }

    // MARK: Delegates

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.lastError = error?.localizedDescription ?? "The encoder failed." }
    }

    /// The system ended the take — a call, Siri — so the screen must not go on saying it records.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in if self.isRecording { self.stop() } }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.guidePlaying = false }
    }
}
