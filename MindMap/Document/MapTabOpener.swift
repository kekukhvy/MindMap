#if os(macOS)
import AppKit
import SwiftUI

/// macOS: a linked map opens as a new native tab of the window it was
/// followed from. Already open (in any window or tab) → that window/tab is
/// brought to the front instead. Map windows keep the standard tabbing
/// (`.automatic`, so File › New follows the system "prefer tabs" setting);
/// only attachment windows disallow tabbing (`AttachmentWindowChrome`).
@MainActor
enum MapTabOpener {
    enum Outcome: Equatable {
        case openedInNewTab
        case focusedExisting
        case failed(String)
    }

    /// Opens `url` and, if `topicID` is set, asks its editor to reveal it.
    static func open(_ url: URL, revealing topicID: UUID?, from hostWindow: NSWindow?,
                     completion: @escaping (Outcome) -> Void = { _ in }) {
        let controller = NSDocumentController.shared
        if let topicID { MapRevealCenter.shared.request(topicID, in: url) }
        if let existing = document(for: url) {
            existing.showWindows()
            if let window = existing.windowControllers.first?.window {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
            completion(.focusedExisting)
            return
        }
        MapFileAccess.retain(url)
        controller.openDocument(withContentsOf: url, display: false) { document, _, error in
            guard let document else {
                completion(.failed(error?.localizedDescription ?? "The map could not be opened."))
                return
            }
            if document.windowControllers.isEmpty { document.makeWindowControllers() }
            if let window = document.windowControllers.first?.window, let hostWindow, window !== hostWindow,
               !(hostWindow.tabbedWindows ?? []).contains(window) {
                if hostWindow.tabbingMode == .disallowed { hostWindow.tabbingMode = .automatic }
                if window.tabbingMode == .disallowed { window.tabbingMode = .automatic }
                hostWindow.addTabbedWindow(window, ordered: .above)
            }
            document.showWindows()
            document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
            completion(.openedInNewTab)
        }
    }

    /// The open document of `url` (compared after resolving symlinks).
    static func document(for url: URL) -> NSDocument? {
        let key = LaunchEnvironment.key(url)
        return NSDocumentController.shared.documents.first { $0.fileURL.map(LaunchEnvironment.key) == key }
    }
}

/// Reports the NSWindow hosting the editor (the tab group new map tabs
/// join).
struct HostWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
