import Foundation
import Performance
import SongGraph

/// The Mixer: a strip per part the transport plays, edited live, every gesture a mix version.
@MainActor
@Observable
public final class MixerModel {

    /// One strip on the surface.
    public struct Row: Identifiable, Sendable {
        public var part: PartID
        public var label: String
        public var id: PartID { part }
    }

    /// One band of the masking overlay between two parts.
    public struct OverlayBand: Identifiable, Sendable {
        public var name: String
        public var lowHz: Double
        public var highHz: Double
        public var aDB: Double
        public var bDB: Double
        public var id: String { name }
        /// How many dB the louder sits over the quieter; small is shared.
        public var gapDB: Double { abs(aDB - bDB) }
    }

    public static let bands: [(name: String, low: Double, high: Double)] = [
        ("60–120", 60, 120), ("120–250", 120, 250), ("250–2k", 250, 2_000), ("2k–6k", 2_000, 6_000), ("6k+", 6_000, 20_000),
    ]

    public let surfaceID: SurfaceID
    public private(set) var rows: [Row]
    public private(set) var mix: Mix
    /// The version the working mix descends from; nil for unity.
    public private(set) var base: PartVersion?
    /// The mix as last committed, so a gesture's note can say what moved.
    private var committed: Mix
    public private(set) var meters: [PartID: (peak: Float, rms: Float)] = [:]
    public var overlayA: PartID?
    public var overlayB: PartID?
    public private(set) var overlay: [OverlayBand] = []
    public private(set) var isReadingOverlay = false
    public private(set) var lastError: String?
    public private(set) var lastNote: String?

    private let host: any MixHosting
    private var metering: Task<Void, Never>?

    public init(host: any MixHosting, base: PartVersion? = nil, surfaceID: SurfaceID = SurfaceID()) {
        self.host = host
        self.surfaceID = surfaceID
        self.base = base
        let starting: Mix
        if let base, case .mix(let stored) = base.kind {
            starting = stored
        } else {
            starting = host.playback.mix ?? .unity
        }
        mix = starting
        committed = starting
        let rows = Self.rows(of: host.playback, song: host.song, mix: starting)
        self.rows = rows
        overlayA = rows.first?.part
        overlayB = rows.dropFirst().first?.part
    }

    /// Every part the plan plays, in transport order, plus any the mix already names.
    static func rows(of plan: SongPlayback, song: Song?, mix: Mix) -> [Row] {
        var seen: [PartID] = []
        var out: [Row] = []
        func add(_ part: PartID?, _ label: String) {
            guard let part, !seen.contains(part) else { return }
            seen.append(part)
            let title = song?.versions.last { $0.partID == part }.map(PartLabel.title(of:)) ?? label
            out.append(Row(part: part, label: title))
        }
        add(plan.groovePart, "Groove")
        add(plan.basslinePart, "Bass")
        add(plan.chop?.part, plan.chop?.name ?? "Chop")
        for track in plan.tracks { add(track.part, track.name) }
        for segment in plan.segments {
            add(segment.groovePart, "Groove")
            add(segment.basslinePart, "Bass")
            add(segment.chop?.part, segment.chop?.name ?? "Chop")
        }
        for strip in mix.strips { add(strip.part, strip.label) }
        return out
    }

    public func strip(_ part: PartID) -> Strip {
        mix.strip(for: part, label: rows.first { $0.part == part }?.label ?? "Part")
    }

    // MARK: Moves — live while held, a version when let go

    private func update(_ part: PartID, _ change: (inout Strip) -> Void) {
        var strip = self.strip(part)
        change(&strip)
        mix.set(strip)
        host.preview(mix)
    }

    public func setGain(_ dB: Double, for part: PartID) { update(part) { $0.gainDB = max(-60, min(12, dB)) } }
    public func setPan(_ pan: Double, for part: PartID) { update(part) { $0.pan = max(-1, min(1, pan)) } }
    public func setSend(_ dB: Double?, for part: PartID) { update(part) { $0.sendDB = dB.map { max(-60, min(0, $0)) } } }
    public func toggleMute(_ part: PartID) { update(part) { $0.isMuted.toggle() }; endGesture() }
    public func toggleSolo(_ part: PartID) { update(part) { $0.isSoloed.toggle() }; endGesture() }
    public func setEQ(band index: Int, gainDB: Double, for part: PartID) {
        update(part) { strip in
            guard strip.eq.indices.contains(index) else { return }
            strip.eq[index].gainDB = max(-18, min(18, gainDB))
        }
    }
    public func setEQ(band index: Int, frequency: Double, for part: PartID) {
        update(part) { strip in
            guard strip.eq.indices.contains(index) else { return }
            strip.eq[index].frequency = max(20, min(20_000, frequency))
        }
    }
    public func setCompressor(_ compressor: Compressor?, for part: PartID) { update(part) { $0.compressor = compressor }; endGesture() }
    public func setMaster(gainDB: Double? = nil, ceilingDBTP: Double? = nil, targetLUFS: Double? = nil) {
        if let gainDB { mix.master.gainDB = max(-24, min(24, gainDB)) }
        if let ceilingDBTP { mix.master.ceilingDBTP = max(-12, min(0, ceilingDBTP)) }
        if let targetLUFS { mix.master.targetLUFS = max(-30, min(-6, targetLUFS)) }
        host.preview(mix)
    }

