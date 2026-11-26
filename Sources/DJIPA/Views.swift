import SwiftUI

private let kBuiltIn: UInt32 = 0x626C_746E // 'bltn'
private let brand = Color(red: 0.145, green: 0.388, blue: 0.922) // 與圖示相同的藍

struct PanelView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 10) {
            header
            devices
            transport
            levels
            effects
            if !model.message.isEmpty {
                Label(model.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(12)
        .frame(width: 340)
        .tint(brand)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("現場擴音").font(.title3.weight(.semibold))
                Text(model.running ? String(format: "緩衝延遲約 %.0f ms", model.latencyMs) : "麥克風 → 喇叭")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            StatusPill(running: model.running, muted: model.muted)
        }
    }

    private var devices: some View {
        Card {
            DeviceRow(icon: "mic.fill", title: "麥克風", selection: $model.inputUID, devices: model.inputs)
            DeviceRow(icon: "hifispeaker.fill", title: "輸出", selection: $model.outputUID,
                      devices: model.outputs)
            if model.output?.transport == kBuiltIn {
                Label("內建喇叭容易嘯叫", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var transport: some View {
        let canStart = model.input != nil && model.output != nil
        return HStack(spacing: 8) {
            BigButton(title: model.running ? "停止" : "開始擴音",
                      icon: model.running ? "stop.fill" : "play.fill",
                      fill: model.running ? .red : brand,
                      action: model.toggle)
                .disabled(!model.running && !canStart)
            BigButton(title: model.muted ? "取消靜音" : "靜音",
                      icon: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                      fill: model.muted ? .orange : nil,
                      action: { model.muted.toggle() })
                .disabled(!model.running)
                .frame(width: 116)
        }
    }

    private var levels: some View {
        Card {
            Meter(title: "麥克風", level: model.inputLevel,
                  marker: model.gate ? (model.gateDB + 60) / 60 : nil)
            Meter(title: "輸出", level: model.outputLevel, marker: (model.ceilingDB + 60) / 60)
            SliderRow(title: "音量", value: $model.volumeDB, range: -40...18)
            SliderRow(title: "輸出上限", value: $model.ceilingDB, range: -24...(-1))
            if model.limiting {
                Text("限幅中：聲音超過上限，已自動壓低")
                    .font(.caption).foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var effects: some View {
        Card {
            EffectRow(icon: "waveform.path.badge.minus", title: "低頻切除",
                      detail: "濾掉 100 Hz 以下", isOn: $model.highPass)
            Divider()
            EffectRow(icon: "door.left.hand.closed", title: "噪音閘門",
                      detail: !model.gate || !model.running ? "沒講話時降低音量"
                        : String(format: "輸入 %.0f dB，%@", model.inputDB, model.gateOpen ? "開啟" : "關閉"),
                      isOn: $model.gate)
            if model.gate {
                SliderRow(title: "門檻", value: $model.gateDB, range: -70...(-20))
            }
            Divider()
            EffectRow(icon: "ear.badge.waveform", title: "自動嘯叫抑制",
                      detail: !model.howl || !model.running ? "削掉持續的尖銳單音"
                        : model.notches.isEmpty ? "尚未偵測到嘯叫" : "已抑制 \(model.notches.count) 個頻率",
                      isOn: $model.howl)
            if model.howl && !model.notches.isEmpty {
                HStack(alignment: .top) {
                    Text(model.notches.map { "\($0) Hz" }.joined(separator: "、"))
                        .monospacedDigit().foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("清除") { model.clearNotches() }.controlSize(.small)
                }
                .font(.caption)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { model.refresh() } label: { Label("重新整理裝置", systemImage: "arrow.clockwise") }
                .disabled(model.running)
            Spacer()
            Button {
                model.stop()
                NSApplication.shared.terminate(nil)
            } label: { Label("結束", systemImage: "power") }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 4)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 8) { content }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct StatusPill: View {
    let running: Bool
    let muted: Bool

    var body: some View {
        let state: (String, Color) = !running ? ("待機", .secondary)
            : muted ? ("靜音", .orange) : ("擴音中", .green)
        HStack(spacing: 5) {
            Circle().fill(state.1).frame(width: 7, height: 7)
            Text(state.0).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(state.1.opacity(0.15)))
    }
}

struct DeviceRow: View {
    let icon: String
    let title: String
    @Binding var selection: String
    let devices: [AudioDevice]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(brand).frame(width: 18)
            Text(title).frame(width: 50, alignment: .leading)
            Picker(title, selection: $selection) {
                Text("請選擇").tag("")
                ForEach(devices) { Text("\($0.name)（\($0.transportLabel)）").tag($0.uid) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }
}

struct BigButton: View {
    let title: String
    let icon: String
    let fill: Color?
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundColor(fill == nil ? .primary : .white)
                .background(RoundedRectangle(cornerRadius: 9).fill(fill ?? Color.primary.opacity(0.09)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct EffectRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(isOn ? brand : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).monospacedDigit().foregroundColor(.secondary)
            }
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 56, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: "%+.0f dB", value))
                .monospacedDigit().foregroundColor(.secondary).frame(width: 52, alignment: .trailing)
        }
    }
}

/// 分段式音量表；marker 是門檻或上限的位置（0...1）
struct Meter: View {
    let title: String
    let level: Double
    var marker: Double?
    private let count = 32

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 56, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    let position = Double(i) / Double(count)
                    let color: Color = position > 0.9 ? .red : position > 0.75 ? .yellow : .green
                    RoundedRectangle(cornerRadius: 1)
                        .fill(position < level ? color : Color.primary.opacity(0.12))
                }
            }
            .frame(height: 10)
            .overlay(GeometryReader { geo in
                if let marker {
                    Rectangle().fill(Color.primary.opacity(0.7))
                        .frame(width: 2, height: 16)
                        .offset(x: geo.size.width * min(max(marker, 0), 1) - 1, y: -3)
                }
            })
        }
    }
}
