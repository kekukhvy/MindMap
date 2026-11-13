import CoreGraphics
import Foundation

/// Three-way merge of two edited versions of a map against their common
/// base (WP14 library sync conflicts). Pure; works topic by topic (by id):
///
/// - Topic fields (text, colour, task, link, …) merge key by key: a key
///   changed on one side only takes that side's value; changed on both
///   sides to different values → the NEWER side wins (map modification
///   date), except:
///   - `text` changed on both sides: the newer text stays in the topic and
///     the other text is kept as a new sibling topic "<text> (conflicting
///     edit)" right after it (child of a central / floating topic). Decision:
///     a visible sibling is noticed and is one Delete away; a note would hide
///     the lost text behind an icon and change attachments.
///   - `attachments` merge per attachment id (added on either side kept,
///     removed on one side and unchanged on the other removed, both changed
///     → newer).
/// - Structure: parent / floating slot three-way like a field; sibling order
///   from the side that changed it (newer if both); moves that would form a
///   cycle fall back to the local parent.
/// - Delete vs edit: a topic deleted on one side but edited (fields
///   changed) on the other is KEPT, with the ancestors it needs.
/// - Relationships and boundaries merge per item id; items whose topics are
///   gone are dropped. Theme / tasks panel: three-way, newer on conflict.
enum MapMerge {
    struct Side {
        var map: MindMap
        var modified: Date
    }

    struct Conflict: Equatable {
        enum Kind: Equatable {
            /// Both sides changed the text; `copyID` = the "conflicting
            /// edit" topic holding the older text.
            case text(copyID: UUID)
            /// Both sides changed another field (newer value kept).
            case field(String)
            /// Deleted on one side, edited on the other: kept.
            case deleteVsEdit
        }

        var nodeID: UUID
        var kind: Kind
    }

    struct Result {
        var map: MindMap
        var conflicts: [Conflict]
    }

    static let conflictSuffix = " (conflicting edit)"
    private static let positionKey = "__position"

    static func merge(base: MindMap, local: Side, remote: Side) -> Result {
        var merger = Merger(base: base, local: local, remote: remote)
        return merger.run()
    }

    // MARK: - Flattened map

    enum Slot: Hashable {
        case root
        case floating
        case child(of: UUID)
    }

    struct Entry: Equatable {
        var slot: Slot
        var fields: [String: JSONValue]
    }

    struct Flat {
        var entries: [UUID: Entry] = [:]
        var order: [Slot: [UUID]] = [:]
        var rootID: UUID?

        init(_ map: MindMap) {
            rootID = map.root.id
            add(map.root, slot: .root, position: nil)
            for floating in map.floatingTopics {
                add(floating.node, slot: .floating, position: floating.position)
            }
        }

        private mutating func add(_ node: Node, slot: Slot, position: CGPoint?) {
            var fields = MapMerge.fields(of: node)
            if let position, let value = try? MapMerge.json(position) { fields[MapMerge.positionKey] = value }
            entries[node.id] = Entry(slot: slot, fields: fields)
            order[slot, default: []].append(node.id)
            for child in node.children { add(child, slot: .child(of: node.id), position: nil) }
        }

        /// Ancestor chain (nearest first) by `slot`.
        func parent(of id: UUID) -> UUID? {
            if case let .child(parent)? = entries[id]?.slot { return parent }
            return nil
        }
    }

    // MARK: - Merger

    private struct Merger {
        let base: Flat
        let local: Flat
        let remote: Flat
        let baseMap: MindMap
        let localSide: Side
        let remoteSide: Side
        let localIsNewer: Bool
        var conflicts: [Conflict] = []
        var result: [UUID: Entry] = [:]
        /// Which side each kept topic's position came from (for ordering).
        var positionSource: [UUID: Bool] = [:] // true = local

        init(base: MindMap, local: Side, remote: Side) {
            self.base = Flat(base)
            self.local = Flat(local.map)
            self.remote = Flat(remote.map)
            baseMap = base
            localSide = local
            remoteSide = remote
            localIsNewer = local.modified >= remote.modified
        }

