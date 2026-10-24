import Foundation

@main struct AdvancedSettingsTests {
    static func main() throws {
        let name = "local.sakuzy.SpatialUnlockPlayer.AdvancedSettingsTests"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        precondition(AdvancedAudioPreferences.load(defaults).isEmpty)
        precondition(AdvancedAudioSettings.defaults.headroomMode == .system)
        precondition(AdvancedAudioSettings.defaults.hrtfMode == .system)
        precondition(AdvancedAudioSettings.defaults.headroomDB == 20)
        precondition(AdvancedAudioSettings.validatedHeadroom(.nan) == nil)
        precondition(AdvancedAudioSettings.validatedHeadroom(.infinity) == nil)
        precondition(AdvancedAudioSettings.validatedHeadroom(-0.1) == nil)
        precondition(AdvancedAudioSettings.validatedHeadroom(20.1) == nil)
        precondition(AdvancedAudioSettings.validatedHeadroom(7.34) == 7.3)
        var gesture = HeadroomEditGesture()
        gesture.begin(uid: "fiio-uid"); precondition(gesture.isEditing)
        precondition(gesture.finish(currentUID: "fiio-uid")); precondition(!gesture.finish(currentUID: "fiio-uid"))
        gesture.begin(uid: "fiio-uid"); gesture.cancel(); precondition(!gesture.finish(currentUID: "fiio-uid"))
        gesture.begin(uid: "fiio-uid"); precondition(!gesture.finish(currentUID: "airpods-uid"))
        gesture.begin(uid: nil); precondition(!gesture.finish(currentUID: nil))
        var a = AdvancedAudioSettings(); a.headroomMode = .custom; a.headroomDB = 0; a.hrtfMode = .generic
        var b = AdvancedAudioSettings(); b.headroomDB = 7.3; b.headroomMode = .custom; b.hrtfMode = .personalized
        AdvancedAudioPreferences.save(["fiio-uid":a,"airpods-uid":b], to:defaults)
        let restored = AdvancedAudioPreferences.load(defaults)
        precondition(restored["fiio-uid"] == a && restored["airpods-uid"] == b)
        precondition(restored["fiio-uid"] != .defaults)
        let malformed = Data(#"{"version":1,"devices":{"fiio-uid":{"headroomMode":"custom","headroomDB":99,"hrtfMode":"personalized"},"airpods-uid":{"headroomMode":"future","headroomDB":7.34,"hrtfMode":"future"}}}"#.utf8)
        defaults.set(malformed, forKey: AdvancedAudioPreferences.key)
        let sanitized = AdvancedAudioPreferences.load(defaults)
        precondition(sanitized["fiio-uid"]?.headroomMode == .system && sanitized["fiio-uid"]?.hrtfMode == .personalized)
        precondition(sanitized["airpods-uid"]?.headroomDB == 7.3 && sanitized["airpods-uid"]?.hrtfMode == .system)
        print("PASS: system defaults, custom zero, continuous precision, per-UID persistence, invalid preference recovery")
    }
}
