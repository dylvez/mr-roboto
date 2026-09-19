import AudioEngine
import Foundation

// Inputs I1/I3: which device and channel the Booth records from, remembered by UID.

/// A device by UID and, on a device with more than one input, one channel (0-based) as mono.
/// A nil device is the system's default; a nil channel is every channel the device has.
public struct InputChoice: Equatable, Sendable, Codable {
    public var deviceUID: String?
    public var channel: Int?

    public init(deviceUID: String? = nil, channel: Int? = nil) {
        self.deviceUID = deviceUID
        self.channel = channel
    }

    public static let systemDefault = InputChoice()

    /// The chosen device among these, or the default one when nothing is chosen or it is not here.
    public func device(in devices: [AudioInputDevice]) -> AudioInputDevice? {
        if let deviceUID, let found = devices.first(where: { $0.uid == deviceUID }) { return found }
        return devices.first { $0.isDefault } ?? devices.first
    }

    /// Whether the chosen device is missing, so the take falls back to the default.
    public func isFallingBack(in devices: [AudioInputDevice]) -> Bool {
        guard let deviceUID else { return false }
        return !devices.contains { $0.uid == deviceUID }
    }

    /// The channel that applies to this device: nil on a mono device or when none is chosen.
    public func channel(on device: AudioInputDevice?) -> Int? {
        guard let channel, let device, device.inputChannels > 1, channel < device.inputChannels else { return nil }
        return channel
    }

    /// What the take will say: "Scarlett 2i2, input 1", or the default with a reason.
    public func describe(in devices: [AudioInputDevice]) -> String {
        guard let device = device(in: devices) else { return "No input device is here." }
        let name = channel(on: device).map { "\(device.name), input \($0 + 1)" } ?? device.name
        if isFallingBack(in: devices) { return "\(name) — the remembered device is not here, so this is the system's default." }
        return deviceUID == nil ? "\(name) — the system's default input." : name
    }
}

/// The choice, in `UserDefaults`.
public struct InputSettings {
    private let defaults: UserDefaults
    static let deviceKey = "input.deviceUID"
    static let channelKey = "input.channel"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var choice: InputChoice {
        get {
            let channel = defaults.object(forKey: Self.channelKey) as? Int
            return InputChoice(deviceUID: defaults.string(forKey: Self.deviceKey), channel: channel)
        }
        nonmutating set {
            if let uid = newValue.deviceUID { defaults.set(uid, forKey: Self.deviceKey) } else { defaults.removeObject(forKey: Self.deviceKey) }
            if let channel = newValue.channel { defaults.set(channel, forKey: Self.channelKey) } else { defaults.removeObject(forKey: Self.channelKey) }
        }
    }
}
