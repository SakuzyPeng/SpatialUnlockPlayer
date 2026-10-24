import AppKit
import Combine
import UniformTypeIdentifiers

struct EQPlaybackContext: Equatable {
    var hasItem = false
    var playing = false
    var loading = false
}

@MainActor
final class EqualizerModel: ObservableObject {
    @Published private(set) var preset: EqualizerPreset?
    @Published private(set) var isEnabled = false
    @Published private(set) var renderer = SpatialEQGetStatus()
    @Published private(set) var renderingAllowed = false
    @Published private(set) var context = EQPlaybackContext()
    @Published var importError: String?
    var playbackContext: (() -> EQPlaybackContext)?
    private let defaults: UserDefaults
    private var timer: AnyCancellable?
    private struct Saved: Codable { var version = 1; let preset: EqualizerPreset; let enabled: Bool }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "parametricEQ"), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           saved.version == 1, (try? saved.preset.validate()) != nil {
            preset = saved.preset; isEnabled = saved.enabled
            _ = publish(saved.preset, enabled: false)
        } else { SpatialEQSetEnabled(false) }
        timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
    }

    var isApplied: Bool { isEnabled && renderingAllowed && renderer.activeMixers > 0 && renderer.lastError == 0 }
    var sampleRate: Double { context.hasItem && renderer.sampleRate > 0 ? renderer.sampleRate : 48000 }
    var isPreview: Bool { !context.hasItem || renderer.sampleRate <= 0 }
    var statusText: String {
        if preset == nil { return "未导入 EQ 配置" }
        if !isEnabled { return "EQ 已关闭" }
        if !renderingAllowed { return "当前播放路径未应用 EQ" }
        if !context.hasItem || context.loading { return "已启用 · 等待播放" }
        if renderer.lastError != 0 { return "当前播放路径未应用 EQ" }
        if isApplied { return context.playing ? "EQ 已生效" : "EQ 已生效 · 播放已暂停" }
        if !context.playing { return "已启用 · 播放已暂停" }
        return renderer.mixers == 0 ? "当前播放路径未应用 EQ" : "已启用 · 等待空间渲染" }
    var detailText: String? {
        guard isEnabled, preset != nil else { return nil }
        if !renderingAllowed { return "EQ 仅用于空间音频播放。配置与开关会保留。" }
        switch renderer.lastError {
        case Int32(SpatialEQFormat): return "当前空间音频输出格式不支持此 EQ。"
        case Int32(SpatialEQFrequency): return "配置中的频率超出当前采样率可处理的范围。"
        case Int32(SpatialEQCoefficientsInvalid): return "当前采样率下无法使用这组滤波参数。"
        case Int32(SpatialEQRenderError), Int32(SpatialEQBuffer), Int32(SpatialEQNonFinite): return "当前音频处理不可用，已旁路 EQ。"
        default: return nil
        }
    }

    private func publish(_ preset: EqualizerPreset, enabled: Bool) -> Bool {
        let filters = preset.filters.map(\.native)
        return filters.withUnsafeBufferPointer { SpatialEQSetConfiguration($0.baseAddress, UInt32($0.count), preset.preamp, enabled) }
    }
    private func save() {
        guard let preset, let data = try? JSONEncoder().encode(Saved(preset: preset, enabled: isEnabled)) else { return }
        defaults.set(data, forKey: "parametricEQ")
    }
    func importPreset(_ url: URL) throws {
        let limit = 65536
        if (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > limit {
            throw EQImportError(line: nil, reason: "EQ 文件须小于 64 KiB。")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= limit, let text = String(data: data, encoding: .utf8) else {
            throw EQImportError(line: nil, reason: "请选择小于 64 KiB 的 UTF-8 参数 EQ 文本。")
        }
        let candidate = try EqualizerPreset.parse(text, name: url.deletingPathExtension().lastPathComponent)
        guard publish(candidate, enabled: renderingAllowed) else {
            throw EQImportError(line: nil, reason: "滤波参数无效，原配置已保留。")
        }
        preset = candidate; isEnabled = true; importError = nil; save(); refresh()
    }
    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "导入参数 EQ"; panel.prompt = "导入"
        panel.allowedContentTypes = [.plainText]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do { try self.importPreset(url) } catch { self.importError = error.localizedDescription }
        }
    }
    func setEnabled(_ value: Bool) {
        guard preset != nil else { return }
        isEnabled = value; SpatialEQSetEnabled(value && renderingAllowed); save(); refresh()
    }
    func setRenderingAllowed(_ value: Bool) {
        renderingAllowed = value; SpatialEQSetEnabled(isEnabled && value); refresh()
    }
    func refresh() {
        let nextContext = playbackContext?() ?? .init()
        if context != nextContext { context = nextContext }
        let next = SpatialEQGetStatus()
        // Render counters change every block; they must not redraw the curve or
        // recreate accessibility elements while the user operates the panel.
        if renderer.enabled != next.enabled || renderer.mixers != next.mixers || renderer.activeMixers != next.activeMixers ||
            renderer.lastError != next.lastError || renderer.sampleRate != next.sampleRate || renderer.generation != next.generation {
            renderer = next
        }
    }
    func shutdown() { timer?.cancel(); timer = nil; SpatialEQSetEnabled(false) }
    func diagnosticSnapshot() -> [String: Any] {
        refresh()
        let status = SpatialEQGetStatus()
        return ["eqName": preset?.name ?? "", "eqEnabled": isEnabled, "eqApplied": isApplied,
                "eqFilterCount": preset?.filters.count ?? 0, "eqPreamp": preset?.preamp ?? 0,
                "eqStatus": statusText, "eqSampleRate": sampleRate, "eqError": renderer.lastError,
                "eqBuffers": status.processedBuffers, "eqFrames": status.processedFrames,
                "eqMinFrames": status.minFrames, "eqMaxFrames": status.maxFrames]
    }
}
