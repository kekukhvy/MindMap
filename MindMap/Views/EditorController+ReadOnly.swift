import SwiftUI

/// "Map is locked — unlock to edit" (WP15): short, non-modal, with Unlock.
struct ReadOnlyNotice: Equatable, Identifiable {
    /// Stable while the notice stays up (repeated refusals re-arm it).
    var id = UUID()
    /// Changes on every refusal: only the latest one hides it.
    var token = UUID()
}

/// "Lock Editing" (WP15). The map model is the gate (`MindMapModel
/// +ReadOnly`: every refused change reports here and shows the notice);
/// this layer keeps the UI from even starting an edit (inline rename,
/// drag, pick modes, editors) and tells which commands / menu items are
/// edits (disabled while locked).
extension EditorController {
    static let readOnlyMessage = "Map is locked — unlock to edit"
    static let readOnlyNoticeDuration: TimeInterval = 2.5

    var isReadOnly: Bool { model.map.isReadOnly }
    var canEdit: Bool { !model.map.isReadOnly }

    /// The toolbar toggle / Edit ▸ Lock Editing (⌥⌘L): one undo step.
    /// Locking first commits a rename in progress and ends drags / pick modes.
    func setReadOnly(_ readOnly: Bool) {
        guard readOnly != isReadOnly else { return }
        if readOnly { finishInteractionsForLock() }
        model.setReadOnly(readOnly, undoManager: undoManager)
        if !readOnly { readOnlyNotice = nil }
        refreshUndoState()
    }

    func toggleReadOnly() {
        setReadOnly(!isReadOnly)
    }

    /// Starting an edit: true when the map may change, else the notice.
    @discardableResult
    func requireEditable() -> Bool {
        guard isReadOnly else { return true }
        showReadOnlyNotice()
        return false
    }

    func showReadOnlyNotice() {
        var notice = readOnlyNotice ?? ReadOnlyNotice()
        notice.token = UUID()
        let token = notice.token
        withAnimation(.easeOut(duration: 0.15)) { readOnlyNotice = notice }
        noticeScheduler(Self.readOnlyNoticeDuration) { [weak self] in
            guard let self, self.readOnlyNotice?.token == token else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.readOnlyNotice = nil }
        }
    }

    /// Unlock button of the notice.
    func unlockFromNotice() {
        setReadOnly(false)
    }

    private func finishInteractionsForLock() {
        commitEditing()
        cancelPick()
        if boundaryMemberEditing != nil { finishEditBoundaryMembers(commit: true) }
        drag = nil
        controlDrag = nil
        taskPanelDrag = nil
        favoritesPanelDrag = nil
        dueDatePickerID = nil
        linkEditor = nil
        colorSheet = nil
        fileDropTargetID = nil
    }

    /// Topic an undone / redone fold keeps still (WP17 anchoring): the
    /// topmost toggled topic; several (Collapse to Level, Expand All): the
    /// selection, else the first of them.
    func replayAnchor(for toggled: [UUID]) -> UUID? {
        let ids = Set(toggled)
        let map = model.map
        let topmost = toggled.filter { id in
            var parent = map.parentID(of: id)
            while let current = parent {
                if ids.contains(current) { return false }
                parent = map.parentID(of: current)
            }
            return true
        }
        if topmost.count == 1 { return topmost[0] }
        if let selectedID, scene.nodes[selectedID] != nil { return selectedID }
        return topmost.first
    }
}

extension EditorCommand {
    /// Changes the map (refused on a read-only map). Opening an existing
    /// note is not an edit: `.note` / `.handwrittenNote` decide themselves.
    var isEdit: Bool {
        switch self {
        case .addChild, .addSibling, .delete, .edit, .editReplacing, .addRelationship, .addBoundary, .attachFile,
             .editLink, .toggleTaskDone, .cut, .paste:
            return true
        case .undo, .redo, .move, .toggleCollapse, .zoomIn, .zoomOut, .zoomToFit, .note, .handwrittenNote,
             .collapseToLevel, .expandAll, .goBack, .selectAll, .cancel, .toggleReadOnly, .copy:
            return false
        }
    }
}

extension TopicMenuAction {
    /// Whether the item still works on a read-only map: following / copying
    /// links, opening existing notes and attachments (read-only), unlocking
    /// a locked note to read it.
    func isAllowedWhileReadOnly(_ facts: TopicMenuFacts) -> Bool {
        switch self {
        case .goToLink, .copyLink, .openAttachment: return true
        case .openOrAddNote: return facts.hasNote
        case .openOrAddDrawing: return facts.hasDrawing
        case let .noteLock(action):
            if case .unlock = action { return true }
            return false
        case .convertToTask, .toggleDone, .setPriority, .setDue, .chooseDueDate, .clearDueDate, .convertToTopic,
             .editLink, .locateMap, .removeLink, .addNote, .deleteNote, .addDrawing, .attachFile, .pasteFile,
             .moveAttachment, .removeAttachment:
            return false
        }
    }
}

extension PaletteAction {
    /// Palette buttons that change the map (`.note` / `.link` open or go
    /// to what exists; `.collapse` folds).
    var isEdit: Bool {
        switch self {
        case .note, .link, .collapse, .more: return false
        case .addChild, .addSibling, .rename, .delete, .task, .boundary, .floatingTopic, .drawing, .attachFile,
             .relationship:
            return true
        }
    }
}