        mutating func run() -> Result {
            // Different central topics (unrelated maps): no structural merge.
            guard local.rootID == remote.rootID else {
                return Result(map: localIsNewer ? localSide.map : remoteSide.map, conflicts: [])
            }
            var ids = Set(local.entries.keys).union(remote.entries.keys)
            ids.formUnion(base.entries.keys)
            for id in ids { decide(id) }
            resurrectAncestors()
            breakCycles()
            var map = build()
            addTextConflictCopies(to: &map)
            return Result(map: map, conflicts: conflicts)
        }

        // MARK: Per topic

        private mutating func decide(_ id: UUID) {
            let b = base.entries[id], l = local.entries[id], r = remote.entries[id]
            switch (l, r) {
            case (nil, nil):
                return
            case let (l?, nil):
                if let b {
                    // Deleted remotely: kept only if edited locally.
                    guard l.fields != b.fields else { return }
                    conflicts.append(Conflict(nodeID: id, kind: .deleteVsEdit))
                }
                result[id] = l
                positionSource[id] = true
            case let (nil, r?):
                if let b {
                    guard r.fields != b.fields else { return }
                    conflicts.append(Conflict(nodeID: id, kind: .deleteVsEdit))
                }
                result[id] = r
                positionSource[id] = false
            case let (l?, r?):
                let fields = mergeFields(id: id, base: b?.fields ?? [:], local: l.fields, remote: r.fields)
                let slot: Slot
                let fromLocal: Bool
                if l.slot == r.slot {
                    slot = l.slot; fromLocal = true
                } else if l.slot == b?.slot {
                    slot = r.slot; fromLocal = false
                } else if r.slot == b?.slot {
                    slot = l.slot; fromLocal = true
                } else {
                    slot = localIsNewer ? l.slot : r.slot; fromLocal = localIsNewer
                }
                result[id] = Entry(slot: slot, fields: fields)
                positionSource[id] = fromLocal
            }
        }

        private mutating func mergeFields(id: UUID, base: [String: JSONValue], local: [String: JSONValue],
                                          remote: [String: JSONValue]) -> [String: JSONValue] {
            var merged: [String: JSONValue] = [:]
            for key in Set(local.keys).union(remote.keys).union(base.keys) {
                let bv = base[key], lv = local[key], rv = remote[key]
                let value: JSONValue?
                if lv == rv {
                    value = lv
                } else if lv == bv {
                    value = rv
                } else if rv == bv {
                    value = lv
                } else if key == "attachments" {
                    value = mergeAttachments(base: bv, local: lv, remote: rv)
                } else {
                    value = localIsNewer ? lv : rv
                    if key == "text" {
                        textConflicts.append((id, localIsNewer ? rv : lv))
                    } else {
                        conflicts.append(Conflict(nodeID: id, kind: .field(key)))
                    }
                }
                if let value { merged[key] = value }
            }
            return merged
        }

        /// Older texts to keep as "conflicting edit" topics.
        private var textConflicts: [(UUID, JSONValue?)] = []

        private func mergeAttachments(base: JSONValue?, local: JSONValue?, remote: JSONValue?) -> JSONValue? {
            func items(_ value: JSONValue?) -> [(String, JSONValue)] {
                guard case let .array(list)? = value else { return [] }
                return list.compactMap { item in
                    if case let .object(fields) = item, case let .string(id)? = fields["id"] { return (id, item) }
                    return nil
                }
            }
            let b = Dictionary(items(base), uniquingKeysWith: { a, _ in a })
            let l = items(local), r = items(remote)
            let lMap = Dictionary(l, uniquingKeysWith: { a, _ in a })
            let rMap = Dictionary(r, uniquingKeysWith: { a, _ in a })
            var out: [JSONValue] = []
            var seen = Set<String>()
            let first = localIsNewer ? l : r
            let second = localIsNewer ? r : l
            for (id, _) in first + second where seen.insert(id).inserted {
                let bv = b[id], lv = lMap[id], rv = rMap[id]
                let value: JSONValue?
                switch (lv, rv) {
                case let (lv?, rv?):
                    if lv == rv || rv == bv { value = lv } else if lv == bv { value = rv } else { value = localIsNewer ? lv : rv }
                case let (lv?, nil):
                    value = (bv != nil && lv == bv) ? nil : lv
                case let (nil, rv?):
                    value = (bv != nil && rv == bv) ? nil : rv
                case (nil, nil):
                    value = nil
                }
                if let value { out.append(value) }
            }
            return .array(out)
        }

