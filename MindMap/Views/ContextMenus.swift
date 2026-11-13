import SwiftUI

/// Long-press (iPad) / right-click (macOS) menu of a topic.
struct NodeContextMenu: View {
    let editor: EditorController
    let id: UUID

    var body: some View {
        Group {
            if editor.isMultiSelection && editor.isSelected(id) {
                MultiTopicMenuItems(editor: editor, id: id)
            } else {
                items
            }
        }
        // Right click / long press selects the topic first (a topic of the
        // multi-selection keeps the selection: the menu acts on all).
        .onAppear { if !editor.isSelected(id) { editor.select(id) } }
    }

    @ViewBuilder private var items: some View {
        let info = editor.scene.nodes[id]
        let isMainRoot = id == editor.model.root.id
        let isFloatingRoot = editor.model.map.isFloatingRoot(id)
        // Read-only map (WP15): edit items disabled, folding / links / opening stay.
        let locked = editor.isReadOnly
        Group {
            Button("Rename", systemImage: "pencil") { editor.beginEditing(id) }
            Button("Add Child Topic", systemImage: "arrow.turn.down.right") {
                editor.select(id)
                editor.addChild()
            }
            Button("Add Sibling Topic", systemImage: "plus") {
                editor.select(id)
                editor.addSibling()
            }
            .disabled(info?.isTreeRoot ?? true)
            LayoutStyleMenu(editor: editor, id: id)
        }
        .disabled(locked)
        ClipboardMenuItems(editor: editor, id: id)
        if info?.hasChildren == true {
            Button(info?.isCollapsed == true ? "Expand" : "Collapse",
                   systemImage: info?.isCollapsed == true ? "plus.circle" : "minus.circle") {
                editor.toggleCollapse(id)
            }
            Button("Expand Branch", systemImage: "plus.square.on.square") { editor.expandBranch(id) }
            Button("Collapse Branch", systemImage: "minus.square") { editor.collapseBranch(id) }
            SortChildrenMenu(editor: editor, id: id)
                .disabled(locked)
        }
        if editor.isFreelyPositioned(id) {
            Button("Reset Position", systemImage: "arrow.uturn.backward.circle") { editor.resetPositions(in: id) }
                .disabled(locked)
        }
        if isMainRoot {
            Divider()
            OutlineMenuItems(editor: editor)
        }
        FavoriteMenuItem(editor: editor, id: id)
        Divider()
        TopicSubmenusView(facts: editor.menuFacts(for: id)) { editor.performMenuAction($0, on: id) }
        Divider()
        Group {
            Button("Relationship", systemImage: "arrow.triangle.turn.up.right.diamond") {
                editor.beginRelationship(from: id)
            }
            if !isMainRoot {
                Button("Boundary", systemImage: "square.dashed") { editor.addBoundaryFromSelection(id) }
            }
            if isFloatingRoot {
                Button("Attach to…", systemImage: "link") { editor.beginAttach(id) }
            } else if !isMainRoot {
                Button("Detach as Floating", systemImage: "rectangle.dashed") { editor.detachAsFloating(id) }
            }
        }
        .disabled(locked)
        Divider()
        NodeFormatMenus(editor: editor, id: id, includesLayout: false)
        if !isMainRoot {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                editor.select(id)
                editor.deleteSelection()
            }
            .disabled(locked)
        }
    }
}

/// Menu of a topic that is part of a multi-selection: "N Topics" header,
/// then the actions that apply to all of them (one undo step each).
struct MultiTopicMenuItems: View {
    let editor: EditorController
    let id: UUID

    var body: some View {
        let ids = editor.selection
        let nodes = ids.compactMap { editor.model.map.node(withID: $0) }
        let reference = editor.model.map.node(withID: id)
        let locked = editor.isReadOnly
        Text("\(ids.count) Topics")
        Divider()
        LayoutStyleMenu(editor: editor, id: id)
        if nodes.contains(where: { !$0.children.isEmpty }) {
            let collapsed = reference?.isCollapsed == true
            Button(collapsed ? "Expand" : "Collapse", systemImage: collapsed ? "plus.circle" : "minus.circle") {
                editor.toggleCollapseTargets(id)
            }
        }
        ClipboardMenuItems(editor: editor, id: id)
        FavoriteMenuItem(editor: editor, id: id)
        Divider()
        // Task ▸ applies to all; Link / Note / Attachments ▸ are disabled
        // (one topic only).
        TopicSubmenusView(facts: editor.menuFacts(for: id)) { editor.performMenuAction($0, on: id) }
        Divider()
        Button("Add Boundary", systemImage: "square.dashed") { editor.addBoundaryFromSelection(id) }
            .disabled(locked || editor.model.map.movableTopics(ids).isEmpty)
        Divider()
        NodeFormatMenus(editor: editor, id: id, includesLayout: false)
        Divider()
        Button("Delete \(ids.count) Topics", systemImage: "trash", role: .destructive) {
            editor.deleteSelectedTopics()
        }
        .disabled(locked || editor.model.map.movableTopics(ids).isEmpty)
    }
}

