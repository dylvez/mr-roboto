import AudioEngine
import Foundation
import Performance
import SongGraph

/// The whole song bounced once through a mix and read: the delivery numbers, and every section of
/// the form in the same numbers, off the same buffer. What the Master shows, and what `read_mix`
/// and `master` tell the Director — one bounce for all of it, read again only when the song or
/// the mix sounds different.
public struct WholeSongReading: Sendable {
    /// The plan it was bounced from, as `audible(_:)` keeps it: what "still current" is asked of.
    public var plan: SongPlayback
    public var observation: MixObservation
    public var truePeakDBTP: Double
    /// The whole and each section: loudness, crest, spread and the five bands (`SectionMeter`).
    public var sheet: SectionMeter.Sheet
    /// The form's section each of `sheet.sections` is, in the same order.
    public var sectionIDs: [SectionID]
    /// How long the bounce was, tail included.
    public var seconds: Double

    /// Reads a whole-song bounce of `plan`: one K-weighting pass and one STFT for the whole and
    /// every section — the delivery numbers are the sheet's whole row, not read a second time —
    /// and the true peak once. Pure, so it can run off the main actor.
    nonisolated static func measure(_ planar: [[Float]], sampleRate: Double, plan: SongPlayback, label: String) -> WholeSongReading {
        let spans = SectionBounce.spans(of: plan, sampleRate: sampleRate)
        let sheet = SectionMeter.read(planar, sampleRate: sampleRate, spans: spans.map(\.span), name: label)
        let truePeak = MixMeter.truePeakDB(planar, sampleRate: sampleRate)
        var observation = MixObservation(label: label, integratedLUFS: sheet.whole.integratedLUFS ?? -.infinity,
                                         peakDBFS: sheet.whole.peakDBFS ?? -.infinity, crestDB: sheet.whole.crestDB ?? 0,
                                         tiltDB: MixMeter.tiltDB(spectrum: sheet.spectrum, sampleRate: sampleRate),
                                         bandwidthHz: MixMeter.bandwidthHz(spectrum: sheet.spectrum, sampleRate: sampleRate))
        observation.truePeakDBTP = truePeak
        return WholeSongReading(plan: audible(plan), observation: observation, truePeakDBTP: truePeak, sheet: sheet,
                                sectionIDs: spans.map(\.section),
                                seconds: sampleRate > 0 ? Double(planar.first?.count ?? 0) / sampleRate : 0)
    }

    /// The plan as far as the bounce can hear it: not looping (a bounce never loops), and the
    /// master's target cleared — the target judges the numbers and is not in the audio.
    nonisolated static func audible(_ plan: SongPlayback) -> SongPlayback {
        var copy = plan.looping(false)
        copy.mix?.master.targetLUFS = 0
        return copy
    }

    /// Whether this reading is of `plan` as it sounds now.
    func isCurrent(for plan: SongPlayback) -> Bool { Self.audible(plan) == self.plan }

    /// The Engineer on the balance against a reference, band by band; nothing without one.
    func balanceReadings(against reference: ReferenceReading?, genre: GenreLens?) -> [PersonaReading] {
        guard let reference else { return [] }
        return Engineer().read(balance: sheet.whole.bandsDB, against: reference.sheet.whole.bandsDB,
                               named: reference.name, genre: genre?.profile)
    }

    /// The Peer on each hook against the verse before it.
    var liftReadings: [PersonaReading] { Peer().read(lifts: sheet.sections) }
}

/// A reference, read the way the song is: a record's file whole and by the sections its analysis
/// heard, or another song bounced whole through its own mix.
public struct ReferenceReading: Sendable, Equatable {
    public enum Kind: String, Sendable { case record, song }

    public var reference: MixReference
    public var name: String
    public var kind: Kind
    public var sheet: SectionMeter.Sheet
    /// What it was measured from: a record's file and grid, or the song as the library held it. A
    /// reference measured from something else is measured again.
    var source: String
}

