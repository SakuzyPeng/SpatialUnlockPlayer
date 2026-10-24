import SwiftUI
import AVKit
import UniformTypeIdentifiers

@MainActor
struct PlayerView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var devices: AudioDeviceCatalog
    @State private var selection: UUID?
    @State private var dropTarget = false
    @State private var draggingPosition = false
    @State private var sliderPosition: Double = 0
    @State private var isFullScreen = false
    @State private var namingPlaylist: PlaylistNameDraft?

    var body: some View {
        VStack(spacing: 0) {
            if isFullScreen && model.metadata.hasVideo {
                playbackArea
            } else {
                toolbar
                Divider()
                HSplitView {
                    sidebar.frame(minWidth: 200, idealWidth: 240, maxWidth: 280)
                    playbackArea.frame(minWidth: 530)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(isFullScreen && model.metadata.hasVideo ? .dark : nil)
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.blue, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(5).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
            model.importDrop(providers); return true
        }
        .onAppear { selection = visibleCurrentID; sliderPosition = model.position }
        .onChange(of: model.currentID) { _, _ in
            if model.browsedPlaylistID == model.playingPlaylistID { selection = model.currentID }
        }
        .onChange(of: model.browsedPlaylistID) { _, _ in selection = visibleCurrentID }
        .onChange(of: model.position) { _, value in if !draggingPosition { sliderPosition = value } }
        .onChange(of: model.playlist) { _, values in
            if let id = selection, !values.contains(where: { $0.id == id }) { selection = visibleCurrentID }
        }
        .sheet(item: $namingPlaylist) { draft in
            PlaylistNameEditor(name: draft.name, isNew: draft.playlistID == nil) { name in
                if let id = draft.playlistID { model.renamePlaylist(id, name: name) }
                else { model.createPlaylist(name: name) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == "main" { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == "main" { isFullScreen = false }
        }
    }

    private var visibleCurrentID: UUID? {
        model.browsedPlaylistID == model.playingPlaylistID ? model.currentID : nil
    }

    private func namePlaylist(_ id: UUID?) {
        namingPlaylist = PlaylistNameDraft(playlistID: id,
            name: id.flatMap { id in model.playlists.first { $0.id == id }?.name } ?? "新建播放列表")
    }

    private var playbackArea: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage { errorBanner(message) }
            mediaSurface.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            transport
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button(action: model.presentOpenPanel) { Label("打开", systemImage: "plus") }
                .help("加入音频或视频文件（⌘O）").accessibilityIdentifier("openFiles")
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Picker("输出设备", selection: Binding(get: { model.outputSelection }, set: model.setOutput)) {
                    Text("系统默认").tag("system")
                    Divider()
                    ForEach(devices.devices) { device in Text(device.name).tag(device.uid) }
                    if model.outputSelection != "system", !devices.devices.contains(where: { $0.uid == model.outputSelection }) {
                        Text("设备已断开").tag(model.outputSelection)
                    }
                }
                .labelsHidden().frame(width: 190).accessibilityIdentifier("outputDevice")
            }
            HStack(spacing: 6) {
                Label("空间音频", systemImage: "headphones").font(.caption).foregroundStyle(.secondary)
                Picker("空间音频", selection: Binding(get: { model.spatialMode }, set: model.setMode)) {
                    ForEach(SpatialMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .labelsHidden().frame(width: 155).accessibilityIdentifier("spatialMode")
            }
            HeadTrackingControl(model: model.headTracking)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var sidebar: some View {
        let listID = model.browsedPlaylistID
        return VStack(spacing: 0) {
            HStack {
                Picker("播放列表", selection: Binding(get: { model.browsedPlaylistID }, set: model.browsePlaylist)) {
                    ForEach(model.playlists) { list in Text(list.name).tag(list.id) }
                }
                .labelsHidden().accessibilityIdentifier("playlistPicker")
                Text("\(model.playlist.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Menu {
                    Button("新建播放列表…") { namePlaylist(nil) }
                    Button("重命名…") { namePlaylist(listID) }
                    Button("删除播放列表", role: .destructive) { model.deletePlaylist(listID) }
                    Divider()
                    Button("移除选中项目") { if let selection { model.remove([selection], from: listID) } }.disabled(selection == nil)
                    Button("清空播放列表", role: .destructive) { model.clear(listID) }.disabled(model.playlist.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("播放列表操作")
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
            if let list = model.playingPlaylist {
                Button { model.browsePlaylist(list.id) } label: {
                    Label("正在播放：\(list.name)", systemImage: "waveform")
                        .font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 10)
                .help("显示正在播放的列表").accessibilityIdentifier("showPlayingPlaylist")
            }
            if model.playlist.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.badge.plus").font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text("拖入文件，或点击“打开”").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(model.playlist) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: rowIcon(entry)).frame(width: 16)
                                .foregroundStyle(entry.id == visibleCurrentID ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title).font(.callout).lineLimit(1)
                                Text(entry.url.lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if entry.failure != nil { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .tag(entry.id)
                        .onTapGesture(count: 2) { model.select(entry.id, in: listID) }
                        .contextMenu {
                            Button("播放") { model.select(entry.id, in: listID) }
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                            Divider()
                            Button("移除") { model.remove([entry.id], from: listID) }
                        }
                        .accessibilityLabel(entry.title)
                        .accessibilityAction(named: "播放") { model.select(entry.id, in: listID) }
                    }
                }
                .listStyle(.sidebar)
                .onKeyPress(.return) { if let selection { model.select(selection, in: listID); return .handled }; return .ignored }
                .onDeleteCommand { if let selection { model.remove([selection], from: listID) } }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func rowIcon(_ entry: PlaylistEntry) -> String {
        if entry.id == visibleCurrentID { return model.wantsToPlay ? "waveform" : "pause.fill" }
        return "play.circle"
    }

    @ViewBuilder private var mediaSurface: some View {
        GeometryReader { geometry in
        let artworkSize = max(56, min(230, min(geometry.size.height - 170, geometry.size.width - 48)))
        ZStack {
            if model.currentEntry == nil {
                VStack(spacing: geometry.size.height < 300 ? 10 : 18) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: geometry.size.height < 300 ? 36 : 52, weight: .light)).foregroundStyle(.blue)
                    VStack(spacing: 8) {
                        Text("SpatialUnlock Player").font(.largeTitle.weight(.semibold))
                        Text("打开音频或视频，开始播放").foregroundStyle(.secondary)
                    }
                    Button("打开文件…", action: model.presentOpenPanel).buttonStyle(.borderedProminent).controlSize(.large)
                    Text("本地播放 · 耳机空间音频").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(geometry.size.height < 300 ? 16 : 30)
            } else if model.metadata.hasVideo {
                Color.black
                VideoSurface(player: model.player)
                    .onTapGesture(count: 2, perform: AppContext.toggleFullScreen)
            } else {
                VStack(spacing: 22) {
                    Group {
                        if let artwork = model.metadata.artwork {
                            Image(nsImage: artwork).resizable().scaledToFit()
                        } else {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(.blue.gradient.opacity(0.13))
                                .overlay { Image(systemName: "waveform").font(.system(size: min(82, artworkSize * 0.4), weight: .light)).foregroundStyle(.blue) }
                        }
                    }
                    .frame(width: artworkSize, height: artworkSize).clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
                    VStack(spacing: 8) {
                        Text(model.displayTitle).font(.title2.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
                        if !model.metadata.artist.isEmpty { Text(model.metadata.artist).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                .padding(24)
            }
            if model.isLoading {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在加载…") }
                    .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transport: some View {
        VStack(spacing: 12) {
            if model.metadata.hasVideo {
                HStack {
                    Text(model.displayTitle).font(.caption.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                }
            }
            HStack(spacing: 10) {
                Text(timeLabel(draggingPosition ? sliderPosition : model.position)).frame(minWidth: 45, alignment: .trailing)
                Slider(value: Binding(get: { sliderPosition }, set: { value in
                    sliderPosition = value
                    if !draggingPosition { model.seek(to: value) }
                }), in: 0...max(model.duration, 1)) { editing in
                    draggingPosition = editing
                    if !editing { model.seek(to: sliderPosition) }
                }
                .disabled(model.duration <= 0 || model.isLoading || model.player == nil)
                .accessibilityLabel("播放进度").accessibilityIdentifier("seekSlider")
                Text(timeLabel(model.duration)).frame(minWidth: 45, alignment: .leading)
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                HStack(spacing: 18) {
                    Button(action: model.previous) { Image(systemName: "backward.end.fill") }.disabled(!model.canGoPrevious).accessibilityLabel("上一项")
                    Button(action: model.togglePlayback) {
                        Image(systemName: model.wantsToPlay ? "pause.fill" : "play.fill").font(.system(size: 25)).frame(width: 38, height: 32)
                    }.disabled(!model.canPlay).accessibilityLabel(model.wantsToPlay ? "暂停" : "播放").accessibilityIdentifier("playPause")
                    Button(action: model.next) { Image(systemName: "forward.end.fill") }.disabled(!model.canGoNext).accessibilityLabel("下一项")
                }
                .buttonStyle(.plain).font(.system(size: 17))
                Menu {
                    Picker("播放模式", selection: Binding(get: { model.playbackMode }, set: model.setPlaybackMode)) {
                        ForEach(PlaybackMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                    }.pickerStyle(.inline)
                } label: {
                    Label(model.playbackMode.title, systemImage: model.playbackMode.symbol).font(.caption)
                }
                .fixedSize().menuStyle(.borderlessButton).accessibilityIdentifier("playbackMode")
                .help("播放模式：\(model.playbackMode.title)")
                Spacer(minLength: 10)
                EqualizerControl(model: model.equalizer)
                HStack(spacing: 7) {
                    Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2").foregroundStyle(.secondary)
                    Slider(value: $model.volume, in: 0...1).frame(width: 105).accessibilityLabel("音量")
                }
                if model.metadata.hasVideo {
                    Button(action: AppContext.toggleFullScreen) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.plain).accessibilityLabel(isFullScreen ? "退出全屏" : "全屏")
                }
            }
            HStack(spacing: 6) {
                Image(systemName: model.policy.useShim ? "headphones" : "speaker.wave.2")
                Text(model.policy.description)
                Spacer()
                Text(model.selectedOutput?.name ?? "输出不可用").lineLimit(1)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer(minLength: 6)
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示")
        }
        .padding(12).background(Color.orange.opacity(0.09))
    }
}

private struct PlaylistNameDraft: Identifiable {
    let id = UUID()
    let playlistID: UUID?
    let name: String
}

private struct PlaylistNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State var name: String
    let isNew: Bool
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "新建播放列表" : "重命名播放列表").font(.headline)
            TextField("列表名称", text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityIdentifier("playlistName")
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { onSave(name); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 360)
        .onAppear { focused = true }
    }
}

@MainActor
private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
