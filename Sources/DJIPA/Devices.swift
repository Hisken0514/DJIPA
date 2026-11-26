import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let transport: UInt32

    var isDisplayOutput: Bool {
        transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort
    }
    var transportLabel: String {
        switch transport {
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBuiltIn: return "內建"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "藍牙"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        default: return "其他"
        }
    }
}

enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         default initial: T) -> T {
        var addr = address(selector)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        return err == noErr ? result : initial
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        let ref: Unmanaged<CFString>? = value(id, selector, default: nil)
        return (ref?.takeRetainedValue() as String?) ?? ""
    }

    static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func allDevices() -> [AudioDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let transport: UInt32 = value(id, kAudioDevicePropertyTransportType, default: 0)
            // 聚集裝置（包含本程式建立的）不列入選單
            if transport == kAudioDeviceTransportTypeAggregate { return nil }
            return AudioDevice(id: id,
                               uid: string(id, kAudioDevicePropertyDeviceUID),
                               name: string(id, kAudioObjectPropertyName),
                               inputChannels: channels(id, kAudioObjectPropertyScopeInput),
                               outputChannels: channels(id, kAudioObjectPropertyScopeOutput),
                               transport: transport)
        }
    }
}
