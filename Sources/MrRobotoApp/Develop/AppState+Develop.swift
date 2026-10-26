import Foundation
import Performance
import SongGraph

/// What a song was before it was developed: its form, and the mix it had.
public struct BeforeDevelopment: Equatable, Sendable {
    public var song: SongID
    public var sections: [Section]
    /// The newest mix then, or nil when the song had never been mixed.
    public var mix: VersionID?
    /// The part developing marked as the song's tune, when none was: put back, it is unmarked
    /// again, unless somebody has marked another since.
    public var markedTune: PartID?
}

/// How a development landed, for whoever asked for it to say.
public struct DevelopmentResult: Equatable, Sendable {
    public var development: Development
    /// The loudness it was read at once everything was in, and the master gain that got it
    /// there. Nil when there was nothing to bounce through.
    public var loudness: Loudness?

    public struct Loudness: Equatable, Sendable {
        public var integratedLUFS: Double
        public var truePeakDBTP: Double
        public var masterGainDB: Double
        public var seconds: Double
    }
}

extension AppState {

    /// What developing the open song would do, without doing it. Nil when nothing in it plays.
    public func development(form: [(name: String, bars: Int)]? = nil, by author: Author = Develop.author) -> Development? {
        guard let song else { return nil }
        // The genre somebody set decides the form and the loudness. One guessed from a feel
        // decides only whether the drums are dance music's.
        let reading = GenreBook.standard.genre(of: song)
        let set = reading.flatMap { $0.source == .set ? $0.profile : nil }
        return Develop.plan(for: song, form: form, genre: set, electronic: Develop.isElectronic(reading?.profile),
                            harmony: .varied(seed: Develop.seed(for: song)), by: author)
    }

    /// Whether there is a loop to develop: something that plays.
    public var canDevelop: Bool { song.map { !Develop.loop(of: $0).isEmpty } ?? false }

    /// Whether the open song's last development can be put back.
    public var canPutBackDevelopment: Bool {
        guard let before = beforeDevelopment, let song else { return false }
        return before.song == song.id
    }

    /// Develops the open song: the form, a variation of each part for the sections that want one,
    /// each section's levels and the master's target, kept as one move.
    ///
    /// The loudness is not read here — that is a bounce, and takes seconds — but by
    /// `masterToLoudness`, which `developAndMaster` runs after it.
    @discardableResult
    public func develop(form: [(name: String, bars: Int)]? = nil, by source: SessionEntry.Source = .you,
                        author: Author = Develop.author) -> Development? {
        keepSurfaceWork()
        guard let song else {
            note(.session, "No song open; nothing to develop")
            return nil
        }
        // An idea is not developed in place: a song is made of it, and that is developed. The idea
        // keeps its one section and stays on its shelf.
        if song.isIdea {
            guard canDevelop else {
                note(.session, "Nothing in \(song.title) plays yet",
                     detail: "Paint a groove, write a bass line or set the chords; then there is a loop to make a song of.")
                return nil
            }
            guard songFromIdea(song.id) != nil, self.song?.isIdea == false else { return nil }
            return develop(form: form, by: source, author: author)
        }
        guard let development = development(form: form, by: author) else {
            note(.session, "Nothing in \(song.title) plays yet",
                 detail: "Paint a groove, write a bass line or set the chords; then there is a loop to develop.")
            return nil
        }
        let before = BeforeDevelopment(song: song.id, sections: song.sections, mix: Guidance.mixes(in: song).last?.id,
                                       markedTune: development.tune)
        guard keep(development.versions, arranged: development.sections) else { return nil }
        if let mix = development.mix {
            _ = MixAdapter(app: self, author: author)
                .commit(mix, base: Guidance.mixes(in: self.song ?? song).last, note: "Each section's level, for the arrangement")
            refreshSurfaces(of: [.mixer, .master])
        }
        // What it treated as the tune is the song's tune now, when nobody had said which.
        if let tune = development.tune { updateSong { $0.markTune(tune) } }
        beforeDevelopment = before
        let seconds = StructureModel.seconds(bars: development.bars, tempo: song.tempo, timeSignature: song.timeSignature)
        var detail = development.plays.map { "\($0.name) \($0.bars)" }.joined(separator: " · ")
        detail += " · \(StructureModel.clock(seconds)), \(development.form.words)."
        if !development.written.isEmpty { detail += " Written: \(development.written.joined(separator: ", "))." }
        if let tune = development.tune.flatMap({ self.song?.latestVersion(of: $0) }) {
            detail += " \(PartLabel.title(of: tune)) is marked as the song's tune."
        }
        if transport.isPlaying { detail += " Heard the next time you press play." }
        note(source, "Developed \(song.title): \(development.shape)", detail: detail)
        return development
    }

