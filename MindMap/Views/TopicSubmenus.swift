import SwiftUI

// Task ▸ / Link ▸ / Note ▸ / Attachments ▸ — the four parallel topic
// submenus. ONE pure description (`TopicMenus`) is rendered by the topic
// context menu (macOS right-click, iPad long press and the action palette's
// "More") and by the Topic menu bar, so all of them show the same items in
// the same order with the same wording, icons and shortcuts. Items that do
// not apply are disabled, not hidden (stable structure).

/// Shortcut of a submenu item (registered by the Topic menu bar; shown in
/// the macOS context menu).
enum TopicMenuShortcut: Equatable {
    case commandReturn, commandK, shiftCommandN, shiftCommandD, shiftCommandA

    var keyboardShortcut: KeyboardShortcut {
        switch self {
        case .commandReturn: return KeyboardShortcut(.return, modifiers: .command)
        case .commandK: return KeyboardShortcut("k", modifiers: .command)
        case .shiftCommandN: return KeyboardShortcut("n", modifiers: [.command, .shift])
        case .shiftCommandD: return KeyboardShortcut("d", modifiers: [.command, .shift])
        case .shiftCommandA: return KeyboardShortcut("a", modifiers: [.command, .shift])
        }
    }
}

/// What a submenu item does (`EditorController.performMenuAction`).
enum TopicMenuAction: Hashable {
    // Task
    case convertToTask, toggleDone, setPriority(TaskPriority?), setDue(DueQuickPick), chooseDueDate,
         clearDueDate, convertToTopic
    // Link
    case editLink, goToLink, copyLink, locateMap, removeLink
    // Note
    case openOrAddNote, addNote, deleteNote
    // Attachments
    case openOrAddDrawing, addDrawing, attachFile, pasteFile
    case openAttachment(UUID), moveAttachment(UUID, by: Int), removeAttachment(UUID)
}

struct TopicMenuEntry: Equatable {
    enum Kind: Equatable {
        case button(TopicMenuAction)
        case submenu([TopicMenuEntry])
        case divider
    }

    var kind: Kind
    var title = ""
    var systemImage: String?
    var shortcut: TopicMenuShortcut?
    var isEnabled = true
    var isChecked = false
    var isDestructive = false

    static let divider = TopicMenuEntry(kind: .divider)

    static func button(_ title: String, _ systemImage: String?, _ action: TopicMenuAction,
                       shortcut: TopicMenuShortcut? = nil, enabled: Bool = true, checked: Bool = false,
                       destructive: Bool = false) -> TopicMenuEntry {
        TopicMenuEntry(kind: .button(action), title: title, systemImage: systemImage, shortcut: shortcut,
                       isEnabled: enabled, isChecked: checked, isDestructive: destructive)
    }

    static func submenu(_ title: String, _ systemImage: String?, enabled: Bool = true,
                        _ entries: [TopicMenuEntry]) -> TopicMenuEntry {
        TopicMenuEntry(kind: .submenu(entries), title: title, systemImage: systemImage, isEnabled: enabled)
    }

    /// Item titles (dividers as "-"), submenus as "Title ▸".
    var outline: String {
        switch kind {
        case .divider: return "-"
        case .submenu: return "\(title) ▸"
        case .button: return title
        }
    }
}

struct TopicSubmenu: Equatable {
    var title: String
    var systemImage: String
    var isEnabled: Bool
    var entries: [TopicMenuEntry]
}

/// Facts about the topic(s) a menu acts on (Equatable: also part of
/// `EditorCommandState` so the menu bar refreshes when they change).
struct TopicMenuFacts: Equatable {
    struct LinkFacts: Equatable {
        /// "Go to “Target”" / "Open “Map”".
        var goToTitle: String
        var goToSystemImage: String
        /// Not a deleted-topic link.
        var canCopy: Bool
        /// Link to another map: Locate… (relink a moved / missing file).
        var isMapLink: Bool
    }

    struct AttachmentFacts: Equatable {
        var id: UUID
        var title: String
        var systemImage: String
    }

