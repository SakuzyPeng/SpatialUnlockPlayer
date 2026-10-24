import Foundation
import Combine

@MainActor
final class HeadTrackingModel: ObservableObject {
    @Published var portText: String
    @Published var sourceFilter: String
    @Published private(set) var isEnabled = false
    @Published private(set) var snapshot = PoseBridgeSnapshot()
    @Published private(set) var renderer = SpatialHeadPoseGetStatus()
    @Published private(set) var renderingAllowed = false
    private let defaults: UserDefaults
    private let receiver = PoseBridgeReceiver()
    private var generation: UInt64 = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
        portText = String(defaults.object(forKey: "poseBridgePort") == nil ? 9000 : defaults.integer(forKey: "poseBridgePort"))
        sourceFilter = defaults.string(forKey: "poseBridgeSource") ?? ""
        if defaults.bool(forKey: "poseBridgeEnabled") { setEnabled(true) }
    }
    var statusText: String {
        if snapshot.error != nil { return "PoseBridge 接收失败" }
        if !isEnabled { return "系统头部追踪" }
        if !snapshot.listening { return "正在启动接收…" }
        if snapshot.accepted == 0 { return "等待 PoseBridge" }
        if !snapshot.fresh { return "信号中断 · 保持朝向" }
        if !renderingAllowed { return "已接收 · 空间音频未启用" }
        if renderer.lastError != 0 { return "渲染器未接受头部姿态" }
        if renderer.mixers == 0 { return "已接收 · 等待空间渲染器" }
        return "PoseBridge 头部追踪"
    }
    func setEnabled(_ value: Bool) {
        if !value {
            generation &+= 1
            isEnabled = false; defaults.set(false, forKey: "poseBridgeEnabled")
            receiver.stop(); snapshot = .init()
            syncRenderer()
            return
        }
        let text = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(text), port > 0 else {
            snapshot.error = "请输入 1–65535 之间的 UDP 端口。"; return
        }
        guard sourceFilter.isEmpty || PoseBridgeProtocol.validSource(sourceFilter) else {
            snapshot.error = "来源名称须为 1–256 字节，不能全为空白或含控制字符。"; return
        }
        generation &+= 1
        let ticket = generation
        isEnabled = true; snapshot = .init()
        defaults.set(Int(port), forKey: "poseBridgePort")
        defaults.set(sourceFilter, forKey: "poseBridgeSource")
        defaults.set(true, forKey: "poseBridgeEnabled")
        syncRenderer()
        receiver.start(port: port, source: sourceFilter) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket else { return }
                self.snapshot = result
                if result.error != nil {
                    self.isEnabled = false
                    self.defaults.set(false, forKey: "poseBridgeEnabled")
                }
                self.syncRenderer()
            }
        }
    }
    func setRenderingAllowed(_ allowed: Bool) {
        renderingAllowed = allowed
        syncRenderer()
    }
    private func syncRenderer() {
        SpatialHeadPoseSetEnabled(isEnabled && snapshot.listening && renderingAllowed)
        renderer = SpatialHeadPoseGetStatus()
    }
    func recenter() { receiver.recenter() }
    func shutdown() {
        generation &+= 1
        SpatialHeadPoseSetEnabled(false)
        receiver.shutdown()
    }
    func diagnosticSnapshot() -> [String: Any] {
        let status = SpatialHeadPoseGetStatus()
        return ["poseListening": snapshot.listening, "poseFresh": snapshot.fresh,
                "poseSource": snapshot.source, "poseAccepted": snapshot.accepted, "poseInvalid": snapshot.invalid,
                "poseIgnored": snapshot.ignored, "poseRecenters": snapshot.recenters,
                "poseReferences": snapshot.referenceChanges, "poseEnabled": status.enabled != 0,
                "poseMixers": status.mixers, "posePublished": status.published, "poseApplied": status.applied,
                "poseRestored": status.restored, "poseRenderCallbacks": status.renderCallbacks,
                "poseFailures": status.failures, "poseError": snapshot.error ?? "", "hasPoseError": snapshot.error != nil,
                "poseQuaternion": [snapshot.head.inverse.x, snapshot.head.inverse.y, snapshot.head.inverse.z, snapshot.head.inverse.w]]
    }
}
