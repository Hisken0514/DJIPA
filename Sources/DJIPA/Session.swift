import AudioCore
import CoreAudio
import Foundation

struct SessionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 一次擴音：建立私有聚集裝置（麥克風 + 喇叭），在上面跑音訊回呼。
final class Session {
    private var aggregate: AudioObjectID = 0
    private(set) var engine: OpaquePointer?
    private(set) var latencyMs: Double = 0
    private(set) var sampleRate: Double = 0
    private(set) var bufferFrames: UInt32 = 0
    var deviceID: AudioObjectID { aggregate }

    init(input: AudioDevice, output: AudioDevice) throws {
        let sameDevice = input.uid == output.uid
        // 沿用輸出裝置目前的取樣率。強制改掉會讓藍牙耳機（常為 44.1 kHz）斷斷續續，
        // 而且影響其他正在播放的程式
        let outputRate: Float64 = CA.value(output.id, kAudioDevicePropertyNominalSampleRate, default: 48000)
        let bluetooth = [input, output].contains {
            $0.transport == kAudioDeviceTransportTypeBluetooth
                || $0.transport == kAudioDeviceTransportTypeBluetoothLE
        }
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: input.uid]]
        if !sameDevice {
            // 以輸出裝置為時脈來源，麥克風做漂移補償
            subDevices[0][kAudioSubDeviceDriftCompensationKey] = 1
            subDevices.append([kAudioSubDeviceUIDKey: output.uid])
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "現場擴音 (內部)",
            kAudioAggregateDeviceUIDKey: "local.djipa.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1, // 不出現在系統設定，程式結束即消失
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
        var err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard err == noErr else { throw SessionError(message: "無法合併音訊裝置（錯誤 \(err)）") }

        // 聚集裝置建立後需要一點時間才會列出所有聲道
        let expectedIn = input.inputChannels + (sameDevice ? 0 : output.inputChannels)
        let expectedOut = output.outputChannels + (sameDevice ? 0 : input.outputChannels)
        let deadline = Date().addingTimeInterval(3)
        while CA.channels(aggregate, kAudioObjectPropertyScopeInput) < expectedIn
                || CA.channels(aggregate, kAudioObjectPropertyScopeOutput) < expectedOut {
            if Date() > deadline {
                close()
                throw SessionError(message: "音訊裝置沒有回應，請重新插拔後再試")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        func currentRate() -> Float64 {
            CA.value(aggregate, kAudioDevicePropertyNominalSampleRate, default: outputRate)
        }
        if currentRate() != outputRate {
            setProperty(kAudioDevicePropertyNominalSampleRate, outputRate)
            let rateDeadline = Date().addingTimeInterval(2)
            while currentRate() != outputRate && Date() < rateDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        // 藍牙需要較大的緩衝才穩定
        setProperty(kAudioDevicePropertyBufferFrameSize, UInt32(bluetooth ? 1024 : 256))
        let rate = currentRate()
        let frames: UInt32 = CA.value(aggregate, kAudioDevicePropertyBufferFrameSize, default: 512)
        latencyMs = Double(frames) * 2 / rate * 1000
        sampleRate = rate
        bufferFrames = frames

        // 麥克風排第一，聲道從 0 開始；喇叭聲道接在麥克風自己的輸出之後
        engine = pa_create(0, UInt32(input.inputChannels),
                           UInt32(sameDevice ? 0 : input.outputChannels),
                           UInt32(output.outputChannels), rate)
        guard let engine else {
            close()
            throw SessionError(message: "記憶體不足")
        }
        err = pa_start(engine, aggregate)
        guard err == noErr else {
            close()
            throw SessionError(message: "無法開始播放（錯誤 \(err)）")
        }
    }

    private func setProperty<T>(_ selector: AudioObjectPropertySelector, _ newValue: T) {
        var addr = CA.address(selector)
        var v = newValue
        _ = withUnsafePointer(to: &v) {
            AudioObjectSetPropertyData(aggregate, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }

    func close() {
        if let engine {
            pa_destroy(engine)
            self.engine = nil
        }
        if aggregate != 0 {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = 0
        }
    }

    deinit { close() }
}