    /// Topics the menu acts on (0 = nothing selected: all disabled).
    var count = 0
    /// Reference topic (the clicked / primary one).
    var isTask = false
    var isDoneTask = false
    var anyTask = false
    var anyNonTask = false
    /// Priority every task shares (nil: none or mixed).
    var commonPriority: TaskPriority?
    var allTasksWithoutPriority = false
    var anyDueDate = false
    var link: LinkFacts?
    var hasNote = false
    var hasDrawing = false
    var attachments: [AttachmentFacts] = []

    var isSingle: Bool { count == 1 }
}

enum TopicMenus {
    static func all(_ facts: TopicMenuFacts) -> [TopicSubmenu] {
        [task(facts), link(facts), note(facts), attachments(facts)]
    }

    /// Task ▸ Convert to Task / Mark as Done (⌘⏎) / Priority ▸ / Due Date ▸
    /// / Convert to Topic. Applies to the whole selection.
    static func task(_ facts: TopicMenuFacts) -> TopicSubmenu {
        TopicSubmenu(title: "Task", systemImage: "checklist", isEnabled: facts.count > 0,
                     entries: taskEntries(facts))
    }

    static func taskEntries(_ facts: TopicMenuFacts) -> [TopicMenuEntry] {
        let priorities = TaskPriority.allCases.map { priority in
            TopicMenuEntry.button("\(priority.title)  \(priority.mark)", nil, .setPriority(priority),
                                  checked: facts.commonPriority == priority)
        }
        let dueDates = DueQuickPick.allCases.map { TopicMenuEntry.button($0.title, nil, .setDue($0)) }
        return [
            .button("Convert to Task", "checkmark.circle", .convertToTask, enabled: facts.anyNonTask),
            .button(facts.isDoneTask ? "Mark as Not Done" : "Mark as Done",
                    facts.isDoneTask ? "circle" : "checkmark.circle.fill", .toggleDone,
                    shortcut: .commandReturn, enabled: facts.isTask),
            .submenu("Priority", "exclamationmark.circle", enabled: facts.anyTask, priorities + [
                .divider,
                .button("None", nil, .setPriority(nil), checked: facts.allTasksWithoutPriority),
            ]),
            .submenu("Due Date", "calendar", enabled: facts.anyTask, dueDates + [
                .divider,
                .button("Choose Date…", nil, .chooseDueDate, enabled: facts.isSingle),
                .button("Clear Due Date", nil, .clearDueDate, enabled: facts.anyDueDate),
            ]),
            .divider,
            .button("Convert to Topic", "circle.slash", .convertToTopic, enabled: facts.anyTask),
        ]
    }

    /// Link ▸ Add/Edit Link… (⌘K) / Go to … / Copy Link / Locate… (map
    /// links) / Remove Link. One topic only.
    static func link(_ facts: TopicMenuFacts) -> TopicSubmenu {
        let link = facts.link
        var entries: [TopicMenuEntry] = [
            .button(link == nil ? "Add Link…" : "Edit Link…", link == nil ? "link.badge.plus" : "pencil",
                    .editLink, shortcut: .commandK),
            .button(link?.goToTitle ?? "Go to Link", link?.goToSystemImage ?? "arrow.right.circle", .goToLink,
                    enabled: link != nil),
            .button("Copy Link", "doc.on.doc", .copyLink, enabled: link?.canCopy == true),
        ]
        if link?.isMapLink == true {
            entries.append(.button("Locate…", "magnifyingglass", .locateMap))
        }
        entries += [
            .divider,
            .button("Remove Link", "xmark.circle", .removeLink, enabled: link != nil),
        ]
        return TopicSubmenu(title: "Link", systemImage: "link", isEnabled: facts.isSingle, entries: entries)
    }

    /// Note ▸ Add/Open Note (⇧⌘N) / Add Another Note / Delete Note.
    static func note(_ facts: TopicMenuFacts) -> TopicSubmenu {
        TopicSubmenu(title: "Note", systemImage: "note.text", isEnabled: facts.isSingle, entries: [
            .button(facts.hasNote ? "Open Note" : "Add Note", facts.hasNote ? "note.text" : "note.text.badge.plus",
                    .openOrAddNote, shortcut: .shiftCommandN),
            .button("Add Another Note", "plus", .addNote, enabled: facts.hasNote),
            .divider,
            .button("Delete Note", "trash", .deleteNote, enabled: facts.hasNote, destructive: true),
        ])
    }

