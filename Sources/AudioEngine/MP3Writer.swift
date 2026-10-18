import CLame
import Foundation

// The MP3 door. Core Audio reads MP3 but has no encoder for it, so this is LAME, vendored in the
// CLame target: 320 kbps constant bit rate at LAME's high-quality setting, joint stereo, an ID3v2
// tag in front and an Info frame first in the stream. The Info frame carries the length and the
// encoder's delay and padding, so a player seeks right and an album plays gapless.
//
// At 48 kHz, the rate a master renders at, every frame is 960 bytes and Core Audio reads the length
// to the sample. At 44.1 kHz frames are 1044 or 1045 bytes, and for about one length in nine Core
// Audio reports a frame (1152 samples) of silence more than the file holds: it seems to count CBR
// frames from the file's size rather than the Info frame, which is right either way.

/// Planar float audio as an MP3 file.
public enum MP3Writer {

    /// What the ID3 tag says. Every field but the title may be left out, and a blank one is.
    public struct Tags: Sendable, Hashable {
        public var title: String
        public var artist: String?
        public var album: String?
        public var albumArtist: String?
        /// The track's number on the album, from 1; with `trackCount`, written "3/11".
        public var track: Int?
        public var trackCount: Int?
        public var year: Int?
        /// The cover, JPEG or PNG bytes as they are. Anything else is left out.
        public var cover: Data?

        public init(title: String, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                    track: Int? = nil, trackCount: Int? = nil, year: Int? = nil, cover: Data? = nil) {
            self.title = title
            self.artist = artist
            self.album = album
            self.albumArtist = albumArtist
            self.track = track
            self.trackCount = trackCount
            self.year = year
            self.cover = cover
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case noAudio
        case encoder(String)
        public var description: String {
            switch self {
            case .noAudio: return "There is no audio to encode."
            case .encoder(let why): return "The MP3 encoder failed: \(why)"
            }
        }
    }

    /// The constant bit rate, in kbps: the highest MPEG-1 Layer III has.
    public static let bitRate = 320

    /// The rates an MP3 keeps as they are. Any other is resampled by LAME to the nearest it can
    /// carry at this bit rate.
    public static let nativeSampleRates: Set<Int> = [32_000, 44_100, 48_000]

    /// Encodes `planar` (one array per channel; the first two are used, and one is mono) and writes
    /// it to `url`. Never over something already there, as the WAV writers: the caller picks a
    /// free name.
    public static func write(_ planar: [[Float]], sampleRate: Double, tags: Tags? = nil, to url: URL) throws {
        let data = try encode(planar, sampleRate: sampleRate, tags: tags)
        try data.write(to: url, options: .withoutOverwriting)
    }

    /// The whole file in memory: the ID3v2 tag, then the stream with its Info frame first.
    public static func encode(_ planar: [[Float]], sampleRate: Double, tags: Tags? = nil) throws -> Data {
        guard let left = planar.first, !left.isEmpty else { throw Failure.noAudio }
        let right = planar.count >= 2 ? planar[1] : left
        let channels: Int32 = planar.count >= 2 ? 2 : 1
        let frames = min(left.count, right.count)
        let rate = Int32(sampleRate.rounded())

        guard let lame = lame_init() else { throw Failure.encoder("LAME could not start.") }
        defer { lame_close(lame) }
        lame_set_num_channels(lame, channels)
        lame_set_in_samplerate(lame, rate)
        if nativeSampleRates.contains(Int(rate)) { lame_set_out_samplerate(lame, rate) }
        // Known up front, so the tag carries the length (TLEN) as well as the Info frame.
        lame_set_num_samples(lame, UInt(frames))
        lame_set_mode(lame, channels == 2 ? JOINT_STEREO : MONO)
        lame_set_VBR(lame, vbr_off)
        lame_set_brate(lame, Int32(bitRate))
        // 2 is `lame -h`: LAME's recommended high quality, a little slower than its default 3.
        lame_set_quality(lame, 2)
        lame_set_bWriteVbrTag(lame, 1)
        // The tag is asked for and written here, ahead of the stream, rather than mixed into the
        // first encoded bytes, so the Info frame's place after it is known.
        lame_set_write_id3tag_automatic(lame, 0)
        id3tag_init(lame)
        id3tag_v2_only(lame)
        if let tags { apply(tags, to: lame) }
        let ready = lame_init_params(lame)
        guard ready >= 0 else { throw Failure.encoder("its settings were refused (\(ready)).") }

        var out = Data()
        let tagSize = lame_get_id3v2_tag(lame, nil, 0)
        if tagSize > 0 {
            var tag = [UInt8](repeating: 0, count: tagSize)
            let made = lame_get_id3v2_tag(lame, &tag, tagSize)
            out.append(contentsOf: tag.prefix(made))
        }
        let streamStart = out.count

        // LAME's own worst case for a chunk: 1.25 × samples + 7200 bytes.
        let chunk = 8192
        var buffer = [UInt8](repeating: 0, count: chunk * 5 / 4 + 7200)
        try left.withUnsafeBufferPointer { l in
            try right.withUnsafeBufferPointer { r in
                var start = 0
                while start < frames {
                    let count = min(chunk, frames - start)
                    let written = lame_encode_buffer_ieee_float(lame, l.baseAddress! + start, r.baseAddress! + start,
                                                                Int32(count), &buffer, Int32(buffer.count))
                    guard written >= 0 else { throw Failure.encoder(reason(written)) }
                    out.append(buffer, count: Int(written))
                    start += count
                }
            }
        }
        let tail = lame_encode_flush(lame, &buffer, Int32(buffer.count))
        guard tail >= 0 else { throw Failure.encoder(reason(tail)) }
        out.append(buffer, count: Int(tail))

        // The Info frame LAME left room for at the head of the stream, now that it knows the
        // length. Without it a player guesses the duration and plays the encoder's silence.
        let infoSize = lame_get_lametag_frame(lame, nil, 0)
        if infoSize > 0, out.count >= streamStart + infoSize {
            var info = [UInt8](repeating: 0, count: infoSize)
            if lame_get_lametag_frame(lame, &info, infoSize) == infoSize {
                out.replaceSubrange(streamStart..<streamStart + infoSize, with: info)
            }
        }
        return out
    }

    /// The frames as UTF-16 with a byte-order mark, which LAME asks for and every reader takes;
    /// a title with an accent in it is not Latin-1-safe across players otherwise.
    private static func apply(_ tags: Tags, to lame: OpaquePointer) {
        func text(_ id: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            let units: [UInt16] = [0xFEFF] + Array(value.utf16) + [0]
            _ = id3tag_set_textinfo_utf16(lame, id, units)
        }
        text("TIT2", tags.title)
        text("TPE1", tags.artist)
        text("TALB", tags.album)
        text("TPE2", tags.albumArtist)
        if let track = tags.track, track > 0 {
            text("TRCK", tags.trackCount.map { "\(track)/\($0)" } ?? "\(track)")
        }
        if let year = tags.year { text("TYER", "\(year)") }
        if let cover = tags.cover, !cover.isEmpty {
            cover.withUnsafeBytes { raw in
                _ = id3tag_set_albumart(lame, raw.baseAddress!.assumingMemoryBound(to: CChar.self), cover.count)
            }
        }
    }

    /// What LAME's negative returns mean, from lame.h.
    private static func reason(_ code: Int32) -> String {
        switch code {
        case -1: return "its output buffer was too small."
        case -2: return "it ran out of memory."
        case -3: return "it was not set up before encoding."
        case -4: return "its psychoacoustic model failed."
        default: return "error \(code)."
        }
    }
}
