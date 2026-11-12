import Foundation

/// Undoable topic-link operations (one undo step each; false = invalid or
/// no change).
extension MindMapModel {
    /// Sets, replaces or (nil) removes `id`'s link.
    @discardableResult
    func setLink(_ link: TopicLink?, for id: UUID, undoManager: UndoManager?) -> Bool {
        guard let edits = try? map.setLinkEdits(link, for: id), !edits.isEmpty else { return false }
        let name = link == nil ? "Remove Link" : (map.link(of: id) == nil ? "Add Link" : "Edit Link")
        return perform(edits, actionName: name, undoManager: undoManager)
    }

    @discardableResult
    func removeLink(from id: UUID, undoManager: UndoManager?) -> Bool {
        setLink(nil, for: id, undoManager: undoManager)
    }

    /// Expands the collapsed ancestors of `id` (Go to a hidden topic). The
    /// collapse state is document data (saved, undoable everywhere else), so
    /// this is one undo step "Show Topic"; false if `id` was visible.
    @discardableResult
    func revealTopic(_ id: UUID, undoManager: UndoManager?) -> Bool {
        let edits = map.revealEdits(id)
        guard !edits.isEmpty else { return false }
        return perform(edits, actionName: "Show Topic", undoManager: undoManager)
    }
}
