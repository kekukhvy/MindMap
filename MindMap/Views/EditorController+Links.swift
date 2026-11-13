import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Request to show the link editor for a topic.
struct LinkEditorRequest: Identifiable, Equatable {
    let id = UUID()
    var nodeID: UUID
    /// Pane to open (nil: the link's kind).
    var mode: LinkEditorSheet.Mode?
}

/// Topic links: edit (one undo step each), Go to, Back, copy.
extension EditorController {
    func link(of id: UUID) -> TopicLink? {
        model.map.link(of: id)
    }

    /// ⌘K / "Add Link…" / "Edit Link…": shows the link editor.
    func beginEditLink(_ id: UUID? = nil, mode: LinkEditorSheet.Mode? = nil) {
        commitEditing()
        cancelPick()
        guard let target = id ?? selectedID, model.map.node(withID: target) != nil else { return }
        select(target)
        linkEditor = LinkEditorRequest(nodeID: target, mode: mode)
    }

    @discardableResult
    func setLink(_ link: TopicLink?, for id: UUID) -> Bool {
        commitEditing()
        return model.setLink(link, for: id, undoManager: undoManager)
    }

    func removeLink(_ id: UUID? = nil) {
        guard let target = id ?? selectedID else { return }
        setLink(nil, for: target)
    }

    /// "Pick on canvas": the next topic clicked becomes the link target.
    func beginLinkPick(for id: UUID) {
        guard scene.nodes[id] != nil else { return }
        linkEditor = nil
        beginPick(.link(from: id))
    }

    /// Web: the URL; topic link: the target's path (text).
    func copyLink(_ id: UUID? = nil) {
        guard let target = id ?? selectedID, let resolved = model.map.resolvedLink(of: target) else { return }
        let text: String
        switch resolved {
        case let .web(url): text = url.absoluteString
        case let .topic(topic): text = model.map.breadcrumb(to: topic) ?? ""
        case let .map(reference): text = resolvedMapURL(of: target)?.path ?? reference.pathDescription
        case .brokenTopic: return
        }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Go to: opens a web link in the browser, jumps to the linked topic
    /// (expanding collapsed ancestors, remembering `id` for Back) or opens
    /// the linked map (`openMapLink`). A broken topic link shows "Target
    /// topic was deleted".
    func goToLink(of id: UUID? = nil) {
        guard let source = id ?? selectedID, let resolved = model.map.resolvedLink(of: source) else { return }
        commitEditing()
        cancelPick()
        switch resolved {
        case let .web(url):
            select(source)
            openURL(url)
        case let .topic(target):
            navigationHistory.push(source)
            show(target)
        case .map:
            openMapLink(of: source)
        case .brokenTopic:
            select(source)
            linkMessage = LinkSummary.brokenMessage
        }
    }

    /// Topic Back (⌘[ / Back pill) would return to (deleted ones skipped).
    var backTargetID: UUID? {
        navigationHistory.peek { model.map.contains($0) }
    }

    /// Back (⌘[): returns to the topic the last topic-link jump started from.
    func goBack() {
        commitEditing()
        cancelPick()
        guard let target = navigationHistory.pop(where: { model.map.contains($0) }) else { return }
        show(target)
    }

    /// Expands `id`'s collapsed ancestors (one undo step), selects it and
    /// scrolls / zooms it into view with animation.
    func show(_ id: UUID) {
        guard model.map.contains(id) else { return }
        // The collapsed ancestor that opens stays put; then scroll if needed.
        keepingOnScreen(id) { _ = model.revealTopic(id, undoManager: undoManager) }
        select(id)
        guard let frame = scene.layout.frames[id] else { return }
        let target = viewport.focusing(frame, in: viewSize)
        guard target != viewport else { return }
        withAnimation(.easeInOut(duration: 0.35)) { viewport = target }
    }

    /// Default `openURL`: the system's default browser / handler app.
    static func openInBrowser(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