/// One thing a song can be read against, for a picker.
public struct ReferenceChoice: Identifiable, Hashable, Sendable {
    public var reference: MixReference
    public var title: String
    /// "Bessie Smith", "Disco · 124 BPM".
    public var detail: String
    public var kind: ReferenceReading.Kind
    public var id: MixReference { reference }
}

/// Why a reference could not be measured.
enum ReferenceFailure: Error, CustomStringConvertible {
    case missing
    case itself
    case silent(String)
    case unplayable(String)

    var description: String {
        switch self {
        case .missing: return "The reference is no longer in the library."
        case .itself: return "A song cannot be its own reference."
        case .silent(let name): return "\(name) has nothing to read."
        case .unplayable(let name): return "\(name) has nothing to play."
        }
    }
}

extension SectionBounce {
    /// Where each section of a whole-song bounce of `plan` lies, in frames, in the form's order,
    /// on the clock `render` bounces it at. Empty for a plan with no form.
    static func spans(of plan: SongPlayback, sampleRate: Double) -> [(section: SectionID, span: SectionMeter.Span)] {
        guard plan.isArranged, sampleRate > 0 else { return [] }
        let clock = TransportClock(tempo: plan.tempo, timeSignature: plan.timeSignature, sampleRate: sampleRate)
        return plan.segments.map { segment in
            let start = Int((clock.seconds(forBar: segment.startBar) * sampleRate).rounded())
            let end = Int((clock.seconds(forBar: segment.endBar) * sampleRate).rounded())
            return (segment.section, SectionMeter.Span(name: segment.name, frames: start..<max(start, end)))
        }
    }
}

extension AppState {

    // MARK: The whole song

    /// The whole song read through the mix it plays now: the last reading when the song and the mix
    /// still sound as they did, else bounced once — only the mix, no stems — and read. Nil for a song
    /// with nothing to play.
    func readWholeSong(kitsDirectory: URL = AuditionService.defaultKitsDirectory) async throws -> WholeSongReading? {
        let plan = playback
        guard plan.isPlayable else { return nil }
        if let held = wholeSongReading, held.isCurrent(for: plan) { return held }
        let stems = try await SectionBounce.render(plan, section: nil, kitsDirectory: kitsDirectory, onlyTheMix: true)
        let label = song?.title ?? "Song"
        let reading = await Task.detached { WholeSongReading.measure(stems.mix, sampleRate: stems.sampleRate, plan: plan, label: label) }.value
        wholeSongReading = reading
        return reading
    }

    /// Keeps a reading the Master made, for the tools to read from while it is current.
    func keep(_ reading: WholeSongReading) { wholeSongReading = reading }

    // MARK: The reference

