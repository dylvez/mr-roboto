import Testing
import AVFAudio
import AudioToolbox
import Foundation
@testable import AudioEngine

@Suite struct MP3WriterTests {

    static func tone(_ frequency: Double, amplitude: Float, frames: Int, sampleRate: Double) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot()
    }

    /// Upward zero crossings per second: the tone's frequency, near enough.
    static func frequency(_ x: ArraySlice<Float>, sampleRate: Double) -> Double {
        var crossings = 0
        var previous = x.first ?? 0
        for value in x.dropFirst() {
            if previous < 0, value >= 0 { crossings += 1 }
            previous = value
        }
        return Double(crossings) * sampleRate / Double(x.count)
    }

    static func read(_ url: URL) throws -> (format: AVAudioFormat, planar: [[Float]]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let planar = (0..<Int(file.processingFormat.channelCount)).map { Analysis.samples(buffer, channel: $0) }
        return (file.processingFormat, planar)
    }

    /// What Core Audio reads from the file's ID3 tag.
    static func info(_ url: URL) throws -> [String: Any] {
        var file: AudioFileID?
        #expect(AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileMP3Type, &file) == noErr)
        let opened = try #require(file)
        defer { AudioFileClose(opened) }
        var dictionary: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        #expect(AudioFileGetProperty(opened, kAudioFilePropertyInfoDictionary, &size, &dictionary) == noErr)
        return (dictionary?.takeRetainedValue() as? [String: Any]) ?? [:]
    }

    @Test("a stereo tone comes back from Core Audio at its rate and length, each side at its level and pitch")
    func stereoRoundTrip() throws {
        let rate = 48_000.0
        let frames = Int(rate * 3)
        let left = Self.tone(440, amplitude: 0.5, frames: frames, sampleRate: rate)
        let right = Self.tone(660, amplitude: 0.25, frames: frames, sampleRate: rate)
        let url = try Analysis.temporaryDirectory("mp3").appendingPathComponent("tone.mp3")
        try MP3Writer.write([left, right], sampleRate: rate, to: url)

        let back = try Self.read(url)
        #expect(back.format.sampleRate == rate)
        #expect(back.format.channelCount == 2)
        // The Info frame says how much of the stream is the encoder's delay and padding, and Core
        // Audio drops it: the length is the length given, not a frame or two longer.
        #expect(abs(back.planar[0].count - frames) <= 1, "decoded \(back.planar[0].count) frames of \(frames)")
        // 320 kbps is 1 ms of stream for every 40 bytes; three seconds is about 120 kB.
        let bytes = try Data(contentsOf: url).count
        #expect(bytes > 110_000 && bytes < 135_000, "\(bytes) bytes")

        let middle = Int(rate * 0.5)..<Int(rate * 2.5)
        for (side, (original, amplitude, pitch)) in [(left, 0.5, 440.0), (right, 0.25, 660.0)].enumerated() {
            let decoded = back.planar[side][middle]
            let levelDB = 20 * log10(Self.rms(decoded) / Self.rms(original[middle]))
            #expect(abs(levelDB) < 0.2, "side \(side) is \(levelDB) dB off")
            #expect(abs(Self.frequency(decoded, sampleRate: rate) - pitch) < 2)
            #expect(abs(Self.rms(decoded) - Double(amplitude) / 2.0.squareRoot()) < 0.01)
            // Sample-aligned too: the delay dropped is exactly the encoder's.
            let error = zip(decoded, original[middle]).map { $0 - $1 }
            let snr = 20 * log10(Self.rms(original[middle]) / Self.rms(error[...]))
            #expect(snr > 30, "side \(side): \(snr) dB signal to error")
        }
    }

    @Test("the tag carries the title, artist, album, track and year, accents kept, and the cover as an APIC frame")
    func tags() throws {
        let rate = 48_000.0
        let tone = Self.tone(220, amplitude: 0.3, frames: Int(rate), sampleRate: rate)
        let cover = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: UInt8(7), count: 600))
        let tags = MP3Writer.Tags(title: "Malecón", artist: "Swag Hooks", album: "Shellac", albumArtist: "Swag Hooks",
                                  track: 3, trackCount: 11, year: 2026, cover: cover)
        let url = try Analysis.temporaryDirectory("mp3").appendingPathComponent("tagged.mp3")
        try MP3Writer.write([tone, tone], sampleRate: rate, tags: tags, to: url)

        let data = try Data(contentsOf: url)
        #expect(data.prefix(3) == Data("ID3".utf8))
        let info = try Self.info(url)
        #expect(info[kAFInfoDictionary_Title] as? String == "Malecón")
        #expect(info[kAFInfoDictionary_Artist] as? String == "Swag Hooks")
        #expect(info[kAFInfoDictionary_Album] as? String == "Shellac")
        #expect(info[kAFInfoDictionary_TrackNumber] as? String == "3/11")
        #expect(info[kAFInfoDictionary_Year] as? String == "2026")
        #expect(data.range(of: Data("APIC".utf8)) != nil)
        #expect(data.range(of: Data("image/png".utf8)) != nil)
        #expect(data.range(of: cover) != nil, "the cover's bytes are in the tag as they were given")
        // And the audio after the tag still reads, at its length.
        let back = try Self.read(url)
        #expect(abs(back.planar[0].count - tone.count) <= 1, "decoded \(back.planar[0].count) frames of \(tone.count)")
    }

    @Test("one channel is a mono file; a file already at the path is kept, not replaced; no audio is an error")
    func monoAndRefusals() throws {
        let rate = 48_000.0
        let tone = Self.tone(330, amplitude: 0.4, frames: Int(rate / 2), sampleRate: rate)
        let url = try Analysis.temporaryDirectory("mp3").appendingPathComponent("mono.mp3")
        try MP3Writer.write([tone], sampleRate: rate, tags: .init(title: "Mono"), to: url)
        let back = try Self.read(url)
        #expect(back.format.channelCount == 1)
        #expect(abs(back.planar[0].count - tone.count) <= 1, "decoded \(back.planar[0].count) frames of \(tone.count)")

        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try MP3Writer.write([tone, tone], sampleRate: rate, to: url) }
        #expect(try Data(contentsOf: url) == before)

        #expect(throws: MP3Writer.Failure.self) { try MP3Writer.encode([], sampleRate: rate) }
        #expect(throws: MP3Writer.Failure.self) { try MP3Writer.encode([[]], sampleRate: rate) }
    }
}
