import Foundation

enum AudioHeadroomMode: String, Codable, CaseIterable {
    case system, custom
    var title: String { self == .system ? "系统决定" : "自定义" }
}

enum AudioHRTFMode: String, Codable, CaseIterable {
    case system, generic, personalized
    var title: String {
        switch self { case .system: "系统决定"; case .generic: "通用"; case .personalized: "个性化" }
    }
    var nativeValue: Int32 {
        switch self { case .system: -1; case .generic: 0; case .personalized: 1 }
    }
}

struct AdvancedAudioSettings: Codable, Equatable {
    var headroomMode: AudioHeadroomMode = .system
    var headroomDB: Double = 20
    var hrtfMode: AudioHRTFMode = .system
    static let defaults = Self()

    static func validatedHeadroom(_ value: Double) -> Double? {
        guard value.isFinite, (0...20).contains(value) else { return nil }
        return (value * 10).rounded() / 10
    }
    private enum CodingKeys: String, CodingKey { case headroomMode, headroomDB, hrtfMode }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headroomMode = (try? c.decode(AudioHeadroomMode.self, forKey: .headroomMode)) ?? .system
        hrtfMode = (try? c.decode(AudioHRTFMode.self, forKey: .hrtfMode)) ?? .system
        if let value = try? c.decode(Double.self, forKey: .headroomDB), let valid = Self.validatedHeadroom(value) {
            headroomDB = valid
        } else { headroomMode = .system; headroomDB = 20 }
    }
}

// A drag belongs to the device selected when the pointer went down. Its draft
// is committed only after a matching release; changing output cancels the edit.
struct HeadroomEditGesture {
    private(set) var isEditing = false
    private(set) var isCancelled = false
    private var sourceUID: String?
    mutating func begin(uid: String?) { sourceUID = uid; isEditing = true; isCancelled = false }
    mutating func cancel() { if isEditing { isCancelled = true } }
    mutating func finish(currentUID: String?) -> Bool {
        let commit = isEditing && !isCancelled && sourceUID != nil && sourceUID == currentUID
        self = .init(); return commit
    }
}

enum AdvancedAudioPreferences {
    static let key = "advancedAudioSettingsV1"
    private struct Saved: Codable { var version = 1; var devices: [String: AdvancedAudioSettings] }
    static func load(_ defaults: UserDefaults) -> [String: AdvancedAudioSettings] {
        guard let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == 1 else { return [:] }
        return saved.devices.filter { !$0.key.isEmpty }
    }
    static func save(_ devices: [String: AdvancedAudioSettings], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(Saved(devices: devices)) else { return }
        defaults.set(data, forKey: key)
    }
}