    /// Attachments ▸ Add/Open Handwritten Note (⇧⌘D) / Add Another
    /// Handwritten Note / Attach File… (⇧⌘A) / Paste File, then every
    /// attachment ▸ Open / Move Left / Move Right / Remove.
    static func attachments(_ facts: TopicMenuFacts) -> TopicSubmenu {
        var entries: [TopicMenuEntry] = [
            .button(facts.hasDrawing ? "Open Handwritten Note" : "Add Handwritten Note", "pencil.and.scribble",
                    .openOrAddDrawing, shortcut: .shiftCommandD),
            .button("Add Another Handwritten Note", "plus", .addDrawing, enabled: facts.hasDrawing),
            .button("Attach File…", "paperclip", .attachFile, shortcut: .shiftCommandA),
            .button("Paste File", "doc.on.clipboard", .pasteFile),
        ]
        if !facts.attachments.isEmpty { entries.append(.divider) }
        let count = facts.attachments.count
        for (index, attachment) in facts.attachments.enumerated() {
            var items: [TopicMenuEntry] = [.button("Open", "arrow.up.forward.square", .openAttachment(attachment.id))]
            if count > 1 {
                items.append(.button("Move Left", "arrow.left", .moveAttachment(attachment.id, by: -1),
                                     enabled: index > 0))
                items.append(.button("Move Right", "arrow.right", .moveAttachment(attachment.id, by: 1),
                                     enabled: index < count - 1))
            }
            items += [.divider, .button("Remove", "trash", .removeAttachment(attachment.id), destructive: true)]
            entries.append(.submenu(attachment.title, attachment.systemImage, items))
        }
        return TopicSubmenu(title: "Attachments", systemImage: "paperclip", isEnabled: facts.isSingle,
                            entries: entries)
    }
}

// MARK: Rendering

/// Task ▸ Link ▸ Note ▸ Attachments ▸ next to each other.
struct TopicSubmenusView: View {
    let facts: TopicMenuFacts
    var showsShortcuts = TopicSubmenusView.contextMenuShowsShortcuts
    let perform: (TopicMenuAction) -> Void

    /// macOS context menus show the shortcuts (as the menu bar does); iPad
    /// menus do not (the menu bar / canvas key handler own them).
    static var contextMenuShowsShortcuts: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        ForEach(TopicMenus.all(facts), id: \.title) { submenu in
            Menu {
                TopicMenuEntriesView(entries: submenu.entries, showsShortcuts: showsShortcuts, perform: perform)
            } label: {
                Label(submenu.title, systemImage: submenu.systemImage)
            }
            .disabled(!submenu.isEnabled)
        }
    }
}

/// Items of one submenu (recursive for Priority / Due Date / attachments).
struct TopicMenuEntriesView: View {
    let entries: [TopicMenuEntry]
    var showsShortcuts = false
    let perform: (TopicMenuAction) -> Void

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            row(entry)
        }
    }

    @ViewBuilder private func row(_ entry: TopicMenuEntry) -> some View {
        switch entry.kind {
        case .divider:
            Divider()
        case let .submenu(children):
            Menu {
                TopicMenuEntriesView(entries: children, showsShortcuts: showsShortcuts, perform: perform)
            } label: {
                label(entry)
            }
            .disabled(!entry.isEnabled)
        case let .button(action):
            Button(role: entry.isDestructive ? .destructive : nil) { perform(action) } label: { label(entry) }
                .keyboardShortcut(showsShortcuts ? entry.shortcut?.keyboardShortcut : nil)
                .disabled(!entry.isEnabled)
        }
    }

    @ViewBuilder private func label(_ entry: TopicMenuEntry) -> some View {
        if entry.isChecked {
            Label(entry.title, systemImage: "checkmark")
        } else if let image = entry.systemImage {
            Label(entry.title, systemImage: image)
        } else {
            Text(entry.title)
        }
    }
}
