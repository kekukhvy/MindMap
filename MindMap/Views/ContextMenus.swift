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
        if editor.link(of: id) != nil {
            GoToLinkButton(editor: editor, id: id)
            Divider()
        }
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
        if info?.hasChildren == true {
            Button(info?.isCollapsed == true ? "Expand" : "Collapse",
                   systemImage: info?.isCollapsed == true ? "plus.circle" : "minus.circle") {
                editor.toggleCollapse(id)
            }
            Button("Expand Branch", systemImage: "plus.square.on.square") { editor.expandBranch(id) }
            Button("Collapse Branch", systemImage: "minus.square") { editor.collapseBranch(id) }
        }
        if editor.isFreelyPositioned(id) {
            Button("Reset Position", systemImage: "arrow.uturn.backward.circle") { editor.resetPositions(in: id) }
        }
        if isMainRoot {
            Divider()
            OutlineMenuItems(editor: editor)
        }
        Divider()
        TaskMenuItems(editor: editor, id: id)
        Divider()
        AttachmentMenuItems(editor: editor, id: id)
        Divider()
        LinkMenuItems(editor: editor, id: id)
        Divider()
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
        Divider()
        NodeFormatMenus(editor: editor, id: id, includesLayout: false)
        if !isMainRoot {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                editor.select(id)
                editor.deleteSelection()
            }
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
        Text("\(ids.count) Topics")
        Divider()
        LayoutStyleMenu(editor: editor, id: id)
        if nodes.contains(where: { !$0.children.isEmpty }) {
            let collapsed = reference?.isCollapsed == true
            Button(collapsed ? "Expand" : "Collapse", systemImage: collapsed ? "plus.circle" : "minus.circle") {
                editor.toggleCollapseTargets(id)
            }
        }
        Divider()
        if nodes.contains(where: { $0.task == nil }) {
            Button("Convert to Task", systemImage: "checkmark.circle") { editor.convertToTask(id) }
        }
        if let task = reference?.task {
            Button(task.isDone ? "Mark as Not Done" : "Mark as Done",
                   systemImage: task.isDone ? "circle" : "checkmark.circle") { editor.toggleTargetsDone(id) }
        }
        if nodes.contains(where: { $0.task != nil }) {
            Button("Convert to Topic", systemImage: "circle.slash") { editor.convertToTopic(id) }
        }
        Divider()
        Button("Add Boundary", systemImage: "square.dashed") { editor.addBoundaryFromSelection(id) }
            .disabled(editor.model.map.movableTopics(ids).isEmpty)
        Divider()
        NodeFormatMenus(editor: editor, id: id, includesLayout: false)
        Divider()
        Button("Delete \(ids.count) Topics", systemImage: "trash", role: .destructive) {
            editor.deleteSelectedTopics()
        }
        .disabled(editor.model.map.movableTopics(ids).isEmpty)
    }
}

/// Secondary-click menu on empty canvas (macOS).
struct CanvasBackgroundMenu: View {
    let editor: EditorController

    var body: some View {
        Button("Add Floating Topic Here", systemImage: "rectangle.dashed") {
            editor.addFloatingTopic(at: editor.contextPoint)
        }
        Divider()
        OutlineMenuItems(editor: editor)
    }
}

/// Map-wide outline items: Collapse to Level 1-4, Expand All, Reset All
/// Positions (context menus and the toolbar Outline menu; the menu bar
/// View menu has the same items with Cmd+Option+1...4 / 0).
struct OutlineMenuItems: View {
    let editor: EditorController

    var body: some View {
        ForEach(1...4, id: \.self) { level in
            Button("Collapse to Level \(level)") { editor.collapseToLevel(level) }
        }
        Button("Expand All", systemImage: "arrow.down.right.and.arrow.up.left") { editor.expandAll() }
        Button("Reset All Positions", systemImage: "arrow.uturn.backward.circle") { editor.resetPositions() }
            .disabled(!editor.hasManualPosition())
    }
}

/// Notes / attachments of a topic: Add Note / Handwritten Note / Attach
/// File… / Paste File, then each attachment with
/// Open, Move and Remove (icons on the topic open them directly).
struct AttachmentMenuItems: View {
    let editor: EditorController
    let id: UUID

