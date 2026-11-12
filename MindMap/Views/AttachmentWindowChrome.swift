#if os(macOS)
import AppKit
import SwiftUI

/// macOS attachment windows (note, handwritten note, file) are ordinary
/// floating windows owned by AppKit, not SwiftUI scenes: titled, closable,
/// miniaturizable, resizable, never tabbed and never full screen themselves.
/// Each one is a CHILD window of its map's window, so it always stays above
/// that map and lives in the map's space — also when the map is in full
/// screen (`.fullScreenAuxiliary`: it floats over the full-screen map instead
/// of becoming its own black full-screen space). Each kind remembers its
/// last frame (clamped to a visible screen); first time: a default size
/// centered on the map window.
enum AttachmentWindowChrome {
    /// Default content size and minimum size per kind.
    static func defaultSize(for kind: AttachmentKind?) -> CGSize {
        switch kind {
        case .drawing: return CGSize(width: 900, height: 760)
        case .file: return CGSize(width: 760, height: 800)
        case .markdown, nil: return CGSize(width: 640, height: 720)
        }
    }

    static let minSize = CGSize(width: 420, height: 360)

    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    /// Floats with its map: same space, auxiliary over a full-screen map,
    /// moves to the active space, never a full-screen / tiled window itself.
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .fullScreenAuxiliary, .moveToActiveSpace, .fullScreenDisallowsTiling, .managed,
    ]

    static func frameKey(for kind: AttachmentKind?) -> String {
        "MindMap.attachmentWindowFrame.\(kind?.rawValue ?? "markdown")"
    }

    /// Window controls, no tabbing, auxiliary in full-screen spaces.
    @MainActor
    static func applyRules(_ window: NSWindow) {
        window.styleMask.formUnion(styleMask)
        window.tabbingMode = .disallowed
        if window.collectionBehavior != collectionBehavior { window.collectionBehavior = collectionBehavior }
        if window.contentMinSize != minSize { window.contentMinSize = minSize }
    }

    /// Saved frame of this kind if it is still on a screen, else the default
    /// size centered on `anchor` (the map window) / the main screen.
    @MainActor
    static func initialFrame(for window: NSWindow, kind: AttachmentKind?, anchor anchorWindow: NSWindow?,
                             defaults: UserDefaults = .standard) -> CGRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        if let string = defaults.string(forKey: frameKey(for: kind)) {
            let saved = NSRectFromString(string)
            if let visible = screens.first(where: { $0.intersects(saved) }), saved.width >= minSize.width {
                return clamp(saved, to: visible)
            }
        }
        let content = defaultSize(for: kind)
        let size = window.frameRect(forContentRect: CGRect(origin: .zero, size: content)).size
        let anchor = anchorWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let visible = anchorWindow?.screen?.visibleFrame
            ?? screens.first { $0.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main?.visibleFrame ?? anchor
        let frame = CGRect(x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2,
                           width: size.width, height: size.height)
        return clamp(frame, to: visible)
    }

    /// Fits `frame` inside `visible` (smaller than the screen: never "zoomed").
    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        guard visible.width > 0, visible.height > 0 else { return frame }
        var result = frame
        result.size.width = min(frame.width, visible.width * 0.9)
        result.size.height = min(frame.height, visible.height * 0.95)
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }

    static func save(_ window: NSWindow, kind: AttachmentKind?, defaults: UserDefaults = .standard) {
        guard !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: frameKey(for: kind))
    }
}

/// The NSWindow of one attachment. Esc closes it (when nothing inside
/// handles it); undo / redo go to the map document's undo manager.
final class AttachmentPanel: NSWindow {
    let windowID: AttachmentWindowID
    let kind: AttachmentKind?
    /// Closed because its map closed: no empty-note cleanup on that document.
    var isClosingWithMap = false

