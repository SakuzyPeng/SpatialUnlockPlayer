import AppKit
import Combine
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class PlayerModel: ObservableObject {
    let devices = AudioDeviceCatalog()
    @Published private(set) var playlist: [PlaylistEntry] = []
    @Published private(set) var currentID: UUID?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var metadata = MediaMetadata()
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isSeeking = false
    @Published private(set) var isPlaying = false
    @Published private(set) var wantsToPlay = false
    @Published private(set) var spatialMode: SpatialMode
    @Published private(set) var outputSelection: String
    @Published private(set) var policy = SpatialPolicy.resolve(mode: .automatic, device: nil)
    @Published var errorMessage: String?
    @Published var volume: Float {
        didSet {
            player?.volume = volume
            defaults.set(volume, forKey: "volume")
        }
    }

    private let defaults: UserDefaults
    private var generation: UInt64 = 0
    private var seekSerial: UInt64 = 0
    private var readyGeneration: UInt64?
    private var activeDevice: AudioOutputDevice?
    private var loadTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var itemObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var shuttingDown = false
    private var errorDetails = ""
    private var lastSessionSave: TimeInterval = 0

    var currentEntry: PlaylistEntry? { playlist.first { $0.id == currentID } }
    var currentIndex: Int? { playlist.firstIndex { $0.id == currentID } }
    var canGoPrevious: Bool { (currentIndex ?? 0) > 0 }
    var canGoNext: Bool { currentIndex.map { $0 + 1 < playlist.count } ?? !playlist.isEmpty }
    var isReady: Bool { player?.currentItem?.status == .readyToPlay && !isLoading && !isSeeking }
    var selectedOutput: AudioOutputDevice? { devices.resolve(outputSelection) }
    var displayTitle: String { metadata.title.isEmpty ? currentEntry?.title ?? "SpatialPlayer" : metadata.title }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.volume = defaults.object(forKey: "volume") == nil ? 0.1 : min(1, max(0, defaults.float(forKey: "volume")))
        self.spatialMode = SpatialMode(rawValue: defaults.string(forKey: "spatialMode") ?? "") ?? .automatic
        let saved = defaults.string(forKey: "outputUID") ?? "system"
        self.outputSelection = saved == "system" || devices.devices.contains(where: { $0.uid == saved }) ? saved : "system"
        activeDevice = selectedOutput
        policy = SpatialPolicy.resolve(mode: spatialMode, device: activeDevice)
        devices.onChange = { [weak self] in self?.devicesChanged() }
        if let session = PlaybackSession.load(from: defaults) {
            playlist = session.entries
            currentID = session.currentID
            position = session.position
            if currentEntry != nil { rebuild(at: position, autoplay: false) }
        }
    }

    private func saveSession() {
        PlaybackSession(entries: playlist, currentID: currentID, position: position).save(to: defaults)
        lastSessionSave = ProcessInfo.processInfo.systemUptime
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "加入播放列表"
        panel.prompt = "打开"
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addFiles(panel.urls)
        }
    }

    func addFiles(_ urls: [URL]) {
        let localFiles = urls.filter { url in
            guard url.isFileURL else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard !localFiles.isEmpty else { errorMessage = "请选择本地音频或视频文件。"; return }
        defer { saveSession() }
        let wasEmpty = playlist.isEmpty
        let entries = localFiles.map { PlaylistEntry(url: $0.standardizedFileURL) }
        playlist.append(contentsOf: entries)
        if wasEmpty, let first = entries.first { select(first.id) }
    }

    func importDrop(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        continuation.resume(returning: url)
                    }
                }
                if let url { urls.append(url) }
            }
            addFiles(urls)
        }
    }

    func select(_ id: UUID, autoplay: Bool = true) {
        guard playlist.contains(where: { $0.id == id }) else { return }
        defer { saveSession() }
        currentID = id
        metadata = MediaMetadata(); position = 0; duration = 0
        rebuild(at: 0, autoplay: autoplay)
    }

    func remove(_ ids: Set<UUID>) {
        defer { saveSession() }
        let oldIndex = currentIndex ?? 0
        let removingCurrent = currentID.map { ids.contains($0) } ?? false
        let resume = wantsToPlay
        playlist.removeAll { ids.contains($0.id) }
        if playlist.isEmpty { clear() }
        else if removingCurrent { select(playlist[min(oldIndex, playlist.count - 1)].id, autoplay: resume) }
    }

    func clear() {
        invalidatePlayback()
        playlist.removeAll(); currentID = nil; metadata = MediaMetadata()
        position = 0; duration = 0; wantsToPlay = false; isLoading = false; isSeeking = false; errorMessage = nil
        SpatialShimSetConfiguration(0, false)
        saveSession()
    }

    func togglePlayback() {
        if wantsToPlay { pause() } else { play() }
    }
    func play() {
        guard currentEntry != nil else {
            if let first = playlist.first { select(first.id) }
            return
        }
        guard selectedOutput != nil else { errorMessage = "所选输出设备不可用，请选择另一个输出。"; return }
        wantsToPlay = true
        if player == nil { rebuild(at: position, autoplay: true) }
        else if duration > 0 && position >= duration - 0.05 { seek(to: 0) }
        else if !isLoading && !isSeeking { player?.play() }
    }
    func pause() {
        wantsToPlay = false; player?.pause(); isPlaying = false
        if !isLoading, !isSeeking, let time = player?.currentTime().seconds, time.isFinite { position = max(0, time) }
        saveSession()
    }
    func previous() {
        guard let index = currentIndex, index > 0 else { return }
        select(playlist[index - 1].id)
    }
    func next() {
        guard let index = currentIndex else { if let first = playlist.first { select(first.id) }; return }
        guard index + 1 < playlist.count else { pause(); return }
        select(playlist[index + 1].id)
    }

    func seek(to requested: Double) {
        guard requested.isFinite, duration > 0, let player, player.currentItem?.status == .readyToPlay, !isLoading else { return }
        let target = min(max(0, requested), duration)
        seekSerial &+= 1
        let serial = seekSerial, ticket = generation
        isSeeking = true; position = target
        saveSession()
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            Task { @MainActor in
                guard let self, let player, self.generation == ticket, self.seekSerial == serial, self.player === player else { return }
                self.isSeeking = false
                if finished {
                    let time = player.currentTime().seconds
                    if time.isFinite { self.position = time }
                    if self.wantsToPlay { player.play() } else { player.pause() }
                    self.saveSession()
                } else {
                    self.pause(); self.errorMessage = "无法定位到该位置，请重试。"
                }
            }
        }
    }

    func setMode(_ mode: SpatialMode) {
        guard mode != spatialMode else { return }
        spatialMode = mode; defaults.set(mode.rawValue, forKey: "spatialMode")
        updateRoute(rebuildCurrent: true)
    }
    func setOutput(_ uid: String) {
        guard uid != outputSelection else { return }
        outputSelection = uid; defaults.set(uid, forKey: "outputUID")
        updateRoute(rebuildCurrent: true)
    }
    private func updateRoute(rebuildCurrent: Bool) {
        policy = SpatialPolicy.resolve(mode: spatialMode, device: selectedOutput)
        if rebuildCurrent, currentEntry != nil { rebuild(at: position, autoplay: wantsToPlay) }
        else { activeDevice = selectedOutput; SpatialShimSetConfiguration(0, false) }
    }
    private func devicesChanged() {
        guard !shuttingDown else { return }
        let nextDevice = selectedOutput
        let nextPolicy = SpatialPolicy.resolve(mode: spatialMode, device: nextDevice)
        guard nextDevice != activeDevice || nextPolicy != policy else { objectWillChange.send(); return }
        let removed = activeDevice.map { old in !devices.devices.contains(where: { $0.uid == old.uid }) } ?? false
        policy = nextPolicy
        if removed, currentEntry != nil {
            invalidatePlayback()
            activeDevice = nextDevice; wantsToPlay = false; isLoading = false; isSeeking = false
            SpatialShimSetConfiguration(0, false)
            errorMessage = "输出设备已断开，播放已暂停。"
        } else { updateRoute(rebuildCurrent: true) }
    }

    private func rebuild(at restoredPosition: Double, autoplay: Bool) {
        guard let entry = currentEntry else { return }
        invalidatePlayback()
        let ticket = generation
        wantsToPlay = autoplay; isLoading = true; isSeeking = false; errorMessage = nil; errorDetails = ""
        readyGeneration = nil; position = restoredPosition
        guard let device = selectedOutput else {
            activeDevice = nil; wantsToPlay = false; isLoading = false
            SpatialShimSetConfiguration(0, false)
            errorMessage = "所选输出设备不可用，请选择另一个输出。"
            return
        }
        activeDevice = device
        policy = SpatialPolicy.resolve(mode: spatialMode, device: device)
        SpatialShimSetConfiguration(device.id, policy.useShim)
        let asset = AVURLAsset(url: entry.url)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.generation == ticket, self.isLoading else { return }
            self.fail("加载超时。请检查文件和输出设备是否仍然可用。", ticket: ticket)
        }
        loadTask = Task { [weak self] in
            do {
                let info = try await MediaMetadata.load(asset: asset)
                guard let self, !Task.isCancelled, self.generation == ticket else { return }
                self.metadata = info; self.duration = info.duration
                if let index = self.playlist.firstIndex(where: { $0.id == entry.id }) {
                    self.playlist[index].failure = nil
                    if !info.title.isEmpty { self.playlist[index].title = info.title }
                }
                let item = AVPlayerItem(asset: asset)
                item.allowedAudioSpatializationFormats = self.policy.allowSpatialization ? .monoStereoAndMultichannel : []
                let player = AVPlayer()
                player.audioOutputDeviceUniqueID = device.uid
                player.volume = self.volume
                player.automaticallyWaitsToMinimizeStalling = true
                self.player = player
                self.observe(player, item: item, ticket: ticket, restoredPosition: restoredPosition)
                player.replaceCurrentItem(with: item)
            } catch {
                guard let self, !Task.isCancelled, self.generation == ticket else { return }
                self.errorDetails = String(describing: error as NSError)
                self.fail(error.localizedDescription, ticket: ticket)
            }
        }
    }

    private func observe(_ player: AVPlayer, item: AVPlayerItem, ticket: UInt64, restoredPosition: Double) {
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.generation == ticket, self.player?.currentItem === item else { return }
                switch item.status {
                case .readyToPlay: self.finishPreparing(ticket: ticket, position: restoredPosition)
                case .failed:
                    self.errorDetails = item.error.map { String(describing: $0 as NSError) } ?? ""
                    self.fail(item.error?.localizedDescription ?? "系统无法解码这个文件。", ticket: ticket)
                default: break
                }
            }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak player] _, _ in
            Task { @MainActor in
                guard let self, let player, self.generation == ticket, self.player === player else { return }
                self.isPlaying = player.timeControlStatus == .playing
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                if !self.isSeeking && !self.isLoading && time.seconds.isFinite { self.position = max(0, time.seconds) }
                if self.wantsToPlay && ProcessInfo.processInfo.systemUptime - self.lastSessionSave >= 5 { self.saveSession() }
            }
        }
        notificationObservers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                self.position = self.duration; self.wantsToPlay = false; self.isPlaying = false
                if self.canGoNext { self.next() } else { self.saveSession() }
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let text = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "播放中断。"
            Task { @MainActor in self?.fail(text, ticket: ticket) }
        })
    }

    private func finishPreparing(ticket: UInt64, position: Double) {
        guard generation == ticket, readyGeneration != ticket, let player else { return }
        readyGeneration = ticket
        let actualDuration = player.currentItem?.duration.seconds ?? 0
        if actualDuration.isFinite && actualDuration > 0 { duration = actualDuration }
        let target = min(max(0, position), max(0, duration - 0.01))
        if target > 0 {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
                Task { @MainActor in
                    guard let self, let player, self.generation == ticket, self.player === player else { return }
                    guard finished else { self.fail("切换后无法恢复播放位置。", ticket: ticket); return }
                    self.completeLoad(ticket: ticket)
                }
            }
        } else { completeLoad(ticket: ticket) }
    }
    private func completeLoad(ticket: UInt64) {
        guard generation == ticket, let player else { return }
        timeoutTask?.cancel(); timeoutTask = nil
        isLoading = false
        let time = player.currentTime().seconds
        if time.isFinite { position = time }
        saveSession()
        if wantsToPlay { player.play() }
    }
    private func fail(_ text: String, ticket: UInt64) {
        guard generation == ticket else { return }
        let message: String
        if spatialMode == .off, metadata.audioDescription.hasPrefix("APAC"), errorDetails.contains("1718449215") {
            message = "系统无法在当前输出上以关闭空间化的方式播放此 APAC 文件。请切回“自动”或“强制耳机空间音频”，再继续播放。"
        } else { message = text }
        if let index = currentIndex { playlist[index].failure = message }
        invalidatePlayback()
        wantsToPlay = false; isLoading = false; isSeeking = false; errorMessage = message
        SpatialShimSetConfiguration(0, false)
        saveSession()
    }
    private func invalidatePlayback() {
        generation &+= 1; seekSerial &+= 1
        loadTask?.cancel(); loadTask = nil; timeoutTask?.cancel(); timeoutTask = nil
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemObservation?.invalidate(); itemObservation = nil
        controlObservation?.invalidate(); controlObservation = nil
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
        notificationObservers.removeAll()
        player?.currentItem?.cancelPendingSeeks()
        player?.replaceCurrentItem(with: nil); player = nil; isPlaying = false
    }
    func shutdown() {
        shuttingDown = true
        pause()
        invalidatePlayback(); devices.shutdown(); SpatialShimSetConfiguration(0, false)
    }

    func diagnosticSnapshot() -> [String: Any] {
        let shim = SpatialShimGetStatus()
        return ["file": currentEntry?.url.path ?? "", "playlistCount": playlist.count,
                "position": position, "duration": duration, "ready": isReady, "playing": isPlaying,
                "wantsToPlay": wantsToPlay, "loading": isLoading, "seeking": isSeeking,
                "mode": spatialMode.rawValue, "outputSelection": outputSelection,
                "outputUID": selectedOutput?.uid ?? "", "nativeSpatial": selectedOutput?.hasNativeSpatialAudio ?? false,
                "shimEnabled": shim.enabled != 0, "shimTarget": shim.deviceID,
                "overriddenQueries": shim.overriddenQueries, "queueSpatial": shim.lastSpatialRequest == UInt32.max ? -1 : Int(shim.lastSpatialRequest),
                "queueLayout": String(format: "0x%08x", shim.lastChannelLayout),
                "hasVideo": metadata.hasVideo, "sourceAudio": metadata.audioDescription,
                "error": errorMessage ?? "", "errorDetails": errorDetails]
    }
}
