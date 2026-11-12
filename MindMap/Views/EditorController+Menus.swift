import Foundation

/// Facts and actions of the Task / Link / Note / Attachments submenus
/// (`TopicMenus`), shared by the context menu and the Topic menu bar.
extension EditorController {
    /// Facts for a menu opened on `id` (the whole selection when `id` is
    /// part of a multi-selection).
    func menuFacts(for id: UUID) -> TopicMenuFacts {
        let map = model.map
        let nodes = targets(for: id).compactMap(map.node(withID:))
        guard let reference = map.node(withID: id), !nodes.isEmpty else { return TopicMenuFacts() }
        let tasks = nodes.compactMap(\.task)
        var facts = TopicMenuFacts(count: nodes.count)
        facts.isTask = reference.task != nil
        facts.isDoneTask = reference.task?.isDone == true
        facts.anyTask = !tasks.isEmpty
        facts.anyNonTask = tasks.count < nodes.count
        let priorities = Set(tasks.map(\.priority))
        facts.commonPriority = priorities.count == 1 ? priorities.first ?? nil : nil
        facts.allTasksWithoutPriority = !tasks.isEmpty && priorities == [nil]
        facts.anyDueDate = tasks.contains { $0.dueDate != nil }
        guard nodes.count == 1 else { return facts }
        if let resolved = map.resolvedLink(of: id) {
            facts.link = .init(goToTitle: Self.goToTitle(resolved, in: map),
                               goToSystemImage: Self.goToSystemImage(resolved),
                               canCopy: !resolved.isBroken, isMapLink: reference.link?.mapReference != nil)
        }
        facts.hasNote = firstNote(of: id) != nil
        facts.hasDrawing = firstDrawing(of: id) != nil
        facts.attachments = attachments(of: id).map {
            .init(id: $0.id, title: $0.title.isEmpty ? $0.kind.displayName : $0.title, systemImage: $0.kind.systemImage)
        }
        return facts
    }

    /// Runs a submenu item on `id` (default: the primary selection).
    func performMenuAction(_ action: TopicMenuAction, on id: UUID? = nil) {
        guard let id = id ?? selectedID, model.map.node(withID: id) != nil else { return }
        switch action {
        case .convertToTask: convertToTask(id)
        case .toggleDone: toggleTargetsDone(id)
        case let .setPriority(priority): setTaskPriority(priority, for: id)
        case let .setDue(pick): setTaskDue(pick, for: id)
        case .chooseDueDate: beginDueDatePicker(id)
        case .clearDueDate: setTaskDueDate(nil, for: id)
        case .convertToTopic: convertToTopic(id)
        case .editLink: beginEditLink(id)
        case .goToLink: goToLink(of: id)
        case .copyLink: copyLink(id)
        case .locateMap: beginLocateMap(id)
        case .removeLink: removeLink(id)
        case .openOrAddNote: openOrAddNote(id)
        case .addNote: addNote(to: id)
        case .deleteNote:
            if let note = firstNote(of: id) { removeAttachment(note.id) }
        case .openOrAddDrawing: openOrAddDrawing(id)
        case .addDrawing: addDrawing(to: id)
        case .attachFile: beginAttachFile(to: id)
        case .pasteFile:
            select(id)
            pasteFiles(to: id)
        case let .openAttachment(attachmentID):
            select(id)
            openAttachment(attachmentID)
        case let .moveAttachment(attachmentID, offset): moveAttachment(attachmentID, by: offset)
        case let .removeAttachment(attachmentID): removeAttachment(attachmentID)
        }
    }

    /// "Go to “Target”" / "Open “Map”" (40 characters at most).
    static func goToTitle(_ resolved: ResolvedLink, in map: MindMap) -> String {
        switch resolved {
        case let .web(url): return "Go to “\(short(LinkURL.displayString(url)))”"
        case let .topic(target):
            return "Go to “\(short(LinkCandidate.displayText(map.node(withID: target)?.text ?? "")))”"
        case .brokenTopic: return "Go to (Deleted Topic)"
        case let .map(reference): return "Open “\(short(reference.displayName))”"
        }
    }

    static func goToSystemImage(_ resolved: ResolvedLink) -> String {
        switch resolved {
        case .web: return "safari"
        case .map: return "macwindow.badge.plus"
        case .topic, .brokenTopic: return "arrow.right.circle"
        }
    }

    private static func short(_ text: String) -> String {
        text.count > 40 ? String(text.prefix(39)) + "…" : text
    }
}
