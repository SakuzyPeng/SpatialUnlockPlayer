import Foundation
import Combine
import CoreAudio

func fourCC(_ text: String) -> UInt32 {
    text.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
}

struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let channels: Int
    let isHeadphones: Bool
    let hasNativeSpatialAudio: Bool
}

enum SpatialMode: String, CaseIterable, Identifiable, Sendable {
    case automatic, headphones, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "自动"
        case .headphones: "强制耳机空间音频"
        case .off: "关闭"
        }
    }
}

struct SpatialPolicy: Equatable, Sendable {
    let useShim: Bool
    let allowSpatialization: Bool
    let description: String

    static func resolve(mode: SpatialMode, device: AudioOutputDevice?) -> Self {
        guard let device else { return .init(useShim: false, allowSpatialization: false, description: "没有可用输出") }
        if mode == .off { return .init(useShim: false, allowSpatialization: false, description: "空间音频已关闭") }
        if device.hasNativeSpatialAudio { return .init(useShim: false, allowSpatialization: true, description: "使用系统空间音频设置") }
        let force = device.channels == 2 && (mode == .headphones || device.isHeadphones)
        return .init(useShim: force, allowSpatialization: true,
                     description: force ? "普通耳机兼容模式" : (mode == .headphones ? "此输出使用系统原生播放" : "系统原生播放"))
    }
}

@MainActor
final class AudioDeviceCatalog: ObservableObject {
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var defaultUID: String?
    var onChange: (() -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var listener: AudioObjectPropertyListenerBlock?
    private var installedAddresses: [AudioObjectPropertyAddress] = []
    private var deviceListeners: [AudioObjectID: [AudioObjectPropertyAddress]] = [:]

    init() {
        refresh()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        listener = block
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
                installedAddresses.append(address)
            }
        }
        refresh()
    }

    func shutdown() {
        refreshTask?.cancel()
        if let listener {
            for var address in installedAddresses {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            }
            for (device, addresses) in deviceListeners {
                for var address in addresses { AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener) }
            }
        }
        installedAddresses.removeAll(); deviceListeners.removeAll(); listener = nil; onChange = nil
    }

    func resolve(_ selection: String) -> AudioOutputDevice? {
        let uid = selection == "system" ? defaultUID : selection
        return devices.first { $0.uid == uid }
    }

    #if SPATIAL_DIAGNOSTICS
    // Exercise the same catalog callback as a physical removal, without changing
    // any system device. The next real refresh restores the hardware snapshot.
    func diagnosticRemoveDevice(uid: String) {
        devices.removeAll { $0.uid == uid }
        if defaultUID == uid { defaultUID = devices.first { $0.uid == "BuiltInSpeakerDevice" }?.uid }
        onChange?()
    }
    #endif

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        let defaultID = Self.uint(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        let allIDs = Self.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        updateDeviceListeners(allIDs)
        let outputs = allIDs.compactMap { id -> AudioOutputDevice? in
            let streams = Self.ids(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            guard !streams.isEmpty, Self.uint(id, kAudioDevicePropertyDeviceIsAlive) != 0,
                  let uid = Self.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            var channels = 0
            var headphoneTerminal = false
            for stream in streams {
                var a = Self.address(kAudioStreamPropertyVirtualFormat)
                var format = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout.size(ofValue: format))
                if AudioObjectGetPropertyData(stream, &a, 0, nil, &size, &format) == noErr { channels += Int(format.mChannelsPerFrame) }
                headphoneTerminal = headphoneTerminal || Self.uint(stream, kAudioStreamPropertyTerminalType) == kAudioStreamTerminalTypeHeadphones
            }
            guard channels > 0 else { return nil }
            var supported: UInt32 = 0
            let supportStatus = SpatialShimNativeReadUInt32(id, fourCC("spap"), &supported)
            var mode: UInt32 = 0
            let nativeABI = SpatialShimNativeHasProperty(id, fourCC("spen")) && SpatialShimNativeReadUInt32(id, fourCC("spmd"), &mode) == noErr
            return AudioOutputDevice(id: id, uid: uid, name: Self.string(id, kAudioObjectPropertyName) ?? uid,
                                     channels: channels, isHeadphones: headphoneTerminal || uid == "BuiltInHeadphoneOutputDevice",
                                     hasNativeSpatialAudio: supportStatus == noErr ? supported != 0 : nativeABI)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let nextDefault = outputs.first { $0.id == defaultID }?.uid
        guard devices != outputs || defaultUID != nextDefault else { return }
        devices = outputs; defaultUID = nextDefault; onChange?()
    }

    private func updateDeviceListeners(_ ids: [AudioObjectID]) {
        guard let listener else { return }
        let present = Set(ids)
        for device in Array(deviceListeners.keys) where !present.contains(device) {
            for var a in deviceListeners.removeValue(forKey: device) ?? [] {
                AudioObjectRemovePropertyListenerBlock(device, &a, .main, listener)
            }
        }
        for device in ids where deviceListeners[device] == nil {
            guard !Self.ids(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty else { continue }
            var addresses: [AudioObjectPropertyAddress] = []
            for var a in [Self.address(kAudioDevicePropertyDeviceIsAlive),
                          Self.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput),
                          Self.address(fourCC("spap"))] {
                if AudioObjectHasProperty(device, &a), AudioObjectAddPropertyListenerBlock(device, &a, .main, listener) == noErr { addresses.append(a) }
            }
            deviceListeners[device] = addresses
        }
    }

    private static func address(_ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func uint(_ object: AudioObjectID, _ selector: UInt32) -> UInt32 {
        var a = address(selector); var value: UInt32 = 0; var size: UInt32 = 4
        return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr ? value : 0
    }
    private static func string(_ object: AudioObjectID, _ selector: UInt32) -> String? {
        var a = address(selector); var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
    private static func ids(_ object: AudioObjectID, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(selector, scope: scope); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var data = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let result = data.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, bytes.baseAddress!)
        }
        return result == noErr ? Array(data.prefix(Int(size) / 4)) : []
    }
}
