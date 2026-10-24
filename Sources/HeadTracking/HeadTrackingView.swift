import SwiftUI

struct HeadTrackingControl: View {
    @ObservedObject var model: HeadTrackingModel
    @State private var showingSettings = false
    var body: some View {
        Button { showingSettings.toggle() } label: {
            Label("头部追踪", systemImage: model.isEnabled ? "headphones.circle.fill" : "headphones.circle")
        }
        .help(model.statusText)
        .accessibilityIdentifier("headTrackingSettings")
        .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("PoseBridge 头部追踪").font(.headline)
                Toggle("接收外部姿态", isOn: Binding(get: { model.isEnabled }, set: model.setEnabled))
                    .accessibilityIdentifier("poseBridgeEnabled")
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("UDP 端口").foregroundStyle(.secondary)
                        TextField("9000", text: $model.portText).frame(width: 100)
                            .accessibilityIdentifier("poseBridgePort")
                    }
                    GridRow {
                        Text("来源名称").foregroundStyle(.secondary)
                        TextField("自动选择", text: $model.sourceFilter).frame(width: 210)
                            .accessibilityIdentifier("poseBridgeSource")
                    }
                }
                .textFieldStyle(.roundedBorder).disabled(model.isEnabled)
                Text("仅接收 127.0.0.1。来源留空时，锁定第一个有效姿态来源。关闭接收后可修改设置。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                Label(model.statusText, systemImage: model.snapshot.fresh ? "dot.radiowaves.left.and.right" : "circle.dotted")
                    .font(.callout).accessibilityIdentifier("poseBridgeStatus")
                if let error = model.snapshot.error {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if !model.snapshot.source.isEmpty {
                    Text(model.snapshot.source).font(.caption.monospaced()).textSelection(.enabled)
                    let angles = model.snapshot.head.physicalEuler
                    Text(String(format: "左右 %.1f°   俯仰 %.1f°   侧倾 %.1f°", angles.yaw, angles.pitch, angles.roll))
                        .font(.caption.monospacedDigit())
                    HStack {
                        if let age = model.snapshot.ageMilliseconds {
                            Text(age < 10000 ? String(format: "姿态年龄 %.0f ms", age) : "姿态已过期")
                        }
                        Spacer()
                        Text(model.snapshot.heartbeatAlive ? "状态心跳正常" : "未收到近期状态心跳")
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Button("回正", action: model.recenter).disabled(!model.snapshot.fresh)
                        .accessibilityIdentifier("poseBridgeRecenter")
                    Spacer()
                    Text("面向屏幕后回正").font(.caption).foregroundStyle(.secondary)
                }
                Text("首次接收时建立正前方；信号超过 500 ms 未更新时保持最后朝向。关闭接收则恢复系统头部追踪。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18).frame(width: 370)
        }
    }
}
