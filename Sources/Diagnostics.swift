#if SPATIAL_DIAGNOSTICS
import Foundation
import AppKit

@MainActor
enum DiagnosticRunner {
    static func startIfRequested(model: PlayerModel) {
        guard let script = ProcessInfo.processInfo.environment["SPATIALUNLOCKPLAYER_TEST_SCRIPT"] else { return }
        Task { await run(script: URL(fileURLWithPath: script), model: model) }
    }

    private static func run(script: URL, model: PlayerModel) async {
        var records: [[String: Any]] = []
        var failure: String?
        do {
            let data = try Data(contentsOf: script)
            guard let steps = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw error("Invalid test script") }
            try await Task.sleep(for: .milliseconds(300))
            for (index, step) in steps.enumerated() {
                let action = step["action"] as? String ?? ""
                switch action {
                case "add":
                    let paths = step["paths"] as? [String] ?? []
                    model.addFiles(paths.map { URL(fileURLWithPath: $0) })
                case "select":
                    let index = step["index"] as? Int ?? -1
                    guard model.playlist.indices.contains(index) else { throw error("Invalid playlist index \(index)") }
                    model.select(model.playlist[index].id, autoplay: step["autoplay"] as? Bool ?? true)
                case "remove":
                    let indices = step["indices"] as? [Int] ?? []
                    model.remove(Set(indices.compactMap { model.playlist.indices.contains($0) ? model.playlist[$0].id : nil }))
                case "clear": model.clear()
                case "play": model.play()
                case "pause": model.pause()
                case "next": model.next()
                case "previous": model.previous()
                case "mode":
                    guard let raw = step["value"] as? String, let mode = SpatialMode(rawValue: raw) else { throw error("Invalid mode") }
                    model.setMode(mode)
                case "output": model.setOutput(step["value"] as? String ?? "system")
                case "deviceMissing": model.devices.diagnosticRemoveDevice(uid: step["value"] as? String ?? "")
                case "refreshDevices": model.devices.refresh()
                case "drop":
                    let urls = (step["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
                    model.importDrop(urls.map { NSItemProvider(object: $0 as NSURL) })
                case "awaitCount":
                    let count = step["value"] as? Int ?? 0
                    try await until(timeout: 10) { model.playlist.count == count }
                case "seek": model.seek(to: step["value"] as? Double ?? 0)
                case "volume": model.volume = Float(step["value"] as? Double ?? 0.1)
                case "poseStart":
                    model.headTracking.portText = String(step["port"] as? Int ?? 9000)
                    model.headTracking.sourceFilter = step["source"] as? String ?? ""
                    model.headTracking.setEnabled(true)
                case "poseStop": model.headTracking.setEnabled(false)
                case "poseRecenter": model.headTracking.recenter()
                case "awaitPose":
                    try await until(timeout: step["timeout"] as? Double ?? 10) {
                        if let error = model.headTracking.snapshot.error { throw Self.error(error) }
                        return model.headTracking.snapshot.fresh
                    }
                case "awaitPoseApplied":
                    try await until(timeout: step["timeout"] as? Double ?? 10) {
                        SpatialHeadPoseGetStatus().applied >= UInt64(step["minimum"] as? Int ?? 5)
                    }
                case "awaitPoseStale":
                    try await until(timeout: step["timeout"] as? Double ?? 10) {
                        model.headTracking.snapshot.accepted > 0 && !model.headTracking.snapshot.fresh
                    }
                case "awaitReady":
                    try await until(timeout: step["timeout"] as? Double ?? 15) {
                        if let error = model.errorMessage { throw Self.error(error) }
                        return model.isReady
                    }
                case "awaitError": try await until(timeout: 10) { model.errorMessage != nil }
                case "awaitStopped": try await until(timeout: 15) { !model.wantsToPlay && !model.isLoading }
                case "wait": try await Task.sleep(for: .seconds(step["seconds"] as? Double ?? 0.6))
                case "assert": try verify(step["expect"] as? [String: Any] ?? [:], snapshot: model.diagnosticSnapshot())
                default: throw error("Unknown action \(action)")
                }
                let record: [String: Any] = ["step": index, "action": action, "state": model.diagnosticSnapshot()]
                records.append(record); emit(record)
            }
        } catch {
            failure = error.localizedDescription
            emit(["failure": failure!, "state": model.diagnosticSnapshot()])
        }
        let result: [String: Any] = ["passed": failure == nil, "failure": failure ?? "", "steps": records,
                                     "injectedLibraries": ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] ?? "",
                                     "finalState": model.diagnosticSnapshot()]
        let destination = ProcessInfo.processInfo.environment["SPATIALUNLOCKPLAYER_TEST_RESULT"].map { URL(fileURLWithPath: $0) } ?? script.appendingPathExtension("results.json")
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: destination) }
        catch { emit(["reportError": error.localizedDescription]) }
        model.pause()
        if ProcessInfo.processInfo.environment["SPATIALUNLOCKPLAYER_TEST_KEEP_OPEN"] != "1" { NSApp.terminate(nil) }
    }

    private static func until(timeout: Double, condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw error("Timed out after \(timeout) seconds")
    }
    private static func verify(_ expected: [String: Any], snapshot: [String: Any]) throws {
        for (key, value) in expected {
            let counters = ["minPoseAccepted": "poseAccepted", "minPoseApplied": "poseApplied",
                            "minPosePublished": "posePublished", "minPoseRestored": "poseRestored",
                            "minPoseReferences": "poseReferences", "minPoseRecenters": "poseRecenters",
                            "minPoseRenderCallbacks": "poseRenderCallbacks"]
            if let field = counters[key], let minimum = value as? NSNumber {
                guard let actual = snapshot[field] as? NSNumber, actual.uint64Value >= minimum.uint64Value else {
                    throw error("\(field) below \(minimum)")
                }
                continue
            }
            if key == "minPosition", let limit = value as? Double {
                guard (snapshot["position"] as? Double ?? -1) >= limit else { throw error("Position below \(limit)") }; continue
            }
            if key == "maxPosition", let limit = value as? Double {
                guard (snapshot["position"] as? Double ?? .infinity) <= limit else { throw error("Position above \(limit)") }; continue
            }
            if key == "fileContains", let fragment = value as? String {
                guard (snapshot["file"] as? String ?? "").contains(fragment) else { throw error("Wrong active file: \(snapshot["file"] ?? "")") }; continue
            }
            if key == "hasError", let wanted = value as? Bool {
                guard (!(snapshot["error"] as? String ?? "").isEmpty) == wanted else { throw error("Unexpected error state") }; continue
            }
            if let number = value as? NSNumber, let actual = snapshot[key] as? NSNumber, number == actual { continue }
            if let text = value as? String, let actual = snapshot[key] as? String, text == actual { continue }
            throw error("Assertion \(key): expected \(value), got \(snapshot[key] ?? "missing")")
        }
    }
    private static func error(_ text: String) -> NSError { NSError(domain: "SpatialUnlockPlayer.Regression", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private static func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}
#endif
