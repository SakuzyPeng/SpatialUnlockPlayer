import SwiftUI

struct EqualizerControl: View {
    @ObservedObject var model: EqualizerModel
    @State private var showing = false
    var body: some View {
        Button { showing.toggle(); model.refresh() } label: {
            Label("EQ", systemImage: "slider.horizontal.3").foregroundStyle(model.isApplied ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain).help(model.statusText).accessibilityIdentifier("equalizerSettings")
        .popover(isPresented: $showing, arrowEdge: .top) { EqualizerPanel(model: model) }
    }
}

private struct EqualizerPanel: View {
    @ObservedObject var model: EqualizerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("参数 EQ").font(.headline)
                Spacer()
                Button("导入…", action: model.presentImportPanel).accessibilityIdentifier("importEQ")
            }
            HStack {
                Toggle("启用 EQ", isOn: Binding(get: { model.isEnabled }, set: model.setEnabled))
                    .disabled(model.preset == nil).accessibilityIdentifier("eqEnabled")
                Spacer()
                Text(model.statusText).font(.caption).foregroundStyle(model.isApplied ? Color.accentColor : .secondary)
                    .accessibilityIdentifier("eqStatus")
            }
            if let error = model.importError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let detail = model.detailText { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let preset = model.preset {
                Divider()
                Text(preset.name).font(.callout.weight(.medium)).lineLimit(2).textSelection(.enabled)
                    .accessibilityIdentifier("eqPresetName")
                HStack {
                    Text("前级 \(number(preset.preamp)) dB")
                    Spacer()
                    Text(model.isPreview ? "48 kHz 预览" : "\(number(model.sampleRate / 1000)) kHz")
                }.font(.caption).foregroundStyle(.secondary)
                EqualizerCurve(preset: preset, sampleRate: model.sampleRate).frame(height: 170)
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 0) {
                    GridRow {
                        Text("#").frame(width: 25, alignment: .trailing)
                        Text("类型").frame(width: 40, alignment: .trailing)
                        Text("频率 Hz").frame(width: 90, alignment: .trailing)
                        Text("增益 dB").frame(width: 75, alignment: .trailing)
                        Text("Q").frame(width: 55, alignment: .trailing)
                    }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ScrollView {
                        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 7) {
                            ForEach(preset.filters) { filter in
                                GridRow {
                                    Text("\(filter.id)").frame(width: 25, alignment: .trailing)
                                    Text(filter.type.rawValue).frame(width: 40, alignment: .trailing)
                                    Text(number(filter.frequency)).frame(width: 90, alignment: .trailing)
                                    Text(number(filter.gain)).frame(width: 75, alignment: .trailing)
                                    Text(number(filter.q)).frame(width: 55, alignment: .trailing)
                                }
                                .foregroundStyle(filter.enabled ? .primary : .tertiary)
                                .help(filter.enabled ? "启用" : "文件中设为 OFF，不参与处理")
                            }
                        }.font(.caption.monospacedDigit()).padding(.vertical, 4)
                    }.frame(height: min(220, CGFloat(preset.filters.count) * 23 + 8)).gridCellColumns(5)
                }
                Text("总响应包含前级增益；灰色滤波器为文件中的 OFF 项。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("导入 AutoEQ / Equalizer APO 参数文本，支持 PK、LSC、HSC 和前级增益。")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            }
        }
        .padding(18).frame(width: 480).background(Color(nsColor: .windowBackgroundColor))
    }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...6))) }
}

private struct EqualizerCurve: View {
    let preset: EqualizerPreset
    let sampleRate: Double
    var body: some View {
        let upper = min(20000, sampleRate * 0.499)
        let frequencies = (0..<320).map { 20 * pow(upper / 20, Double($0) / 319) }
        if let response = preset.response(frequencies: frequencies, sampleRate: sampleRate), response.allSatisfy(\.isFinite) {
            let low = min(-12, floor((response.min() ?? -12) / 6) * 6)
            let high = max(6, ceil((response.max() ?? 6) / 6) * 6)
            Canvas { context, size in
                let inset: CGFloat = 32, bottom: CGFloat = 22
                let width = size.width - inset - 8, height = size.height - bottom - 8
                func x(_ f: Double) -> CGFloat { inset + width * log(f / 20) / log(upper / 20) }
                func y(_ gain: Double) -> CGFloat { 4 + height * (high - gain) / (high - low) }
                for gain in stride(from: low, through: high, by: 6) {
                    var line = Path(); line.move(to: CGPoint(x: inset, y: y(gain))); line.addLine(to: CGPoint(x: size.width - 8, y: y(gain)))
                    context.stroke(line, with: .color(.secondary.opacity(gain == 0 ? 0.4 : 0.15)), lineWidth: 1)
                    context.draw(Text("\(Int(gain))").font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: 15, y: y(gain)))
                }
                for frequency in [20.0, 100, 1000, 10000, 20000] where frequency <= upper {
                    let label = frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
                    context.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: x(frequency), y: size.height - 7))
                }
                var curve = Path()
                for i in frequencies.indices {
                    let point = CGPoint(x: x(frequencies[i]), y: y(response[i]))
                    if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(.accentColor), lineWidth: 2)
            }
            .accessibilityLabel("包含前级的 EQ 总频率响应，20 Hz 至 \(Int(upper)) Hz")
        } else {
            Text("当前采样率无法显示这组滤波参数的响应。")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