    /// Puts the song back as it was before it was last developed: its form, and its mix. What was
    /// written stays in the song, in no section, as everything ever made does.
    @discardableResult
    public func putBackDevelopment(by source: SessionEntry.Source = .you) -> Bool {
        guard let before = beforeDevelopment, let song, before.song == song.id else { return false }
        keepSurfaceWork()
        beforeDevelopment = nil
        let arranged = arrange(before.sections, by: source)
        // The tune developing marked is unmarked again; one marked since is somebody's, and stays.
        if let marked = before.markedTune, self.song?.tune == marked { updateSong { $0.markTune(nil) } }
        let newest = Guidance.mixes(in: song).last
        if let newest, newest.id != before.mix {
            if let mix = before.mix {
                restore(mix)
            } else {
                _ = MixAdapter(app: self, author: .user).commit(.unity, base: newest, note: "The mix as it was: nothing moved")
                refreshSurfaces(of: [.mixer, .master])
            }
        }
        note(source, "\(song.title) is back as it was", detail: "The form and the mix from before it was developed. What was written for it is still in the song.")
        return arranged
    }

    /// Brings the master to a loudness: the song bounced through its mix, read, and the master's
    /// gain moved by the gap — the whole of it the first time, when nothing is in the limiter yet,
    /// and most of it after — until it is within half a LU or three bounces have gone by. One mix
    /// version at the end, however many bounces it took. Nil when nothing plays, or when the song
    /// was changed for another while it was being read.
    public func masterToLoudness(_ target: Double, author: Author = .persona("Engineer")) async -> DevelopmentResult.Loudness? {
        guard let song, playback.isPlayable, !isMastering else { return nil }
        isMastering = true
        defer { isMastering = false }
        let id = song.id
        let base = playback.mix ?? .unity
        var mix = base
        mix.master.targetLUFS = target
        var read: DevelopmentResult.Loudness?
        for pass in 0..<3 {
            var plan = playback
            plan.mix = mix
            guard let stems = try? await SectionBounce.render(plan, section: nil, kitsDirectory: AuditionService.defaultKitsDirectory,
                                                              onlyTheMix: true) else { break }
            let lufs = MixMeter.integratedLoudness(stems.mix, sampleRate: stems.sampleRate)
            guard lufs.isFinite else { break }
            read = DevelopmentResult.Loudness(integratedLUFS: lufs,
                                              truePeakDBTP: MixMeter.truePeakDB(stems.mix, sampleRate: stems.sampleRate),
                                              masterGainDB: mix.master.gainDB,
                                              seconds: Double(stems.mix.first?.count ?? 0) / stems.sampleRate)
            let gap = target - lufs
            if abs(gap) <= 0.5 { break }
            mix.master.gainDB = max(-24, min(24, mix.master.gainDB + (pass == 0 ? 1 : 0.8) * gap))
        }
        guard self.song?.id == id, let read else { return nil }
        mix.master.gainDB = read.masterGainDB
        if mix != base {
            let moved = read.masterGainDB - base.master.gainDB
            let note = String(format: "Master %+.1f dB to %.1f LUFS, for a target of %.1f", moved, read.integratedLUFS, target)
            _ = MixAdapter(app: self, author: author).commit(mix, base: Guidance.mixes(in: self.song ?? song).last, note: note)
            refreshSurfaces(of: [.mixer, .master])
        }
        return read
    }

    /// Develops the song and brings its master to the loudness its genre is delivered at.
    @discardableResult
    public func developAndMaster(form: [(name: String, bars: Int)]? = nil, by source: SessionEntry.Source = .you,
                                 author: Author = Develop.author) async -> DevelopmentResult? {
        guard !isDeveloping, !isMastering else { return nil }
        isDeveloping = true
        let developed = develop(form: form, by: source, author: author)
        // The arrangement is in and plays; reading the master is the slow half, and is not a
        // reason to keep anybody from the song.
        isDeveloping = false
        guard let development = developed else { return nil }
        let loudness = await masterToLoudness(development.targetLUFS)
        if let loudness {
            note(.persona("Engineer"), String(format: "%.1f LUFS, true peak %.1f dBTP", loudness.integratedLUFS, loudness.truePeakDBTP),
                 detail: String(format: "The master is at %+.1f dB for a target of %.1f LUFS%@.", loudness.masterGainDB,
                                development.targetLUFS, development.genre.map { ", where \($0) is delivered" } ?? ""))
        }
        return DevelopmentResult(development: development, loudness: loudness)
    }
}
