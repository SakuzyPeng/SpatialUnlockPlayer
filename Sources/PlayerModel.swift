import AppKit
import Combine
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class PlayerModel: ObservableObject {
    let devices = AudioDeviceCatalog()
    let headTracking: HeadTrackingModel
    let equalizer: EqualizerModel
    let advancedAudio: AdvancedAudioModel
    @Published private(set) var playlists: [Playlist]
    @Published private(set) var browsedPlaylistID: UUID
    @Published private(set) var playingPlaylistID: UUID?
    @Published private(set) var playbackMode: PlaybackMode = .sequential
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
    private var order = PlaybackOrder()
    #if SPATIAL_DIAGNOSTICS
    private(set) var completedItemCount = 0
    #endif

    var browsedPlaylist: Playlist? { playlists.first { $0.id == browsedPlaylistID } }
    var playingPlaylist: Playlist? { playlists.first { $0.id == playingPlaylistID } }
    var playlist: [PlaylistEntry] { browsedPlaylist?.entries ?? [] }
    private var playingEntries: [PlaylistEntry] { playingPlaylist?.entries ?? [] }
    private var playingIDs: [UUID] { playingEntries.map(\.id) }
    var currentEntry: PlaylistEntry? { playingEntries.first { $0.id == currentID } }
    var currentIndex: Int? { playingEntries.firstIndex { $0.id == currentID } }
    var canGoPrevious: Bool { order.canPrevious(playingIDs, current: currentID, mode: playbackMode) }
    var canGoNext: Bool { order.canNext(playingIDs, current: currentID, mode: playbackMode) }
    var canPlay: Bool { currentEntry != nil || !playlist.isEmpty }
    var isReady: Bool { player?.currentItem?.status == .readyToPlay && !isLoading && !isSeeking }
    var selectedOutput: AudioOutputDevice? { devices.resolve(outputSelection) }
    var displayTitle: String { metadata.title.isEmpty ? currentEntry?.title ?? "SpatialUnlock Player" : metadata.title }

    init(defaults: UserDefaults = .standard) {
        let initial = Playlist(name: "默认列表")
        self.playlists = [initial]
        self.browsedPlaylistID = initial.id
        self.defaults = defaults
        self.headTracking = HeadTrackingModel(defaults: defaults)
        self.equalizer = EqualizerModel(defaults: defaults)
        self.advancedAudio = AdvancedAudioModel(defaults: defaults)
        self.volume = defaults.object(forKey: "volume") == nil ? 0.1 : min(1, max(0, defaults.float(forKey: "volume")))
        self.spatialMode = SpatialMode(rawValue: defaults.string(forKey: "spatialMode") ?? "") ?? .automatic
        let saved = defaults.string(forKey: "outputUID") ?? "system"
        self.outputSelection = saved == "system" || devices.devices.contains(where: { $0.uid == saved }) ? saved : "system"
        activeDevice = selectedOutput
        policy = SpatialPolicy.resolve(mode: spatialMode, device: activeDevice)
        equalizer.playbackContext = { [weak self] in
            guard let self else { return .init() }
            return .init(hasItem: self.player?.currentItem != nil, playing: self.isPlaying, loading: self.isLoading)
        }
        advancedAudio.playbackContext = { [weak self] in
            guard let self else { return .init() }
            return .init(hasItem: self.player?.currentItem != nil, playing: self.isPlaying, loading: self.isLoading)
        }
        advancedAudio.onChange = { [weak self] in self?.updateRoute(rebuildCurrent: true) }
        advancedAudio.onRecovery = { [weak self] in self?.updateRoute(rebuildCurrent: true) }
        updateRenderingPolicy()
        devices.onChange = { [weak self] in self?.devicesChanged() }
        if let session = PlaybackSession.load(from: defaults) {
            playlists = session.playlists
            browsedPlaylistID = session.browsedPlaylistID
            playingPlaylistID = session.playingPlaylistID
            playbackMode = session.playbackMode
            currentID = session.currentID
            position = session.position
            order.reset(playingIDs, current: currentID)
            saveSession()
            if currentEntry != nil { rebuild(at: position, autoplay: false) }
        }
    }

    private func saveSession() {
        PlaybackSession(playlists: playlists, browsedPlaylistID: browsedPlaylistID,
                        playingPlaylistID: playingPlaylistID, currentID: currentID,
                        position: position, playbackMode: playbackMode).save(to: defaults)
        lastSessionSave = ProcessInfo.processInfo.systemUptime
    }

    func browsePlaylist(_ id: UUID) {
        guard playlists.contains(where: { $0.id == id }) else { return }
        browsedPlaylistID = id
        saveSession()
    }

    @discardableResult func createPlaylist(name: String = "新建播放列表") -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = Playlist(name: name.isEmpty ? "新建播放列表" : name)
        playlists.append(list)
        browsePlaylist(list.id)
        return list.id
    }

    func renamePlaylist(_ id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name
        saveSession()
    }

    func deletePlaylist(_ id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        if playingPlaylistID == id { stopPlayback() }
        playlists.remove(at: index)
        if playlists.isEmpty { playlists = [Playlist(name: "默认列表")] }
        if browsedPlaylistID == id { browsedPlaylistID = playlists[min(index, playlists.count - 1)].id }
        saveSession()
    }

    func setPlaybackMode(_ mode: PlaybackMode) {
        guard mode != playbackMode else { return }
        playbackMode = mode
        order.reset(playingIDs, current: currentID)
        saveSession()
    }

    func presentOpenPanel() {
        let targetID = browsedPlaylistID
        let panel = NSOpenPanel()
        panel.title = "加入播放列表"
        panel.prompt = "打开"
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addFiles(panel.urls, to: targetID)
        }
    }

    func addFiles(_ urls: [URL], to playlistID: UUID? = nil) {
        let targetID = playlistID ?? browsedPlaylistID
        guard let index = playlists.firstIndex(where: { $0.id == targetID }) else { return }
        let localFiles = urls.filter { url in
            guard url.isFileURL else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard !localFiles.isEmpty else { errorMessage = "请选择本地音频或视频文件。"; return }
        defer { saveSession() }
        let wasEmpty = playlists[index].entries.isEmpty
        let entries = localFiles.map { PlaylistEntry(url: $0.standardizedFileURL) }
        playlists[index].entries.append(contentsOf: entries)
        if playingPlaylistID == targetID { order.synchronize(playingIDs) }
        if currentEntry == nil, wasEmpty, let first = entries.first { select(first.id, in: targetID) }
    }

    func importDrop(_ providers: [NSItemProvider]) {
        let targetID = browsedPlaylistID
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
            addFiles(urls, to: targetID)
        }
    }

    func select(_ id: UUID, in playlistID: UUID, autoplay: Bool = true) {
        startEntry(id, in: playlistID, autoplay: autoplay, resetOrder: true)
    }

    private func startEntry(_ id: UUID, in playlistID: UUID, autoplay: Bool, resetOrder: Bool) {
        guard playlists.contains(where: { $0.id == playlistID && $0.entries.contains { $0.id == id } }) else { return }
        defer { saveSession() }
        playingPlaylistID = playlistID
        currentID = id
        if resetOrder { order.reset(playingIDs, current: id) }
        metadata = MediaMetadata(); position = 0; duration = 0
        rebuild(at: 0, autoplay: autoplay)
    }

    func remove(_ ids: Set<UUID>, from playlistID: UUID) {
        guard let listIndex = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        defer { saveSession() }
        let oldIndex = currentIndex ?? 0
        let removingCurrent = playingPlaylistID == playlistID && (currentID.map { ids.contains($0) } ?? false)
        let replacement = removingCurrent ? (
            playingEntries.dropFirst(oldIndex + 1).first { !ids.contains($0.id) }
                ?? playingEntries.prefix(oldIndex).last { !ids.contains($0.id) }
        ) : nil
        let resume = wantsToPlay
        playlists[listIndex].entries.removeAll { ids.contains($0.id) }
        if playingPlaylistID == playlistID {
            order.synchronize(playingIDs)
            if playingEntries.isEmpty { stopPlayback() }
            else if let replacement {
                select(replacement.id, in: playlistID, autoplay: resume)
            }
        }
    }

    func clear(_ playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if playingPlaylistID == playlistID { stopPlayback() }
        playlists[index].entries.removeAll()
        saveSession()
    }

    private func stopPlayback() {
        invalidatePlayback()
        playingPlaylistID = nil; currentID = nil; metadata = MediaMetadata()
        order.reset([], current: nil)
        position = 0; duration = 0; wantsToPlay = false; isLoading = false; isSeeking = false; errorMessage = nil
        SpatialShimSetConfiguration(0, false)
    }

    func togglePlayback() {
        if wantsToPlay { pause() } else { play() }
    }
    func play() {
        guard currentEntry != nil else {
            if let first = playlist.first { select(first.id, in: browsedPlaylistID) }
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
        guard let listID = playingPlaylistID,
              let id = order.previous(playingIDs, current: currentID, mode: playbackMode) else { return }
        startEntry(id, in: listID, autoplay: true, resetOrder: false)
    }
    func next() {
        guard let listID = playingPlaylistID,
              let id = order.next(playingIDs, current: currentID, mode: playbackMode, automatic: false) else { return }
        startEntry(id, in: listID, autoplay: true, resetOrder: false)
    }

    private func playbackEnded() {
        #if SPATIAL_DIAGNOSTICS
        completedItemCount += 1
        #endif
        position = duration; isPlaying = false
        guard wantsToPlay, let listID = playingPlaylistID else { saveSession(); return }
        guard let id = order.next(playingIDs, current: currentID, mode: playbackMode, automatic: true) else {
            wantsToPlay = false; saveSession(); return
        }
        if id == currentID { seek(to: 0) }
        else { startEntry(id, in: listID, autoplay: true, resetOrder: false) }
    }

    func seek(to requested: Double) {
        guard requested.isFinite, duration > 0, let player, player.currentItem?.status == .readyToPlay, !isLoading else { return }
        let target = min(max(0, requested), duration)
        seekSerial &+= 1
        let serial = seekSerial, ticket = generation
        isSeeking = true; position = target
        SpatialEQReset()
        saveSession()
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            Task { @MainActor in
                guard let self, let player, self.generation == ticket, self.seekSerial == serial, self.player === player else { return }
                self.isSeeking = false
                if finished {
                    SpatialEQReset()
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
        updateRenderingPolicy()
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
        updateRenderingPolicy()
        if removed, currentEntry != nil {
            invalidatePlayback()
            activeDevice = nextDevice; wantsToPlay = false; isLoading = false; isSeeking = false
            SpatialShimSetConfiguration(0, false)
            headTracking.setRenderingAllowed(false)
            equalizer.setRenderingAllowed(false)
            errorMessage = "输出设备已断开，播放已暂停。"
        } else { updateRoute(rebuildCurrent: true) }
    }

    private func rebuild(at restoredPosition: Double, autoplay: Bool) {
        guard let entry = currentEntry, let listID = playingPlaylistID else { return }
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
        updateRenderingPolicy()
        SpatialShimSetConfiguration(device.id, policy.useShim)
        advancedAudio.configure(generation: ticket, deviceID: device.id,
            allowed: policy.allowSpatialization && device.channels == 2)
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
                if let listIndex = self.playlists.firstIndex(where: { $0.id == listID }),
                   let index = self.playlists[listIndex].entries.firstIndex(where: { $0.id == entry.id }) {
                    self.playlists[listIndex].entries[index].failure = nil
                    if !info.title.isEmpty { self.playlists[listIndex].entries[index].title = info.title }
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
                self.playbackEnded()
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
        advancedAudio.refresh()
        guard generation == ticket else { return }
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
        if let listIndex = playlists.firstIndex(where: { $0.id == playingPlaylistID }), let index = currentIndex {
            playlists[listIndex].entries[index].failure = message
        }
        invalidatePlayback()
        wantsToPlay = false; isLoading = false; isSeeking = false; errorMessage = message
        SpatialShimSetConfiguration(0, false)
        saveSession()
    }
    private func invalidatePlayback() {
        SpatialEQReset()
        generation &+= 1; seekSerial &+= 1
        advancedAudio.invalidate(generation: generation)
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
        headTracking.shutdown()
        equalizer.shutdown()
        advancedAudio.shutdown()
        pause()
        invalidatePlayback(); devices.shutdown(); SpatialShimSetConfiguration(0, false)
    }

    func diagnosticSnapshot() -> [String: Any] {
        let shim = SpatialShimGetStatus()
        var result: [String: Any] = ["file": currentEntry?.url.path ?? "", "playlistCount": playlist.count,
                "listCount": playlists.count, "browsedPlaylistID": browsedPlaylistID.uuidString,
                "playingPlaylistID": playingPlaylistID?.uuidString ?? "",
                "browsedPlaylistName": browsedPlaylist?.name ?? "", "playingPlaylistName": playingPlaylist?.name ?? "",
                "playingPlaylistCount": playingEntries.count, "currentID": currentID?.uuidString ?? "",
                "currentIndex": currentIndex ?? -1, "playbackMode": playbackMode.rawValue,
                "canGoPrevious": canGoPrevious, "canGoNext": canGoNext,
                "position": position, "duration": duration, "ready": isReady, "playing": isPlaying,
                "wantsToPlay": wantsToPlay, "loading": isLoading, "seeking": isSeeking,
                "mode": spatialMode.rawValue, "outputSelection": outputSelection,
                "outputUID": selectedOutput?.uid ?? "", "nativeSpatial": selectedOutput?.hasNativeSpatialAudio ?? false,
                "shimEnabled": shim.enabled != 0, "shimTarget": shim.deviceID,
                "overriddenQueries": shim.overriddenQueries, "queueSpatial": shim.lastSpatialRequest == UInt32.max ? -1 : Int(shim.lastSpatialRequest),
                "queueLayout": String(format: "0x%08x", shim.lastChannelLayout),
                "hasVideo": metadata.hasVideo, "sourceAudio": metadata.audioDescription,
                "error": errorMessage ?? "", "errorDetails": errorDetails]
        result.merge(headTracking.diagnosticSnapshot()) { _, new in new }
        result.merge(equalizer.diagnosticSnapshot()) { _, new in new }
        result.merge(advancedAudio.diagnosticSnapshot()) { _, new in new }
        #if SPATIAL_DIAGNOSTICS
        result["completedItemCount"] = completedItemCount
        #endif
        return result
    }
    private func updateRenderingPolicy() {
        headTracking.setRenderingAllowed(policy.allowSpatialization && selectedOutput?.channels == 2)
        equalizer.setRenderingAllowed(policy.allowSpatialization && selectedOutput?.channels == 2)
        advancedAudio.setDevice(selectedOutput, allowed: policy.allowSpatialization && selectedOutput?.channels == 2)
    }
}
