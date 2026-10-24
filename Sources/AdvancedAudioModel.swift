import Foundation
import Combine

struct AdvancedRenderSnapshot: Equatable {
    var generation: UInt64 = 0
    var mixers: UInt32 = 0
    var actualHRTF: Int32 = -1
    var hrtfError: Int32 = 0
    var headroomState: UInt32 = UInt32(SpatialRenderInactive)
    var headroomError: Int32 = 0
    var preGain: Float = 0
    var postGain: Float = 0
    var rollbackFailed = false
    var needsRebuild = false
}

@MainActor
final class AdvancedAudioModel: ObservableObject {
    @Published private(set) var deviceUID: String?
    @Published private(set) var deviceName = "未选择输出设备"
    @Published private(set) var settings = AdvancedAudioSettings.defaults
    @Published private(set) var renderingAllowed = false
    @Published private(set) var renderer = AdvancedRenderSnapshot()
    @Published private(set) var context = EQPlaybackContext()
    var onChange: (() -> Void)?
    var onRecovery: (() -> Void)?
    var playbackContext: (() -> EQPlaybackContext)?
    private let defaults: UserDefaults
    private var devices: [String: AdvancedAudioSettings]
    private var timer: AnyCancellable?
    private var generation: UInt64 = 0
    private var recoverySetting: AdvancedAudioSettings?

    init(defaults: UserDefaults) {
        self.defaults = defaults; devices = AdvancedAudioPreferences.load(defaults)
        timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
    }
    func setDevice(_ device: AudioOutputDevice?, allowed: Bool) {
        if deviceUID != device?.uid {
            deviceUID = device?.uid; recoverySetting = nil
            settings = device.flatMap { devices[$0.uid] } ?? .defaults
            renderer = .init()
        }
        deviceName = device?.name ?? "未选择输出设备"; renderingAllowed = allowed
    }
    private func commit(_ next: AdvancedAudioSettings, uid: String) {
        guard deviceUID == uid, settings != next else { return }
        recoverySetting = nil; settings = next
        if next == .defaults { devices.removeValue(forKey: uid) } else { devices[uid] = next }
        AdvancedAudioPreferences.save(devices, to: defaults); onChange?()
    }
    func setHeadroomMode(_ mode: AudioHeadroomMode, uid: String) {
        var next = settings; next.headroomMode = mode; commit(next, uid: uid)
    }
    @discardableResult func setHeadroomDB(_ value: Double, uid: String) -> Bool {
        guard deviceUID == uid, let valid = AdvancedAudioSettings.validatedHeadroom(value) else { return false }
        var next = settings; next.headroomMode = .custom; next.headroomDB = valid; commit(next, uid: uid); return true
    }
    func setHRTFMode(_ mode: AudioHRTFMode, uid: String) {
        var next = settings; next.hrtfMode = mode; commit(next, uid: uid)
    }
    func reset(uid: String) { commit(.defaults, uid: uid) }
    func configure(generation: UInt64, deviceID: UInt32, allowed: Bool) {
        self.generation = generation
        SpatialRenderConfigure(.init(generation: generation, deviceID: deviceID, allowed: allowed ? 1 : 0,
            hrtfMode: settings.hrtfMode.nativeValue,
            customHeadroom: settings.headroomMode == .custom && recoverySetting != settings ? 1 : 0,
            headroomDB: Float(settings.headroomDB)))
        refresh()
    }
    func invalidate(generation: UInt64) {
        self.generation = generation
        SpatialRenderConfigure(.init(generation: generation, deviceID: 0, allowed: 0,
            hrtfMode: -1, customHeadroom: 0, headroomDB: 20))
        renderer = .init()
    }
    func refresh() {
        let nextContext = playbackContext?() ?? .init()
        if context != nextContext { context = nextContext }
        SpatialRenderRefreshStatus(); let s = SpatialRenderGetStatus()
        guard s.generation == generation else { return }
        let next = AdvancedRenderSnapshot(generation: s.generation, mixers: s.headphoneMixers,
            actualHRTF: s.actualHRTF, hrtfError: s.hrtfError, headroomState: s.headroomState,
            headroomError: s.headroomError, preGain: s.actualPreGainDB.isFinite ? s.actualPreGainDB : 0,
            postGain: s.actualPostGainDB.isFinite ? s.actualPostGainDB : 0, rollbackFailed: s.rollbackFailed != 0,
            needsRebuild: s.needsRebuild != 0)
        if renderer != next { renderer = next }
        if (next.rollbackFailed || next.needsRebuild) && recoverySetting != settings {
            recoverySetting = settings; onRecovery?()
        }
    }
    var hrtfStatus: String {
        guard renderingAllowed else { return "当前路径未应用 HRTF 调节" }
        if !context.hasItem || context.loading { return "等待耳机空间渲染" }
        if renderer.mixers == 0 { return context.playing ? "当前路径未使用耳机空间渲染" : "等待耳机空间渲染" }
        if renderer.actualHRTF == 1 { return "当前使用个性化 HRTF" }
        if renderer.actualHRTF == 0 {
            return settings.hrtfMode == .personalized ? "已请求个性化 · 当前使用通用 HRTF" : "当前使用通用 HRTF"
        }
        return "无法确认当前 HRTF"
    }
    var headroomStatus: String {
        guard renderingAllowed else { return "当前路径未应用处理余量" }
        if recoverySetting == settings { return "未应用 · 已恢复系统处理" }
        if settings.headroomMode == .system { return "处理余量由系统决定" }
        if !context.hasItem || context.loading { return "等待播放" }
        switch renderer.headroomState {
        case UInt32(SpatialRenderApplied): return String(format: "已生效 · 处理余量 %.1f dB", settings.headroomDB)
        case UInt32(SpatialRenderFailed): return "未应用 · 已保留系统处理"
        case UInt32(SpatialRenderUnavailable): return "当前播放链不支持余量调节"
        default: return renderer.mixers == 0 ? (context.playing ? "当前路径未使用耳机空间渲染" : "等待耳机空间渲染") : "等待处理链准备"
        }
    }
    func shutdown() { timer?.cancel(); timer = nil; invalidate(generation: generation &+ 1) }
    func diagnosticSnapshot() -> [String: Any] {
        refresh()
        return ["advancedUID": deviceUID ?? "", "advancedHeadroomMode": settings.headroomMode.rawValue,
            "advancedHeadroomDB": settings.headroomDB, "advancedHRTFMode": settings.hrtfMode.rawValue,
            "advancedHRTFActual": renderer.actualHRTF, "advancedHRTFError": renderer.hrtfError,
            "advancedHeadroomState": renderer.headroomState, "advancedHeadroomError": renderer.headroomError,
            "advancedPreGain": renderer.preGain, "advancedPostGain": renderer.postGain,
            "advancedHRTFStatus": hrtfStatus, "advancedHeadroomStatus": headroomStatus,
            "advancedGeneration": renderer.generation]
    }
}
