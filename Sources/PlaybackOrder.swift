import Foundation

/// Playback decisions are independent of AVPlayer and the list currently being browsed.
struct PlaybackOrder {
    private var pending: [UUID] = []
    private var history: [UUID] = []
    private var cursor = -1
    private var known: Set<UUID> = []
    private let shuffled: ([UUID]) -> [UUID]

    init(shuffled: @escaping ([UUID]) -> [UUID] = { $0.shuffled() }) {
        self.shuffled = shuffled
    }

    mutating func reset(_ ids: [UUID], current: UUID?) {
        known = Set(ids)
        history = current.map { known.contains($0) ? [$0] : [] } ?? []
        cursor = history.count - 1
        pending = shuffled(ids.filter { $0 != current })
    }

    mutating func synchronize(_ ids: [UUID]) {
        let valid = Set(ids)
        let additions = ids.filter { !known.contains($0) }
        pending.removeAll { !valid.contains($0) }
        if !additions.isEmpty { pending = shuffled(pending + additions) }
        let past = history.prefix(cursor + 1).filter { valid.contains($0) }
        let future = history.dropFirst(cursor + 1).filter { valid.contains($0) }
        history = past + future
        cursor = past.count - 1
        known = valid
    }

    func canPrevious(_ ids: [UUID], current: UUID?, mode: PlaybackMode) -> Bool {
        guard ids.count > 1, let current, let index = ids.firstIndex(of: current) else { return false }
        if mode == .shuffle { return cursor > 0 }
        return mode != .sequential || index > 0
    }

    func canNext(_ ids: [UUID], current: UUID?, mode: PlaybackMode) -> Bool {
        guard ids.count > 1, let current, let index = ids.firstIndex(of: current) else { return false }
        return mode != .sequential || index + 1 < ids.count
    }

    mutating func previous(_ ids: [UUID], current: UUID?, mode: PlaybackMode) -> UUID? {
        guard canPrevious(ids, current: current, mode: mode), let current,
              let index = ids.firstIndex(of: current) else { return nil }
        if mode == .shuffle {
            cursor -= 1
            return history[cursor]
        }
        return ids[(index + ids.count - 1) % ids.count]
    }

    mutating func next(_ ids: [UUID], current: UUID?, mode: PlaybackMode, automatic: Bool) -> UUID? {
        guard let current, let index = ids.firstIndex(of: current) else { return nil }
        if !automatic && !canNext(ids, current: current, mode: mode) { return nil }
        if automatic && mode == .repeatOne { return current }
        if mode == .shuffle {
            if cursor + 1 < history.count {
                cursor += 1
                return history[cursor]
            }
            if pending.isEmpty {
                pending = shuffled(ids)
                // Keep every entry in the new round, but avoid repeating at its boundary.
                if pending.count > 1, pending.first == current { pending.swapAt(0, 1) }
            }
            guard !pending.isEmpty else { return nil }
            let next = pending.removeFirst()
            history.append(next); cursor = history.count - 1
            return next
        }
        if index + 1 < ids.count { return ids[index + 1] }
        return mode == .sequential ? nil : ids.first
    }
}