/// Secondary-click menu on empty canvas (macOS).
struct CanvasBackgroundMenu: View {
    let editor: EditorController

    var body: some View {
        Button("Add Floating Topic Here", systemImage: "rectangle.dashed") {
            editor.addFloatingTopic(at: editor.contextPoint)
        }
        .disabled(editor.isReadOnly)
        Button("Paste", systemImage: "doc.on.clipboard") {
            editor.select(nil)
            editor.paste()
        }
        .disabled(!editor.canPaste)
        Divider()
        OutlineMenuItems(editor: editor)
    }
}

/// "Mark as Favorite" / "Remove from Favorites" for a topic or the
/// multi-selection it belongs to (one undo step).
struct FavoriteMenuItem: View {
    let editor: EditorController
    let id: UUID

    var body: some View {
        let remove = editor.targetsAreFavorites(for: id)
        Button(remove ? "Remove from Favorites" : "Mark as Favorite", systemImage: remove ? "star.slash" : "star") {
            editor.toggleFavorite(id)
        }
        .disabled(editor.isReadOnly)
    }
}

/// Sort Children ▸ A → Z / Z → A: reorders a topic's direct children by
/// their text (one undo step).
struct SortChildrenMenu: View {
    let editor: EditorController
    let id: UUID

    var body: some View {
        Menu {
            Button("A → Z", systemImage: "arrow.down") { editor.sortChildren(id, ascending: true) }
            Button("Z → A", systemImage: "arrow.up") { editor.sortChildren(id, ascending: false) }
        } label: {
            Label("Sort Children", systemImage: "arrow.up.arrow.down")
        }
    }
}

/// Cut / Copy / Paste of a topic or of the multi-selection it belongs to
/// (Paste puts the clipboard's topics inside `id`).
struct ClipboardMenuItems: View {
    let editor: EditorController
    let id: UUID

    var body: some View {
        let isRoot = id == editor.model.root.id
        Divider()
        Button("Cut", systemImage: "scissors") {
            if !editor.isSelected(id) { editor.select(id) }
            editor.cutSelection()
        }
        .disabled(editor.isReadOnly || (isRoot && !editor.isMultiSelection))
        Button("Copy", systemImage: "doc.on.doc") {
            if !editor.isSelected(id) { editor.select(id) }
            editor.copySelection()
        }
        Button("Paste", systemImage: "doc.on.clipboard") {
            editor.select(id)
            editor.paste()
        }
        .disabled(!editor.canPaste)
    }
}

/// Map-wide outline items: Collapse to Level 1-4, Expand All, Reset All
/// Positions, Rebalance Map (context menus and the toolbar Outline menu;
/// the menu bar View menu has the same items with Cmd+Option+1...4 / 0).
struct OutlineMenuItems: View {
    let editor: EditorController

    var body: some View {
        ForEach(1...4, id: \.self) { level in
            Button("Collapse to Level \(level)") { editor.collapseToLevel(level) }
        }
        Button("Expand All", systemImage: "arrow.down.right.and.arrow.up.left") { editor.expandAll() }
        // Folding stays available on a read-only map (WP15); layout does not.
        Button("Reset All Positions", systemImage: "arrow.uturn.backward.circle") { editor.resetPositions() }
            .disabled(editor.isReadOnly || !editor.hasManualPosition())
        Button("Rebalance Map", systemImage: "arrow.left.arrow.right") { editor.rebalanceMap() }
            .disabled(editor.isReadOnly || !editor.canRebalance)
    }
}

/// Tasks panel row menu: Show Topic, then the items of Task ▸ (the same
/// entries as the topic menus; Mark as Done keeps the row lingering).
struct TaskMenuItems: View {
    let editor: EditorController
    let id: UUID

    var body: some View {
        Button("Show Topic", systemImage: "scope") { editor.showTask(id) }
        Divider()
        TopicMenuEntriesView(entries: TopicMenus.taskEntries(editor.menuFacts(for: id))) { action in
            if action == .toggleDone { editor.togglePanelTask(id) } else { editor.performMenuAction(action, on: id) }
        }
    }
}
