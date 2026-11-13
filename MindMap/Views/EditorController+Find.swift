import SwiftUI

/// Find (⌘F). All of it is view state: the filter hides topics in the
/// scene only, nothing here touches the document or the undo stack.
extension EditorController {
    /// The map with the filter applied while the find bar shows a phrase.
    var findFilteredMap: MindMap? {
        guard isFindOpen, !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return model.map.filtered(keeping: model.map.findVisibleIDs(findMatches))
    }

    var currentFindMatch: FindMatch? {
        findMatches.indices.contains(findIndex) ? findMatches[findIndex] : nil
    }

    /// ⌘F: opens the bar (or puts the cursor back into its field).
    func openFind() {
        commitEditing()
        isFindOpen = true
        findFocusToken += 1
        refreshFind()
    }

    /// Esc / close button: the full map comes back, the selected topic
    /// stays where it is on screen.
    func closeFind() {
        keepingOnScreen(selectedID) { isFindOpen = false }
    }

    /// Recomputes the matches (query or map changed). A new query starts at
    /// the first match and shows it.
    func refreshFind(newQuery: Bool = false) {
        findMatches = model.findMatches(findQuery)
        findIndex = newQuery ? 0 : min(findIndex, max(findMatches.count - 1, 0))
        if newQuery { showCurrentFindMatch() }
    }

    /// ⌘G / ⇧⌘G and the bar's arrows: next / previous match, wrapping around.
    func stepFind(forward: Bool) {
        guard !findMatches.isEmpty else { return }
        let count = findMatches.count
        findIndex = (findIndex + (forward ? 1 : count - 1)) % count
        showCurrentFindMatch()
    }

    /// Return in the find field: opens the note of a note match, else next.
    func submitFind() {
        if let noteID = currentFindMatch?.noteID { openAttachment(noteID) } else { stepFind(forward: true) }
    }

    /// Selects the current match and scrolls it into view (the filter
    /// already shows its ancestors, so the document is not changed).
    private func showCurrentFindMatch() {
        guard let id = currentFindMatch?.topicID else { return }
        select(id)
        guard let frame = scene.layout.frames[id] else { return }
        let target = viewport.focusing(frame, in: viewSize)
        guard target != viewport else { return }
        withAnimation(.easeInOut(duration: 0.35)) { viewport = target }
    }
}
