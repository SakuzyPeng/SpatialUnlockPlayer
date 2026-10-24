import SwiftUI
import AppKit

@MainActor
enum AppContext {
    static var model: PlayerModel?
    static var pendingURLs: [URL] = []
    static func toggleFullScreen() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model = AppContext.model { model.addFiles(urls) }
        else { AppContext.pendingURLs.append(contentsOf: urls) }
        application.activate(ignoringOtherApps: true)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AppContext.pendingURLs.isEmpty {
            AppContext.model?.addFiles(AppContext.pendingURLs); AppContext.pendingURLs.removeAll()
        }
        #if SPATIAL_DIAGNOSTICS
        if let model = AppContext.model { DiagnosticRunner.startIfRequested(model: model) }
        #endif
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { AppContext.model?.shutdown() }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

@main
@MainActor
struct SpatialUnlockPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: PlayerModel

    init() {
        #if SPATIAL_DIAGNOSTICS
        let testing = ProcessInfo.processInfo.environment["SPATIALUNLOCKPLAYER_TEST_SCRIPT"] != nil
        let preferences = testing ? UserDefaults(suiteName: "local.sakuzy.SpatialUnlockPlayer.Regression")! : .standard
        if testing && ProcessInfo.processInfo.environment["SPATIALUNLOCKPLAYER_TEST_RESTORE_SESSION"] != "1" {
            preferences.removePersistentDomain(forName: "local.sakuzy.SpatialUnlockPlayer.Regression")
        }
        #else
        let preferences = UserDefaults.standard
        #endif
        let model = PlayerModel(defaults: preferences)
        _model = StateObject(wrappedValue: model)
        AppContext.model = model
    }

    var body: some Scene {
        Window("SpatialUnlock Player", id: "main") {
            PlayerView(model: model, devices: model.devices)
        }
        .defaultSize(width: 1000, height: 650)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件…", action: model.presentOpenPanel).keyboardShortcut("o")
            }
            CommandMenu("播放") {
                Button(model.wantsToPlay ? "暂停" : "播放", action: model.togglePlayback).keyboardShortcut(.space, modifiers: [])
                    .disabled(model.currentEntry == nil)
                Button("上一项", action: model.previous).keyboardShortcut(.leftArrow, modifiers: .command).disabled(!model.canGoPrevious)
                Button("下一项", action: model.next).keyboardShortcut(.rightArrow, modifiers: .command).disabled(!model.canGoNext)
                Divider()
                Button("后退 10 秒") { model.seek(to: model.position - 10) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("前进 10 秒") { model.seek(to: model.position + 10) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Divider()
                Button("头部追踪回正", action: model.headTracking.recenter).keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("切换全屏", action: AppContext.toggleFullScreen).keyboardShortcut("f", modifiers: [.command, .control])
            }
        }
    }
}
