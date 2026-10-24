import Foundation

struct PlaybackSession: Codable {
    private static let key = "playbackSession"
    var version = 2
    var playlists: [Playlist]
    var browsedPlaylistID: UUID
    var playingPlaylistID: UUID?
    var currentID: UUID?
    var position: Double
    var playbackMode: PlaybackMode

    private struct Legacy: Decodable {
        var version: Int
        var entries: [PlaylistEntry]
        var currentID: UUID?
        var position: Double
    }

    static func load(from defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        var session: Self
        if let value = try? decoder.decode(Self.self, from: data), value.version == 2 {
            session = value
        } else if let old = try? decoder.decode(Legacy.self, from: data), old.version == 1 {
            let list = Playlist(name: "默认列表", entries: old.entries)
            session = Self(playlists: [list], browsedPlaylistID: list.id,
                           playingPlaylistID: list.id, currentID: old.currentID,
                           position: old.position, playbackMode: .sequential)
            if !list.entries.contains(where: { $0.id == session.currentID }) {
                session.currentID = list.entries.first?.id; session.position = 0
            }
        } else { return nil }
        var listIDs = Set<UUID>()
        session.playlists = session.playlists.filter { listIDs.insert($0.id).inserted }
        for index in session.playlists.indices {
            var entryIDs = Set<UUID>()
            // A disconnected disk must not erase its entries.
            session.playlists[index].entries = session.playlists[index].entries.filter {
                $0.url.isFileURL && entryIDs.insert($0.id).inserted
            }
        }
        if session.playlists.isEmpty { session.playlists = [Playlist(name: "默认列表")] }
        if !session.playlists.contains(where: { $0.id == session.browsedPlaylistID }) {
            session.browsedPlaylistID = session.playlists[0].id
        }
        if !session.playlists.contains(where: { list in
            list.id == session.playingPlaylistID && list.entries.contains { $0.id == session.currentID }
        }) {
            session.playingPlaylistID = nil; session.currentID = nil; session.position = 0
        }
        session.position = session.position.isFinite ? max(0, session.position) : 0
        return session
    }

    func save(to defaults: UserDefaults) {
        var session = self
        session.position = position.isFinite ? max(0, position) : 0
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
