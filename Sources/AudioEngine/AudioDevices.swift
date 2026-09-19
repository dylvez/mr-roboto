import AVFAudio
import CoreAudio
import Foundation

// Inputs I1: the audio devices CoreAudio reports, and the engine's input pointed at one.

/// An input device, as the Booth lists it.
public struct AudioInputDevice: Hashable, Sendable, Identifiable {
    public var id: AudioDeviceID
    public var name: String
    public var uid: String
    public var inputChannels: Int
    public var isDefault: Bool

    public init(id: AudioDeviceID, name: String, uid: String, inputChannels: Int, isDefault: Bool) {
        self.id = id
        self.name = name
        self.uid = uid
        self.inputChannels = inputChannels
        self.isDefault = isDefault
    }
}

public enum AudioDevices {

    /// Every device with at least one input channel, the system default first.
    public static func inputs() -> [AudioInputDevice] {
        let defaultID = defaultInputID()
        return allDeviceIDs().compactMap { id -> AudioInputDevice? in
            let channels = inputChannelCount(of: id)
            guard channels > 0 else { return nil }
            return AudioInputDevice(id: id, name: string(of: id, kAudioObjectPropertyName) ?? "Input \(id)",
                                    uid: string(of: id, kAudioDevicePropertyDeviceUID) ?? "\(id)", inputChannels: channels, isDefault: id == defaultID)
        }.sorted { ($0.isDefault ? 0 : 1, $0.name) < ($1.isDefault ? 0 : 1, $1.name) }
    }

    /// The device with this UID, if it is here now.
    public static func input(uid: String) -> AudioInputDevice? { inputs().first { $0.uid == uid } }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func string(of id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}

extension Engine {
    /// Points the input node at a device by UID. Takes effect for the next tap; the engine is
    /// best stopped when it changes. Nil goes back to the system default.
    public func setInputDevice(uid: String?) throws {
        guard let unit = avEngine.inputNode.audioUnit else { throw EngineError.formatMismatch("the input node has no audio unit") }
        var id: AudioDeviceID = uid.flatMap { AudioDevices.input(uid: $0)?.id } ?? AudioDevices.defaultInputID() ?? 0
        guard id != 0 else { throw RecorderError.noInput }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw EngineError.formatMismatch("could not set the input device (\(status))") }
    }
}