        // MARK: Structure repair

        /// A kept topic whose parent was deleted on the side it came from:
        /// bring the parent back (from whichever side still has it).
        private mutating func resurrectAncestors() {
            var changed = true
            while changed {
                changed = false
                let missing = Set(result.values.compactMap { entry -> UUID? in
                    guard case let .child(parent) = entry.slot, result[parent] == nil else { return nil }
                    return parent
                })
                for parent in missing {
                    guard let restored = local.entries[parent] ?? remote.entries[parent] ?? base.entries[parent] else {
                        continue
                    }
                    result[parent] = restored
                    positionSource[parent] = local.entries[parent] != nil
                    changed = true
                }
            }
            // Parents nobody has any more: attach to the central topic.
            for (id, entry) in result {
                if case let .child(parent) = entry.slot, result[parent] == nil, let root = local.rootID, id != root {
                    result[id]?.slot = .child(of: root)
                }
            }
        }

        /// Moves on both sides can form a cycle (A under B here, B under A
        /// there): such topics go back to their local parent.
        private mutating func breakCycles() {
            var attempts = 0
            while let cycle = findCycle() {
                attempts += 1
                for id in cycle {
                    if attempts <= result.count, let slot = local.entries[id]?.slot ?? base.entries[id]?.slot {
                        result[id]?.slot = slot
                    } else if let root = local.rootID {
                        result[id]?.slot = .child(of: root)
                    }
                    positionSource[id] = true
                }
            }
        }

        private func findCycle() -> [UUID]? {
            for start in result.keys {
                var path: [UUID] = []
                var seen = Set<UUID>()
                var current = start
                while case let .child(parent)? = result[current]?.slot {
                    if !seen.insert(current).inserted {
                        if let index = path.firstIndex(of: current) { return Array(path[index...]) }
                        return path
                    }
                    path.append(current)
                    current = parent
                }
            }
            return nil
        }

        // MARK: Build

        private func orderedChildren(of slot: Slot) -> [UUID] {
            let members = Set(result.compactMap { $0.value.slot == slot ? $0.key : nil })
            let b = (base.order[slot] ?? []).filter(members.contains)
            let l = (local.order[slot] ?? []).filter(members.contains)
            let r = (remote.order[slot] ?? []).filter(members.contains)
            var order: [UUID]
            if l == b { order = r } else if r == b { order = l } else { order = localIsNewer ? l : r }
            // Topics missing from the chosen order: after their predecessor
            // in the list they came from.
            for id in (localIsNewer ? l + r : r + l) where !order.contains(id) {
                let source = positionSource[id] == true ? l : r
                if let index = source.firstIndex(of: id), index > 0, let at = order.firstIndex(of: source[index - 1]) {
                    order.insert(id, at: at + 1)
                } else if source.first == id {
                    order.insert(id, at: 0)
                } else {
                    order.append(id)
                }
            }
            for id in members.sorted(by: { $0.uuidString < $1.uuidString }) where !order.contains(id) {
                order.append(id)
            }
            return order
        }

        private func node(_ id: UUID) -> Node? {
            guard let entry = result[id] else { return nil }
            var fields = entry.fields
            fields[MapMerge.positionKey] = nil
            guard var node = MapMerge.node(from: fields) else { return nil }
            node.children = orderedChildren(of: .child(of: id)).compactMap(self.node)
            return node
        }