    /// The gesture is over: what moved becomes a version, its note the move.
    @discardableResult
    public func endGesture() -> PartVersion? {
        guard mix != committed else { return nil }
        let note = Self.describe(from: committed, to: mix, labels: Dictionary(rows.map { ($0.part, $0.label) }, uniquingKeysWith: { a, _ in a }))
        guard let version = host.commit(mix, base: base, note: note) else {
            lastError = "The move could not be kept."
            return nil
        }
        base = version
        committed = mix
        lastNote = note
        return version
    }

    /// Reverts the working mix to the version it descends from.
    public func revert() {
        mix = committed
        host.preview(mix)
    }

    /// "Bass −3 dB; Kick EQ 80 Hz −6 dB; master ceiling −1 dBTP" — every field that moved.
    static func describe(from a: Mix, to b: Mix, labels: [PartID: String]) -> String {
        var moves: [String] = []
        for strip in b.strips {
            let before = a.strip(for: strip.part) ?? Strip(part: strip.part, label: strip.label)
            let name = labels[strip.part] ?? strip.label
            if strip.gainDB != before.gainDB { moves.append(String(format: "%@ %+.1f dB", name, strip.gainDB)) }
            if strip.pan != before.pan { moves.append(String(format: "%@ pan %+.2f", name, strip.pan)) }
            if strip.isMuted != before.isMuted { moves.append("\(name) \(strip.isMuted ? "muted" : "unmuted")") }
            if strip.isSoloed != before.isSoloed { moves.append("\(name) \(strip.isSoloed ? "soloed" : "unsoloed")") }
            if strip.sendDB != before.sendDB { moves.append(strip.sendDB.map { String(format: "%@ send %+.1f dB", name, $0) } ?? "\(name) send off") }
            for (index, band) in strip.eq.enumerated() where index < before.eq.count && band != before.eq[index] {
                moves.append(String(format: "%@ EQ %.0f Hz %+.1f dB", name, band.frequency, band.gainDB))
            }
            if strip.compressor != before.compressor {
                moves.append(strip.compressor.map { String(format: "%@ compressor %.0f dB %.1f:1", name, $0.thresholdDB, $0.ratio) } ?? "\(name) compressor off")
            }
        }
        if b.master.gainDB != a.master.gainDB { moves.append(String(format: "master %+.1f dB", b.master.gainDB)) }
        if b.master.ceilingDBTP != a.master.ceilingDBTP { moves.append(String(format: "master ceiling %.1f dBTP", b.master.ceilingDBTP)) }
        if b.master.targetLUFS != a.master.targetLUFS { moves.append(String(format: "target %.0f LUFS", b.master.targetLUFS)) }
        if b.sectionGains != a.sectionGains { moves.append("section gains") }
        return moves.isEmpty ? "Mix" : moves.joined(separator: "; ")
    }

    // MARK: Meters

    public func startMetering() {
        metering?.cancel()
        metering = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.host.isPlaying {
                    self.meters = await self.host.meters(for: self.rows.map(\.part))
                } else if !self.meters.isEmpty {
                    self.meters = [:]
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    public func stopMetering() {
        metering?.cancel()
        metering = nil
    }

    // MARK: The overlay

    /// Bounces the two chosen parts each on its own and reads where they share energy.
    public func readOverlay() async {
        guard let a = overlayA, let b = overlayB, a != b else { return }
        isReadingOverlay = true
        defer { isReadingOverlay = false }
        do {
            var soloA = mix, soloB = mix
            soloA.strips = mix.strips.map { var s = $0; s.isSoloed = s.part == a; s.isMuted = false; return s }
            soloB.strips = mix.strips.map { var s = $0; s.isSoloed = s.part == b; s.isMuted = false; return s }
            var stripA = soloA.strip(for: a, label: ""); stripA.isSoloed = true; soloA.set(stripA)
            var stripB = soloB.strip(for: b, label: ""); stripB.isSoloed = true; soloB.set(stripB)
            let section = host.song?.sections.first?.id
            let (audioA, rate) = try await host.bounce(mix: soloA, section: section)
            let (audioB, _) = try await host.bounce(mix: soloB, section: section)
            overlay = Self.bands.map { band in
                OverlayBand(name: band.name, lowHz: band.low, highHz: band.high,
                            aDB: MixMeter.bandEnergyDB(audioA, sampleRate: rate, lowHz: band.low, highHz: band.high),
                            bDB: MixMeter.bandEnergyDB(audioB, sampleRate: rate, lowHz: band.low, highHz: band.high))
            }
            lastError = nil
        } catch {
            lastError = "The overlay could not be read: \(error)"
        }
    }
}
