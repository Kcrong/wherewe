import AudioToolbox
import CoreAudio
import Foundation

public struct AudioInputDevice: Equatable, Identifiable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannelCount: Int
    public let nominalSampleRate: Double
    public let isDefaultInput: Bool

    public init(
        id: AudioDeviceID,
        uid: String,
        name: String,
        inputChannelCount: Int,
        nominalSampleRate: Double,
        isDefaultInput: Bool
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.inputChannelCount = inputChannelCount
        self.nominalSampleRate = nominalSampleRate
        self.isDefaultInput = isDefaultInput
    }
}

public enum CoreAudioCatalogError: Error, Equatable, LocalizedError, Sendable {
    case propertySize(selector: AudioObjectPropertySelector, status: OSStatus)
    case propertyRead(selector: AudioObjectPropertySelector, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .propertySize:
            return "CoreAudio could not determine the connected audio-device list."
        case .propertyRead:
            return "CoreAudio could not read the connected audio-device list."
        }
    }
}

public struct CoreAudioDeviceCatalog: Sendable {
    public init() {}

    public func inputDevices() throws -> [AudioInputDevice] {
        let deviceIDs = try deviceIDs()
        let defaultInput = try? audioDeviceIDProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        )

        return deviceIDs.compactMap { deviceID in
            guard let channels = try? inputChannelCount(deviceID), channels > 0,
                  let uid = try? stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = try? stringProperty(deviceID, selector: kAudioObjectPropertyName),
                  let sampleRate = try? float64Property(
                    objectID: deviceID,
                    selector: kAudioDevicePropertyNominalSampleRate,
                    scope: kAudioObjectPropertyScopeGlobal
                  ) else {
                return nil
            }
            return AudioInputDevice(
                id: deviceID,
                uid: uid,
                name: name,
                inputChannelCount: channels,
                nominalSampleRate: sampleRate,
                isDefaultInput: deviceID == defaultInput
            )
        }.sorted {
            if $0.isDefaultInput != $1.isDefaultInput { return $0.isDefaultInput }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The device macOS currently plays system output through, if any.
    public func defaultOutputDeviceID() -> AudioDeviceID? {
        guard let value = try? audioDeviceIDProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        ), value != kAudioObjectUnknown else { return nil }
        return value
    }

    private func inputChannelCount(_ deviceID: AudioDeviceID) throws -> Int {
        var address = propertyAddress(
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeInput
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            throw CoreAudioCatalogError.propertySize(selector: address.mSelector, status: sizeStatus)
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        let readStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, list)
        guard readStatus == noErr else {
            throw CoreAudioCatalogError.propertyRead(selector: address.mSelector, status: readStatus)
        }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = propertyAddress(selector: selector, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else {
            throw CoreAudioCatalogError.propertyRead(selector: selector, status: status)
        }
        return value.takeUnretainedValue() as String
    }

    private func audioDeviceIDProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> AudioDeviceID {
        var address = propertyAddress(selector: selector, scope: scope)
        var value = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw CoreAudioCatalogError.propertyRead(selector: selector, status: status)
        }
        return value
    }

    private func float64Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> Float64 {
        var address = propertyAddress(selector: selector, scope: scope)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw CoreAudioCatalogError.propertyRead(selector: selector, status: status)
        }
        return value
    }

    private func deviceIDs() throws -> [AudioDeviceID] {
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        let selector = kAudioHardwarePropertyDevices
        var address = propertyAddress(selector: selector, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            throw CoreAudioCatalogError.propertySize(selector: selector, status: sizeStatus)
        }
        guard size > 0 else { return [] }

        var values = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.stride
        )
        let readStatus = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard readStatus == noErr else {
            throw CoreAudioCatalogError.propertyRead(selector: selector, status: readStatus)
        }
        return values
    }

    private func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