    /// What the open song can be read against: every record in the crate, then every other song in
    /// the library, each by title.
    public var referenceChoices: [ReferenceChoice] {
        let records = library.records.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }.map {
            ReferenceChoice(reference: .record($0.id), title: $0.title, detail: $0.artist.isEmpty ? "A record in the crate" : $0.artist, kind: .record)
        }
        let songs = library.songs.filter { $0.id != song?.id }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { other -> ReferenceChoice in
                let genre = other.genre.flatMap { GenreBook.standard.profile(named: $0) }?.name
                return ReferenceChoice(reference: .song(other.id), title: other.title,
                                       detail: [genre, String(format: "%.0f BPM", other.tempo)].compactMap { $0 }.joined(separator: " · "), kind: .song)
            }
        return records + songs
    }

    /// A reference's title, while the library still holds it.
    func referenceName(_ reference: MixReference) -> String? {
        if let id = reference.record { return library.record(id)?.title }
        if let id = reference.song { return library.song(id)?.title }
        return nil
    }

    /// The reference the open song is read against, when one was picked and is still there.
    public var mixReference: MixReference? {
        guard let picked = song?.mixReference, referenceName(picked) != nil else { return nil }
        return picked
    }

    /// Picks what the open song is read against, or nothing. Kept with the song. False when there
    /// is no song, the reference is not in the library, or it is the song itself.
    @discardableResult
    public func setMixReference(_ reference: MixReference?, by source: SessionEntry.Source = .you) -> Bool {
        guard let song else { return false }
        if let reference {
            guard reference.song != song.id, referenceName(reference) != nil else { return false }
        }
        guard song.mixReference != reference else { return true }
        updateSong { $0.mixReference = reference }
        note(source, reference.flatMap(referenceName).map { "Reading the mix against \($0)" } ?? "No reference for the mix",
             detail: reference == nil ? nil : "The Master draws its balance beside the song's, and the Engineer says where a band is more than 3 dB off it.")
        return true
    }

    /// A reference measured the way the Master measures the song. A record's file is read whole
    /// and by the sections its analysis heard; a song is bounced whole through its own mix — once:
    /// either is kept for the session, and measured again only when its file, its grid or the song
    /// itself has changed.
    func measureReference(_ reference: MixReference, kitsDirectory: URL = AuditionService.defaultKitsDirectory) async throws -> ReferenceReading {
        guard let store else { throw ReferenceFailure.missing }
        if let id = reference.record {
            guard let record = library.record(id) else { throw ReferenceFailure.missing }
            let source = "record:\(record.media.fileName):\(record.grid?.description ?? "as read")"
            if let held = referenceReadings[reference], held.source == source { return held }
            let url = try store.mediaURL(for: record.media)
            let sections = record.reading?.sections ?? []
            let title = record.title
            let sheet = try await Task.detached { () throws -> SectionMeter.Sheet in
                let (planar, rate) = try BoothAdapter.planar(url)
                return SectionMeter.read(planar, sampleRate: rate, spans: AppState.spans(of: sections, sampleRate: rate), name: title)
            }.value
            guard sheet.whole.integratedLUFS != nil else { throw ReferenceFailure.silent(title) }
            let reading = ReferenceReading(reference: reference, name: title, kind: .record, sheet: sheet, source: source)
            referenceReadings[reference] = reading
            return reading
        }
        guard let id = reference.song, let other = library.song(id) else { throw ReferenceFailure.missing }
        guard other.id != song?.id else { throw ReferenceFailure.itself }
        let source = "song:\(other.hashValue)"
        if let held = referenceReadings[reference], held.source == source { return held }
        let plan = SongPlayback.plan(for: other) { ref in try? store.mediaURL(for: ref, song: other.id) }.looping(false)
        guard plan.isPlayable else { throw ReferenceFailure.unplayable(other.title) }
        let stems = try await SectionBounce.render(plan, section: nil, kitsDirectory: kitsDirectory, onlyTheMix: true)
        let title = other.title
        let sheet = await Task.detached {
            SectionMeter.read(stems.mix, sampleRate: stems.sampleRate,
                              spans: SectionBounce.spans(of: plan, sampleRate: stems.sampleRate).map(\.span), name: title)
        }.value
        guard sheet.whole.integratedLUFS != nil else { throw ReferenceFailure.silent(title) }
        let reading = ReferenceReading(reference: reference, name: title, kind: .song, sheet: sheet, source: source)
        referenceReadings[reference] = reading
        return reading
    }

    /// A record's analysed sections as spans of its file: each by its label, "Part" where the
    /// analysis gave none, numbered when a name comes round again.
    nonisolated static func spans(of sections: [SectionRange], sampleRate: Double) -> [SectionMeter.Span] {
        var counts: [String: Int] = [:]
        return sections.compactMap { range in
            let start = max(0, Int((range.start * sampleRate).rounded())), end = Int((range.end * sampleRate).rounded())
            guard end > start else { return nil }
            let label = (range.label?.isEmpty == false ? range.label! : "Part").capitalized
            counts[label, default: 0] += 1
            return SectionMeter.Span(name: counts[label]! > 1 ? "\(label) \(counts[label]!)" : label, frames: start..<end)
        }
    }
}
