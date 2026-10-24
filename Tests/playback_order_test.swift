import Foundation

@main
struct PlaybackTests {
    static func main() throws {
        let ids = (0..<4).map { _ in UUID() }
        var order = PlaybackOrder(shuffled: { $0 })
        order.reset(ids, current: ids[0])
        assert(!order.canPrevious(ids, current: ids[0], mode: .sequential))
        assert(!order.canNext(ids, current: ids[3], mode: .sequential))
        assert(order.next(ids, current: ids[0], mode: .sequential, automatic: true) == ids[1])
        assert(order.next(ids, current: ids[3], mode: .sequential, automatic: true) == nil)
        for mode in [PlaybackMode.repeatAll, .repeatOne] {
            assert(order.next(ids, current: ids[3], mode: mode, automatic: false) == ids[0])
            assert(order.previous(ids, current: ids[0], mode: mode) == ids[3])
        }
        assert(order.next(ids, current: ids[3], mode: .repeatAll, automatic: true) == ids[0])
        assert(order.next(ids, current: ids[1], mode: .repeatOne, automatic: true) == ids[1])
        for mode in PlaybackMode.allCases {
            order.reset([], current: nil)
            assert(order.next([], current: nil, mode: mode, automatic: true) == nil)
            order.reset([ids[0]], current: ids[0])
            assert(!order.canPrevious([ids[0]], current: ids[0], mode: mode))
            assert(!order.canNext([ids[0]], current: ids[0], mode: mode))
            assert(order.next([ids[0]], current: ids[0], mode: mode, automatic: false) == nil)
            assert(order.next([ids[0]], current: ids[0], mode: mode, automatic: true) == (mode == .sequential ? nil : ids[0]))
        }

        // Alternating orders force a repeated boundary candidate; each complete round must still contain all IDs.
        var shuffleCalls = 0
        order = PlaybackOrder(shuffled: { values in
            shuffleCalls += 1
            return shuffleCalls.isMultiple(of: 2) ? Array(values.reversed()) : values
        })
        order.reset(ids, current: ids[0])
        var current = ids[0]
        var round = [current]
        for index in 1..<80 {
            let next = order.next(ids, current: current, mode: .shuffle, automatic: true)!
            assert(next != current)
            round.append(next); current = next
            if (index + 1).isMultiple(of: ids.count) {
                assert(Set(round) == Set(ids) && round.count == ids.count)
                round.removeAll()
            }
        }

        order = PlaybackOrder(shuffled: { $0 })
        order.reset(ids, current: ids[0])
        assert(order.next(ids, current: ids[0], mode: .shuffle, automatic: false) == ids[1])
        assert(order.next(ids, current: ids[1], mode: .shuffle, automatic: false) == ids[2])
        assert(order.previous(ids, current: ids[2], mode: .shuffle) == ids[1])
        assert(order.previous(ids, current: ids[1], mode: .shuffle) == ids[0])
        assert(!order.canPrevious(ids, current: ids[0], mode: .shuffle))
        assert(order.next(ids, current: ids[0], mode: .shuffle, automatic: false) == ids[1])
        assert(order.next(ids, current: ids[1], mode: .shuffle, automatic: false) == ids[2])
        assert(order.next(ids, current: ids[2], mode: .shuffle, automatic: false) == ids[3])

        // Remove past/future entries and insert a new entry without replaying consumed ones.
        order.reset(ids, current: ids[0])
        _ = order.next(ids, current: ids[0], mode: .shuffle, automatic: false)
        _ = order.next(ids, current: ids[1], mode: .shuffle, automatic: false)
        _ = order.previous(ids, current: ids[2], mode: .shuffle)
        let extra = UUID()
        let changed = [ids[1], ids[3], extra]
        order.synchronize(changed)
        assert(!order.canPrevious(changed, current: ids[1], mode: .shuffle))
        assert(order.next(changed, current: ids[1], mode: .shuffle, automatic: false) == ids[3])
        assert(order.next(changed, current: ids[3], mode: .shuffle, automatic: false) == extra)
        order.reset(changed, current: ids[3])
        assert(!order.canPrevious(changed, current: ids[3], mode: .shuffle))
        assert(order.next(changed, current: ids[3], mode: .shuffle, automatic: false) == ids[1])

        try sessions()
        print("PASS playback boundaries, shuffle rounds/history/edits, and session migration/validation")
    }

    static func sessions() throws {
        let domain = "local.sakuzy.SpatialUnlockPlayer.UnitTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let a = PlaylistEntry(url: URL(fileURLWithPath: "/unavailable/test.wav"))
        let b = PlaylistEntry(url: a.url)
        let legacy: [String: Any] = ["version": 1, "entries": [a, b].map {
            ["id": $0.id.uuidString, "url": $0.url.absoluteString, "title": $0.title]
        }, "currentID": b.id.uuidString, "position": 17.5]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "playbackSession")
        let migrated = PlaybackSession.load(from: defaults)!
        assert(migrated.version == 2 && migrated.playlists.count == 1)
        assert(migrated.playlists[0].name == "默认列表")
        assert(migrated.playlists[0].entries.map(\.id) == [a.id, b.id])
        assert(migrated.currentID == b.id && migrated.position == 17.5 && migrated.playbackMode == .sequential)

        let empty = Playlist(name: "空列表")
        var session = migrated
        session.playlists.append(empty); session.browsedPlaylistID = empty.id; session.playbackMode = .shuffle
        session.save(to: defaults)
        let restored = PlaybackSession.load(from: defaults)!
        assert(restored.playlists == session.playlists && restored.browsedPlaylistID == empty.id)
        assert(restored.playingPlaylistID == migrated.playingPlaylistID && restored.currentID == b.id)
        assert(restored.playbackMode == .shuffle && restored.position == 17.5)

        session.playlists = [empty]; session.browsedPlaylistID = UUID(); session.position = -.infinity
        session.save(to: defaults)
        let sanitized = PlaybackSession.load(from: defaults)!
        assert(sanitized.browsedPlaylistID == empty.id && sanitized.playingPlaylistID == nil)
        assert(sanitized.currentID == nil && sanitized.position == 0)
        assert(sanitized.playlists[0].entries.isEmpty && sanitized.playbackMode == .shuffle)

        session.playlists = []
        session.save(to: defaults)
        assert(PlaybackSession.load(from: defaults)!.playlists.count == 1)
        defaults.set(Data("{invalid".utf8), forKey: "playbackSession")
        assert(PlaybackSession.load(from: defaults) == nil)
    }
}
