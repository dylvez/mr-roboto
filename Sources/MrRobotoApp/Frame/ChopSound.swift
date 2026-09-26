import Foundation
import SongGraph

/// A groove's drums when they are a chop rather than a machine.
///
/// Recorded the way a machine pick is — a `.sound` naming the groove's part — so it is versioned,
/// shows in the ledger, and is undone or replaced by picking again. The instrument names the chop's
/// part rather than one version of it, so re-cutting the chop is heard in the groove: the groove
/// plays on the chop's newest cut.
enum ChopSound {
    static let prefix = "chop:"

    /// The `Sound.instrument` that puts a groove on `chop`'s slices.
    static func id(for chop: PartID) -> String {
        prefix + chop.rawValue.uuidString
    }

    /// The chop part a sound id names, or nil when it names a machine or anything else.
    static func part(of id: String) -> PartID? {
        guard id.hasPrefix(prefix), let uuid = UUID(uuidString: String(id.dropFirst(prefix.count))) else {
            return nil
        }
        return PartID(rawValue: uuid)
    }
}
