import SongGraph

/// MIDI velocities for the three sounding tiers of a groove step, configurable per groove.
///
/// `SongGraph.VelocityTier` carries representative velocities (40 / 90 / 120) so a groove means
/// something without a map; this is the per-groove override, because how far a ghost sits under a
/// normal hit is a property of the *feel*, not of the vocabulary. A lo-fi kit wants its ghosts
/// close to audible and its accents well short of 127; a 909 house kit wants the opposite.
public struct VelocityMap: Hashable, Sendable, Codable {
    public var ghost: Int
    public var normal: Int
    public var accent: Int

    public init(ghost: Int = VelocityTier.ghost.velocity,
                normal: Int = VelocityTier.normal.velocity,
                accent: Int = VelocityTier.accent.velocity) {
        self.ghost = VelocityMap.clamp(ghost)
        self.normal = VelocityMap.clamp(normal)
        self.accent = VelocityMap.clamp(accent)
    }

    /// MIDI velocity for a tier. `.rest` is 0 — nothing sounds.
    public func velocity(for tier: VelocityTier) -> Int {
        switch tier {
        case .rest: return 0
        case .ghost: return ghost
        case .normal: return normal
        case .accent: return accent
        }
    }

    public subscript(tier: VelocityTier) -> Int { velocity(for: tier) }

    /// The tier vocabulary's own figures: 40 / 90 / 120.
    public static let standard = VelocityMap()
    /// Narrow and quiet: a dusty, compressed kit where nothing is played hard.
    public static let soft = VelocityMap(ghost: 30, normal: 78, accent: 104)
    /// Wide: the ghost notes are nearly inaudible and the accents are on the ceiling.
    public static let wide = VelocityMap(ghost: 24, normal: 88, accent: 127)
    /// Machine-flat: an 808/909 pattern where every programmed step is the same.
    public static let flat = VelocityMap(ghost: 64, normal: 100, accent: 112)

    private static func clamp(_ v: Int) -> Int { min(127, max(0, v)) }
}