    var body: some View {
        let attachments = editor.attachments(of: id)
        Button("Add Note", systemImage: "note.text.badge.plus") { editor.addNote(to: id) }
        Button("Add Handwritten Note", systemImage: "pencil.and.scribble") { editor.addDrawing(to: id) }
        Button("Attach File…", systemImage: "paperclip") { editor.beginAttachFile(to: id) }
        Button("Paste File", systemImage: "doc.on.clipboard") {
            editor.select(id)
            editor.pasteFiles(to: id)
        }
        ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
            Menu(attachment.title.isEmpty ? attachment.kind.displayName : attachment.title,
                 systemImage: attachment.kind.systemImage) {
                Button("Open", systemImage: "arrow.up.forward.square") {
                    editor.select(id)
                    editor.openAttachment(attachment.id)
                }
                if attachments.count > 1 {
                    Button("Move Left", systemImage: "arrow.left") { editor.moveAttachment(attachment.id, by: -1) }
                        .disabled(index == 0)
                    Button("Move Right", systemImage: "arrow.right") { editor.moveAttachment(attachment.id, by: 1) }
                        .disabled(index == attachments.count - 1)
                }
                Divider()
                Button("Remove", systemImage: "trash", role: .destructive) { editor.removeAttachment(attachment.id) }
            }
        }
    }
}

/// First, prominent item of a linked topic's menu: "Go to “target”".
struct GoToLinkButton: View {
    let editor: EditorController
    let id: UUID

    var body: some View {
        Button { editor.goToLink(of: id) } label: {
            Label { Text(title).bold() } icon: { Image(systemName: icon) }
        }
    }

    private var icon: String {
        switch editor.link(of: id) {
        case .web: return "safari"
        case .map: return "macwindow.badge.plus"
        default: return "arrow.right.circle"
        }
    }

    private var title: String {
        switch editor.model.map.resolvedLink(of: id) {
        case let .web(url): return "Go to “\(Self.short(LinkURL.displayString(url)))”"
        case let .topic(target):
            let text = LinkCandidate.displayText(editor.model.map.node(withID: target)?.text ?? "")
            return "Go to “\(Self.short(text))”"
        case .brokenTopic: return "Go to (Deleted Topic)"
        case let .map(reference): return "Open “\(Self.short(reference.displayName))”"
        case nil: return "Go to"
        }
    }

    private static func short(_ text: String) -> String {
        text.count > 40 ? String(text.prefix(39)) + "…" : text
    }
}

/// Add / Edit Link… (⌘K), Locate… (missing map file), Copy Link, Remove Link.
struct LinkMenuItems: View {
    let editor: EditorController
    let id: UUID

    var body: some View {
        let link = editor.link(of: id)
        Button(link == nil ? "Add Link…" : "Edit Link…", systemImage: "link") { editor.beginEditLink(id) }
        if link != nil {
            if link?.mapReference != nil, editor.resolvedMapURL(of: id) == nil {
                // Missing map file: relink (also offered when Go to fails).
                Button("Locate…", systemImage: "magnifyingglass") { editor.beginLocateMap(id) }
            }
            Button("Copy Link", systemImage: "doc.on.doc") { editor.copyLink(id) }
                .disabled(editor.model.map.resolvedLink(of: id)?.isBroken ?? true)
            Button("Remove Link", systemImage: "xmark.circle") { editor.removeLink(id) }
        }
    }
}

/// Task items: Convert to Task, or Mark as Done / Not Done (⌘⏎), Priority,
/// Due Date (quick picks, Choose Date…, Clear) and Convert to Topic.
struct TaskMenuItems: View {
    let editor: EditorController
    let id: UUID
    /// Tasks panel rows: "Show Topic" first.
    var includesGoTo = false

    var body: some View {
        if includesGoTo {
            Button("Show Topic", systemImage: "scope") { editor.showTask(id) }
            Divider()
        }
        if let task = editor.task(of: id) {
            Button(task.isDone ? "Mark as Not Done" : "Mark as Done",
                   systemImage: task.isDone ? "circle" : "checkmark.circle") {
                if includesGoTo { editor.togglePanelTask(id) } else { editor.toggleTargetsDone(id) }
            }
            Menu("Priority", systemImage: "exclamationmark.circle") {
                ForEach(TaskPriority.allCases, id: \.self) { priority in
                    CheckItem("\(priority.title)  \(priority.mark)", checked: task.priority == priority) {
                        editor.setTaskPriority(priority, for: id)
                    }
                }
                Divider()
                CheckItem("None", checked: task.priority == nil) { editor.setTaskPriority(nil, for: id) }
            }
            Menu("Due Date", systemImage: "calendar") {
                ForEach(DueQuickPick.allCases, id: \.self) { pick in
                    Button(pick.title) { editor.setTaskDue(pick, for: id) }
                }
                Divider()
                Button("Choose Date…") { editor.beginDueDatePicker(id) }
                if task.dueDate != nil {
                    Button("Clear Due Date", role: .destructive) { editor.setTaskDueDate(nil, for: id) }
                }
            }
            Button("Convert to Topic", systemImage: "circle.slash") { editor.convertToTopic(id) }
        } else {
            Button("Convert to Task", systemImage: "checkmark.circle") { editor.convertToTask(id) }
        }
    }
}
