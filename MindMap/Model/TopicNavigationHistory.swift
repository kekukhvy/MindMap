import Foundation

/// Back stack of "Go to" topic-link jumps (view state, not saved, not undoable).
/// Following a topic link pushes the topic the jump started from; Back pops
/// to the most recent one that still exists.
struct TopicNavigationHistory: Equatable {
    static let limit = 50

    private(set) var entries: [UUID] = []

    var isEmpty: Bool { entries.isEmpty }

    /// Records `origin` before jumping away from it (consecutive duplicates
    /// collapse; the oldest entries drop beyond `limit`).
    mutating func push(_ origin: UUID) {
        if entries.last == origin { return }
        entries.append(origin)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// Most recent entry for which `exists` is true; it and everything after
    /// it (stale, deleted topics) are removed. Nil if none is left.
    mutating func pop(where exists: (UUID) -> Bool) -> UUID? {
        while let last = entries.popLast() {
            if exists(last) { return last }
        }
        return nil
    }

    /// The entry Back would return to (skipping deleted topics).
    func peek(where exists: (UUID) -> Bool) -> UUID? {
        entries.last(where: exists)
    }

    mutating func removeAll() { entries.removeAll() }
}
