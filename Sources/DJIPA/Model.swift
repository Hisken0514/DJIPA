import AVFoundation
import AudioCore
import CoreAudio
import Foundation

@MainActor
final class Model: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var inputUID = "" { didSet { selectionChanged(oldValue, inputUID, "inputUID") } }
    @Published var outputUID = "" { didSet { selectionChanged(oldValue, outputUID, "outputUID") } }
    @Published var volumeDB: Double { didSet { save(volumeDB, "volumeDB"); apply() } }
    @Published var ceilingDB: Double { didSet { save(ceilingDB, "ceilingDB"); apply() } }
    @Published var muted = false { didSet { apply() } }
    @Published var highPass: Bool { didSet { save(highPass, "highPass"); apply() } }
    @Published var gate: Bool { didSet { save(gate, "gate"); apply() } }
    @Published var gateDB: Double { didSet { save(gateDB, "gateDB"); apply() } }
    @Published var howl: Bool { didSet { save(howl, "howl"); apply() } }
    @Published var gateOpen = false
    @Published var inputDB = -90.0
    @Published var notches: [Int] = []
    @Published var running = false
    @Published var inputLevel = 0.0
    @Published var outputLevel = 0.0
    @Published var limiting = false
    @Published var latencyMs = 0.0
    @Published var message = ""

    private var session: Session?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var limitingUntil = Date.distantPast
    private var lastCallbacks: UInt64 = 0
    private var lastProgress = Date()

    var inputs: [AudioDevice] { devices.filter { $0.inputChannels > 0 } }
    var outputs: [AudioDevice] { devices.filter { $0.outputChannels > 0 } }
    var input: AudioDevice? { inputs.first { $0.uid == inputUID } }
    var output: AudioDevice? { outputs.first { $0.uid == outputUID } }

    init() {
        let d = UserDefaults.standard
        volumeDB = d.object(forKey: "volumeDB") as? Double ?? -12
        ceilingDB = d.object(forKey: "ceilingDB") as? Double ?? -6
        highPass = d.object(forKey: "highPass") as? Bool ?? true
        gate = d.object(forKey: "gate") as? Bool ?? true
        gateDB = d.object(forKey: "gateDB") as? Double ?? -55
        howl = d.object(forKey: "howl") as? Bool ?? true
        refresh()
        var addr = CA.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) {
            [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// 重新讀取裝置清單，必要時自動選擇或停止。
    func refresh() {
        devices = CA.allDevices()
        if running && (input == nil || output == nil) {
            stop()
            message = "裝置已拔除，擴音已停止"
        }
        guard !running else { return }
        // 優先用上次的選擇，其次自動挑 DJI 與 HDMI；不自動選內建喇叭以免嘯叫
        let d = UserDefaults.standard
        let wantedIn = d.string(forKey: "inputUID")
        let pickIn = inputs.first { $0.uid == wantedIn }
            ?? inputs.first { $0.name.contains("Wireless Mic") || $0.name.contains("DJI") }
        let wantedOut = d.string(forKey: "outputUID")
        let pickOut = outputs.first { $0.uid == wantedOut }
            ?? outputs.first { $0.transport == kAudioDeviceTransportTypeHDMI }
            ?? outputs.first { $0.isDisplayOutput }
        autoSelecting = true
        inputUID = pickIn?.uid ?? ""
        outputUID = pickOut?.uid ?? ""
        autoSelecting = false
    }

    private var autoSelecting = false

    private func selectionChanged(_ old: String, _ new: String, _ key: String) {
        guard old != new, !autoSelecting else { return }
        UserDefaults.standard.set(new, forKey: key)
        if running { stop() } // 換裝置後要重新按開始，避免突然大聲
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    func toggle() { running ? stop() : requestStart() }

    private func requestStart() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                if granted {
                    self.start()
                } else {
                    self.message = "沒有麥克風權限：請到 系統設定 → 隱私權與安全性 → 麥克風 開啟"
                }
            }
        }
    }

    private func start() {
        guard !running else { return }
        guard let input, let output else {
            message = "請先選擇麥克風與輸出裝置"
            return
        }
        do {
            session = try Session(input: input, output: output)
        } catch {
            message = error.localizedDescription
            return
        }
        running = true
        muted = false
        message = ""
        latencyMs = session?.latencyMs ?? 0
        lastCallbacks = 0
        lastProgress = Date()
        apply()
        // 擴音期間不讓電腦或螢幕睡眠（螢幕睡眠會讓 HDMI 沒聲音）
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical], reason: "現場擴音中")
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        session?.close()
        session = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        running = false
        inputLevel = 0
        outputLevel = 0
        limiting = false
        gateOpen = false
        inputDB = -90
        notches = []
    }

    func clearNotches() {
        if let engine = session?.engine { pa_clear_notches(engine) }
        notches = []
    }

    private func apply() {
        guard let engine = session?.engine else { return }
        pa_set_gain(engine, Float(pow(10, volumeDB / 20)))
        pa_set_ceiling(engine, Float(pow(10, ceilingDB / 20)))
        pa_set_muted(engine, muted)
        pa_set_highpass(engine, highPass)
        pa_set_gate(engine, gate, Float(pow(10, gateDB / 20)))
        pa_set_howl(engine, howl)
    }

    private func tick() {
        guard let engine = session?.engine else { return }
        // 音量表：-60 dB 到 0 dB 對應 0 到 1，下降時緩降
        func level(_ peak: Float, _ previous: Double) -> Double {
            let db = 20 * log10(max(Double(peak), 0.000001))
            return max(min((db + 60) / 60, 1), previous - 0.05, 0)
        }
        let inPeak = pa_take_input_peak(engine)
        inputLevel = level(inPeak, inputLevel)
        // 輸入音量讀數緩降，方便設定閘門門檻
        inputDB = max(20 * log10(max(Double(inPeak), 0.00003)), inputDB - 1)
        gateOpen = pa_take_gate_open(engine)
        pa_analyze(engine)
        let found = (0..<pa_notch_count()).map { Int(pa_notch_freq(engine, $0).rounded()) }.filter { $0 > 0 }
        if found != notches { notches = found }
        outputLevel = level(pa_take_output_peak(engine), outputLevel)
        if pa_take_limited(engine) { limitingUntil = Date().addingTimeInterval(0.5) }
        limiting = Date() < limitingUntil

        let count = pa_callback_count(engine)
        if count != lastCallbacks {
            lastCallbacks = count
            lastProgress = Date()
        } else if Date().timeIntervalSince(lastProgress) > 2 {
            stop()
            message = "音訊中斷，擴音已停止，請再按一次開始"
        }
    }
}
