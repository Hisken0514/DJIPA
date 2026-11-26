import AudioCore
import CoreAudio
import SwiftUI

@main
struct Main {
    static func main() {
        // --list：只列出音訊裝置，供除錯用
        if CommandLine.arguments.contains("--list") {
            for d in CA.allDevices() {
                print("\(d.name) [\(d.transportLabel)] in=\(d.inputChannels) out=\(d.outputChannels)")
            }
            return
        }
        // --selftest <輸出裝置名稱>：靜音執行 8 秒，檢查取樣率與音訊週期
        if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
            selfTest(outputName: CommandLine.arguments[i + 1])
            return
        }
        // --snapshot <png> [--demo] [--dark]：把面板畫成圖片檢查版面，不會啟動音訊
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { snapshot(to: CommandLine.arguments[i + 1]) }
            return
        }
        DJIPAApp.main()
    }

    private static func selfTest(outputName: String) {
        let all = CA.allDevices()
        guard let mic = all.first(where: { $0.inputChannels > 0 && $0.name.contains("Wireless Mic") }),
              let out = all.first(where: { $0.outputChannels > 0 && $0.name.contains(outputName) })
        else { print("找不到裝置"); return }
        func rate() -> Float64 { CA.value(out.id, kAudioDevicePropertyNominalSampleRate, default: 0) }
        print("輸出 \(out.name)，開始前 \(rate()) Hz")
        do {
            let session = try Session(input: mic, output: out) // 音量預設為 0，不會出聲
            guard let engine = session.engine else { return }
            var overloads = 0
            var addr = CA.address(kAudioDeviceProcessorOverload)
            AudioObjectAddPropertyListenerBlock(session.deviceID, &addr, .main) { _, _ in overloads += 1 }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            let first = pa_callback_count(engine), start = Date()
            overloads = 0
            RunLoop.current.run(until: Date().addingTimeInterval(6))
            let measured = Double(pa_callback_count(engine) - first) / Date().timeIntervalSince(start)
            print("執行中 聚集 \(session.sampleRate) Hz、緩衝 \(session.bufferFrames)，輸出裝置 \(rate()) Hz")
            print(String(format: "每秒回呼 %.1f（預期 %.1f），過載 %d 次",
                         measured, session.sampleRate / Double(session.bufferFrames), overloads))
            session.close()
        } catch {
            print(error.localizedDescription)
        }
        print("結束後 \(rate()) Hz")
    }

    @MainActor private static func snapshot(to path: String) {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        let model = Model()
        if CommandLine.arguments.contains("--demo") { // 只改畫面狀態，不寫入設定
            model.running = true
            model.latencyMs = 11
            model.inputLevel = 0.72
            model.outputLevel = 0.6
            model.inputDB = -18
            model.gateOpen = true
            model.notches = [1250, 3180]
        }
        let host = NSHostingView(rootView: PanelView(model: model)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("\(Int(host.bounds.width)) x \(Int(host.bounds.height))")
    }
}

struct DJIPAApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: !model.running ? "mic" : model.muted ? "mic.slash.fill" : "mic.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