        private func build() -> MindMap {
            let source = localIsNewer ? localSide.map : remoteSide.map
            var map = source
            if let rootID = local.rootID, let root = node(rootID) { map.root = root }
            map.floatingTopics = orderedChildren(of: .floating).compactMap { id in
                guard let node = node(id) else { return nil }
                let position = result[id]?.fields[MapMerge.positionKey].flatMap { try? MapMerge.decode(CGPoint.self, $0) }
                return FloatingTopic(node: node, position: position ?? .zero)
            }
            map.theme = scalar(baseMap.theme, localSide.map.theme, remoteSide.map.theme)
            map.taskPanel = scalar(baseMap.taskPanel, localSide.map.taskPanel, remoteSide.map.taskPanel)
            map.title = scalar(baseMap.title, localSide.map.title, remoteSide.map.title)
            map.isReadOnly = scalar(baseMap.isReadOnly, localSide.map.isReadOnly, remoteSide.map.isReadOnly)
            let existing = Set(map.allNodeIDsForMerge)
            map.relationships = items(baseMap.relationships, localSide.map.relationships, remoteSide.map.relationships)
                .filter { existing.contains($0.fromNodeID) && existing.contains($0.toNodeID) }
            map.boundaries = items(baseMap.boundaries, localSide.map.boundaries, remoteSide.map.boundaries)
                .compactMap { boundary in
                    var boundary = boundary
                    boundary.memberIDs = boundary.memberIDs.filter(existing.contains)
                    return boundary.memberIDs.isEmpty ? nil : boundary
                }
            return map
        }

        private func scalar<T: Equatable>(_ b: T, _ l: T, _ r: T) -> T {
            if l == r || r == b { return l }
            if l == b { return r }
            return localIsNewer ? l : r
        }

        private func items<T: Identifiable & Equatable>(_ b: [T], _ l: [T], _ r: [T]) -> [T] where T.ID == UUID {
            let bMap = Dictionary(b.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let lMap = Dictionary(l.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let rMap = Dictionary(r.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var out: [T] = []
            var seen = Set<UUID>()
            for item in (localIsNewer ? l + r : r + l) where seen.insert(item.id).inserted {
                let bv = bMap[item.id], lv = lMap[item.id], rv = rMap[item.id]
                switch (lv, rv) {
                case let (lv?, rv?):
                    out.append(lv == rv || rv == bv ? lv : (lv == bv ? rv : (localIsNewer ? lv : rv)))
                case let (lv?, nil):
                    if bv == nil || lv != bv { out.append(lv) }
                case let (nil, rv?):
                    if bv == nil || rv != bv { out.append(rv) }
                case (nil, nil):
                    break
                }
            }
            return out
        }

        private mutating func addTextConflictCopies(to map: inout MindMap) {
            for (id, olderText) in textConflicts {
                guard case let .string(text)? = olderText else { continue }
                let copy = Node(text: text + MapMerge.conflictSuffix)
                if map.insertConflictCopy(copy, besides: id) {
                    conflicts.append(Conflict(nodeID: id, kind: .text(copyID: copy.id)))
                }
            }
        }
    }

    // MARK: - JSON helpers

    static func fields(of node: Node) -> [String: JSONValue] {
        var shallow = node
        shallow.children = []
        guard case var .object(fields)? = try? json(shallow) else { return [:] }
        fields["children"] = nil
        return fields
    }

    static func node(from fields: [String: JSONValue]) -> Node? {
        try? decode(Node.self, .object(fields))
    }

    static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}

private extension MindMap {
    var allNodeIDsForMerge: [UUID] {
        var ids: [UUID] = []
        func walk(_ node: Node) {
            ids.append(node.id)
            node.children.forEach(walk)
        }
        walk(root)
        floatingTopics.forEach { walk($0.node) }
        return ids
    }

    /// Inserts `copy` right after topic `id` (as its last child when `id`
    /// is the central topic or a floating topic).
    mutating func insertConflictCopy(_ copy: Node, besides id: UUID) -> Bool {
        if root.id == id {
            root.children.append(copy)
            return true
        }
        if let index = floatingTopics.firstIndex(where: { $0.node.id == id }) {
            floatingTopics[index].node.children.append(copy)
            return true
        }
        if root.insertSibling(copy, after: id) { return true }
        for index in floatingTopics.indices where floatingTopics[index].node.insertSibling(copy, after: id) {
            return true
        }
        return false
    }
}

private extension Node {
    mutating func insertSibling(_ copy: Node, after id: UUID) -> Bool {
        if let index = children.firstIndex(where: { $0.id == id }) {
            children.insert(copy, at: index + 1)
            return true
        }
        for index in children.indices where children[index].insertSibling(copy, after: id) {
            return true
        }
        return false
    }
}
