import Foundation

struct PlaybackSession: Codable {
    private static let key = "playbackSession"
    var version = 1
    var entries: [PlaylistEntry]
    var currentID: UUID?
    var position: Double

    static func load(from defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey: key),
              var session = try? JSONDecoder().decode(Self.self, from: data),
              session.version == 1 else { return nil }
        var seen = Set<UUID>()
        // Keep unavailable local files: a disconnected disk must not erase the list.
        session.entries = session.entries.filter { $0.url.isFileURL && seen.insert($0.id).inserted }
        if !session.entries.contains(where: { $0.id == session.currentID }) {
            session.currentID = session.entries.first?.id
            session.position = 0
        }
        session.position = session.position.isFinite ? max(0, session.position) : 0
        return session
    }

    func save(to defaults: UserDefaults) {
        if entries.isEmpty { defaults.removeObject(forKey: Self.key); return }
        var session = self
        session.position = position.isFinite ? max(0, position) : 0
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
