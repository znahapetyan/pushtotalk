import CoreAudio
import Foundation

/// A microphone macOS can record from.
struct AudioInputDevice: Equatable {
    /// Valid only right now — CoreAudio mints a fresh id every time a device
    /// appears, so this is never persisted or cached across a reconnect.
    let id: AudioDeviceID
    /// Stable across reconnects, reboots and OS upgrades (it is derived from the
    /// hardware — "BuiltInMicrophoneDevice", a Bluetooth MAC, a USB id), so this
    /// is what a pinned choice is remembered by.
    let uid: String
    let name: String
    /// Bluetooth mics force the headset into HFP while recording, which drops
    /// playback to phone quality. Worth telling the user before they pin one.
    let isBluetooth: Bool
}

/// Read-only view of the machine's input devices. Talk never changes the
/// system's own input device — it just records from the one it was told to.
enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    /// Every connected microphone, in CoreAudio's order.
    static func inputs() -> [AudioInputDevice] {
        allDeviceIDs().compactMap(describe)
    }

    /// The device macOS itself is currently listening to.
    static func defaultInput() -> AudioInputDevice? {
        guard let id = uint32(system, kAudioHardwarePropertyDefaultInputDevice),
              id != AudioDeviceID(kAudioObjectUnknown)
        else { return nil }
        return describe(AudioDeviceID(id))
    }

    /// The connected device with this UID, or nil if it isn't plugged in / paired.
    static func device(uid: String) -> AudioInputDevice? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var query = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &query) { qualifier in
            AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<CFString>.size),
                                       qualifier, &size, &id)
        }
        // A missing device is reported as success with kAudioObjectUnknown, not
        // as an error — checking only the status would hand back device 0.
        guard status == noErr, id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return describe(id)
    }

    /// Resolves what a human typed in config.json: a UID, a device name, or the
    /// start of one ("macbook pro"). Case-insensitive.
    static func device(matching text: String) -> AudioInputDevice? {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        if let exact = device(uid: needle) { return exact }
        let devices = inputs()
        return devices.first { $0.name.caseInsensitiveCompare(needle) == .orderedSame }
            ?? devices.first { $0.name.range(of: needle, options: [.caseInsensitive, .anchored]) != nil }
            ?? devices.first { $0.name.range(of: needle, options: .caseInsensitive) != nil }
    }

    // MARK: - CoreAudio plumbing

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    /// Fills in a device, or returns nil if it isn't something the user could
    /// pick: no input channels (speakers, the output half of a headset), a
    /// private aggregate, or one CoreAudio won't describe.
    private static func describe(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard !isPrivateAggregate(id),
              inputChannels(id) > 0,
              let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName)
        else { return nil }
        let transport = uint32(id, kAudioDevicePropertyTransportType)
        return AudioInputDevice(
            id: id,
            uid: uid,
            name: name,
            isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE
        )
    }

    /// Input channels across all of the device's input streams; 0 means it can't
    /// record. The stream configuration is a variable-length AudioBufferList, so
    /// it has to be read into memory sized by CoreAudio rather than a fixed one.
    private static func inputChannels(_ device: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + $1.mNumberChannels }
    }

    /// True for the per-process aggregates audio frameworks create for their own
    /// use — AVAudioEngine makes one ("CADefaultDeviceAggregate-<pid>-0") to
    /// follow the system input, and it would otherwise show up in the picker as
    /// a device. A user's own aggregate from Audio MIDI Setup is not private and
    /// stays selectable.
    private static func isPrivateAggregate(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioAggregateDevicePropertyComposition)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr,
              let composition = value?.takeRetainedValue() as? [String: Any]
        else { return false }
        return (composition[kAudioAggregateDeviceIsPrivateKey as String] as? Int) == 1
    }

    private static func uint32(_ object: AudioObjectID,
                               _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// CFString properties come back retained, hence `takeRetainedValue`.
    private static func string(_ object: AudioObjectID,
                               _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let cf = value
        else { return nil }
        return cf.takeRetainedValue() as String
    }
}
