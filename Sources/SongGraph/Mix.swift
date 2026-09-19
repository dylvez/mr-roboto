import Foundation

// M6 X1: the mix, as a part. A strip per part id, a master, and per-section gain overrides. Every
// move is a new mix version whose note says what moved and by how much.

/// One band of a strip's EQ.
public struct EQBand: Hashable, Codable, Sendable {
    public enum Shape: String, Codable, Sendable { case lowShelf, peak, highShelf }
    public var shape: Shape
    /// Hz.
    public var frequency: Double
    public var gainDB: Double
    /// Bandwidth for a peak, in octaves; ignored by the shelves.
    public var width: Double

    public init(shape: Shape, frequency: Double, gainDB: Double = 0, width: Double = 1) {
        self.shape = shape
        self.frequency = frequency
        self.gainDB = gainDB
        self.width = width
    }

    /// Three flat bands: a low shelf at 100, a peak at 1 k, a high shelf at 8 k.
    public static let flat: [EQBand] = [EQBand(shape: .lowShelf, frequency: 100), EQBand(shape: .peak, frequency: 1_000),
                                         EQBand(shape: .highShelf, frequency: 8_000)]
}

/// A strip's compressor. `ratio` sets how hard; the engine maps it onto its dynamics unit's knee.
public struct Compressor: Hashable, Codable, Sendable {
    public var thresholdDB: Double
    public var ratio: Double
    public var attackMS: Double
    public var releaseMS: Double
    public var makeupDB: Double

    public init(thresholdDB: Double = -18, ratio: Double = 3, attackMS: Double = 10, releaseMS: Double = 120, makeupDB: Double = 0) {
        self.thresholdDB = thresholdDB
        self.ratio = ratio
        self.attackMS = attackMS
        self.releaseMS = releaseMS
        self.makeupDB = makeupDB
    }
}

/// One part's channel: level, pan, EQ, compression, a send to the bus.
public struct Strip: Hashable, Codable, Sendable, Identifiable {
    public var part: PartID
    /// What the strip is called on the surface: the part's label when it was made.
    public var label: String
    public var gainDB: Double
    /// −1 left … +1 right.
    public var pan: Double
    public var isMuted: Bool
    public var isSoloed: Bool
    public var eq: [EQBand]
    public var compressor: Compressor?
    /// Send to the bus, dB; nil is no send.
    public var sendDB: Double?

    public var id: PartID { part }

    public init(part: PartID, label: String, gainDB: Double = 0, pan: Double = 0, isMuted: Bool = false, isSoloed: Bool = false,
                eq: [EQBand] = EQBand.flat, compressor: Compressor? = nil, sendDB: Double? = nil) {
        self.part = part
        self.label = label
        self.gainDB = gainDB
        self.pan = pan
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.eq = eq
        self.compressor = compressor
        self.sendDB = sendDB
    }

    /// True when the strip does nothing to the signal.
    public var isUnity: Bool {
        gainDB == 0 && pan == 0 && !isMuted && !isSoloed && eq.allSatisfy { $0.gainDB == 0 } && compressor == nil && sendDB == nil
    }
}

/// The master: gain before the limiter, the limiter's ceiling, and the loudness the song is
/// delivered at.
public struct Master: Hashable, Codable, Sendable {
    public var gainDB: Double
    public var ceilingDBTP: Double
    public var targetLUFS: Double

    public init(gainDB: Double = 0, ceilingDBTP: Double = -1, targetLUFS: Double = -14) {
        self.gainDB = gainDB
        self.ceilingDBTP = ceilingDBTP
        self.targetLUFS = targetLUFS
    }
}

/// A strip's gain in one section: the automation this milestone has.
public struct SectionGain: Hashable, Codable, Sendable {
    public var section: SectionID
    public var part: PartID
    public var gainDB: Double

    public init(section: SectionID, part: PartID, gainDB: Double) {
        self.section = section
        self.part = part
        self.gainDB = gainDB
    }
}

/// The mix: strips, master, section gains.
public struct Mix: Hashable, Codable, Sendable {
    public var strips: [Strip]
    public var master: Master
    public var sectionGains: [SectionGain]

    public init(strips: [Strip] = [], master: Master = Master(), sectionGains: [SectionGain] = []) {
        self.strips = strips
        self.master = master
        self.sectionGains = sectionGains
    }

    /// Nothing moved: every part at unity, the master at −14 / −1.
    public static let unity = Mix()

    public func strip(for part: PartID) -> Strip? { strips.first { $0.part == part } }

    /// The strip, or a fresh one at unity for a part the mix has not touched.
    public func strip(for part: PartID, label: String) -> Strip {
        strip(for: part) ?? Strip(part: part, label: label)
    }

    /// Puts a strip in, replacing the one for its part.
    public mutating func set(_ strip: Strip) {
        if let index = strips.firstIndex(where: { $0.part == strip.part }) { strips[index] = strip } else { strips.append(strip) }
    }

    /// A strip's gain in a section: the override when there is one, else the strip's.
    public func gainDB(for part: PartID, in section: SectionID?) -> Double {
        if let section, let override = sectionGains.first(where: { $0.section == section && $0.part == part }) { return override.gainDB }
        return strip(for: part)?.gainDB ?? 0
    }

    /// Whether any strip is soloed, which mutes the rest.
    public var hasSolo: Bool { strips.contains { $0.isSoloed } }

    /// The strip's effective level in dB, or nil for silence (muted, or another strip soloed).
    public func levelDB(for part: PartID, in section: SectionID? = nil) -> Double? {
        let strip = strip(for: part)
        if strip?.isMuted == true { return nil }
        if hasSolo, strip?.isSoloed != true { return nil }
        return gainDB(for: part, in: section)
    }
}
