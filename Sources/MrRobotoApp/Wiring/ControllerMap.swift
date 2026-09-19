import Foundation

// Inputs I7: which control change moves which fader, and how a value becomes decibels.

/// Where a control change goes.
public enum ControlTarget: Hashable, Codable, Sendable {
    /// The Mixer's strip at this row, 0-based.
    case strip(Int)
    case master

    public var title: String {
        switch self {
        case .strip(let index): return "strip \(index + 1)"
        case .master: return "master"
        }
    }
}

/// Controller number → target. Out of the box CC 14–21 are the eight strips and 22 the master;
/// Learn rebinds one.
public struct ControllerMap: Equatable, Codable, Sendable {
    public var targets: [Int: ControlTarget]

    public init(targets: [Int: ControlTarget]) { self.targets = targets }

    public static let standard = ControllerMap(targets: Dictionary(uniqueKeysWithValues: (0..<8).map { (14 + $0, ControlTarget.strip($0)) } + [(22, .master)]))

    public func target(of controller: Int) -> ControlTarget? { targets[controller] }

    public func controller(for target: ControlTarget) -> Int? { targets.first { $0.value == target }?.key }

    /// This controller now moves this target and nothing else does; whatever it moved before is unbound.
    public mutating func learn(controller: Int, target: ControlTarget) {
        targets = targets.filter { $0.value != target }
        targets[controller] = target
    }

    /// A strip's gain: 0…127 as −60…+12 dB, unity at 106.
    public static func gainDB(for value: Int) -> Double { -60 + Double(max(0, min(127, value))) / 127 * 72 }

    /// The master's gain: 0…127 as −24…+24 dB, unity at 64.
    public static func masterGainDB(for value: Int) -> Double { -24 + Double(max(0, min(127, value))) / 127 * 48 }
}

/// The map in `UserDefaults`, as JSON.
public struct ControllerMapSettings {
    private let defaults: UserDefaults
    static let key = "midi.map"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var map: ControllerMap {
        get {
            guard let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode(ControllerMap.self, from: data) else { return .standard }
            return stored
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) }
        }
    }
}