    init(windowID: AttachmentWindowID, kind: AttachmentKind?) {
        self.windowID = windowID
        self.kind = kind
        let size = AttachmentWindowChrome.defaultSize(for: kind)
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: AttachmentWindowChrome.styleMask,
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isRestorable = false
        toolbarStyle = .unified
        AttachmentWindowChrome.applyRules(self)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// Opens, finds and closes attachment windows (one per document +
/// attachment). Closing a window (Done, Esc, close button, ⌘W) removes a
/// note / handwritten note that was left empty (`discardIfEmpty`); closing
/// the map closes its attachment windows without touching the document.
@MainActor
final class AttachmentWindows: NSObject, NSWindowDelegate {
    static let shared = AttachmentWindows()

    private var windows: [AttachmentWindowID: AttachmentPanel] = [:]
    private var observers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let closing, !(closing is AttachmentPanel) else { return }
                self.closeChildren(of: closing)
            }
        })
    }

    /// The open window of an attachment (tests, re-opening).
    func window(for id: AttachmentWindowID) -> AttachmentPanel? {
        windows[id]
    }

    var openWindows: [AttachmentPanel] { Array(windows.values) }

    /// Shows the attachment's window above `mapWindow` (creating it if needed).
    @discardableResult
    func open(_ id: AttachmentWindowID, kind: AttachmentKind?, over mapWindow: NSWindow?) -> AttachmentPanel {
        if let existing = windows[id] {
            attach(existing, to: mapWindow)
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        let window = AttachmentPanel(windowID: id, kind: kind)
        let content = AttachmentWindowContent(windowID: id,
                                              close: { [weak window] in window?.performClose(nil) },
                                              setTitle: { [weak window] in
                                                  if window?.title != $0 { window?.title = $0 }
                                              })
        let host = NSHostingController(rootView: content)
        host.sceneBridgingOptions = [.toolbars]
        // Only the minimum size constrains the window (no ideal-size lock).
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.title = kind?.displayName ?? "Note"
        window.delegate = self
        AttachmentWindowChrome.applyRules(window)
        window.setFrame(AttachmentWindowChrome.initialFrame(for: window, kind: kind, anchor: mapWindow),
                        display: false)
        windows[id] = window
        attach(window, to: mapWindow)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Child of the map window: stays above it, in its (full-screen) space.
    private func attach(_ window: NSWindow, to mapWindow: NSWindow?) {
        guard let mapWindow, mapWindow !== window, window.parent !== mapWindow else { return }
        window.parent?.removeChildWindow(window)
        mapWindow.addChildWindow(window, ordered: .above)
    }

    /// Closes the attachment windows of a map window that is closing.
    private func closeChildren(of mapWindow: NSWindow) {
        for window in windows.values where window.parent === mapWindow {
            window.isClosingWithMap = true
            window.close()
        }
    }

    /// Closes every window of `documentID` (its map was closed).
    func closeWindows(of documentID: UUID) {
        for window in windows.values where window.windowID.documentID == documentID {
            window.isClosingWithMap = true
            window.close()
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? AttachmentPanel else { return }
        AttachmentWindowChrome.save(window, kind: window.kind)
        windows[window.windowID] = nil
        // AppKit detaches a closing child window from its parent itself.
        let id = window.windowID
        let closingWithMap = window.isClosingWithMap
        DispatchQueue.main.async { [weak window] in
            // Tear the editor down (views dismantled, pending strokes / title
            // flushed), then clean up an empty note.
            window?.contentViewController = nil
            guard !closingWithMap, let entry = OpenDocumentRegistry.shared.entry(for: id.documentID),
                  let model = entry.model else { return }
            model.discardIfEmpty(id.attachmentID, undoManager: entry.undoManager)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? AttachmentPanel else { return }
        AttachmentWindowChrome.save(window, kind: window.kind)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? AttachmentPanel else { return }
        AttachmentWindowChrome.save(window, kind: window.kind)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let window = window as? AttachmentPanel else { return nil }
        return OpenDocumentRegistry.shared.entry(for: window.windowID.documentID)?.undoManager
    }
}
#endif
