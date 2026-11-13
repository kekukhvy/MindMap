#if os(macOS)
import AppKit
import ObjectiveC
import SwiftUI

/// The macOS Welcome window (WP13; it replaces WP14b's "Map Library"
/// window): an AppKit window hosting `WelcomeView`, shown at launch, from
/// Window ▸ Welcome (⇧⌘1), File ▸ Open from Library… (⇧⌘O) and Help ▸
/// Welcome Tour. It closes when a map window opens.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private(set) var window: NSWindow?
    var flow: WelcomeFlow = .shared

    var isShown: Bool { window?.isVisible == true }

    func show(tour: Bool = false) {
        if tour { flow.isShowingTour = true }
        let window = window ?? makeWindow()
        self.window = window
        if LaunchEnvironment.isTesting {
            // Never take key focus from the map windows of parallel event tests.
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func close() {
        window?.close()
    }

    /// A map window appeared: the Welcome window steps aside (not while
    /// the tour is running).
    func mapDidOpen() {
        guard isShown, !flow.isShowingTour else { return }
        close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 940, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Welcome to MindMap"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        window.contentMinSize = CGSize(width: 780, height: 540)
        window.delegate = self
        let flow = flow
        let tour = Binding(get: { flow.isShowingTour }, set: { flow.isShowingTour = $0 })
        window.contentView = WelcomeHostingView(rootView: WelcomeView(flow: flow, actions: Self.actions,
                                                                 isShowingTour: tour,
                                                                 systemRecents: Self.systemRecents))
        window.center()
        window.setFrameAutosaveName("MindMapWelcome")
        return window
    }

    static let actions = WelcomeActions(
        newMap: { MapHost.newMap() },
        openFile: { NSDocumentController.shared.openDocument(nil) },
        open: { url in
            let scoped = url.startAccessingSecurityScopedResource()
            MapHost.open(url) { failure in
                if failure != nil, scoped { url.stopAccessingSecurityScopedResource() }
                if let failure {
                    let alert = NSAlert()
                    alert.messageText = "“\(MapPaths.displayName(of: url))” could not be opened."
                    alert.informativeText = failure
                    alert.runModal()
                } else {
                    // Also when the map was open already (no new window appears).
                    WelcomeWindowController.shared.mapDidOpen()
                }
            }
        })

    static func systemRecents() -> [URL] {
        NSDocumentController.shared.recentDocumentURLs
    }
}

/// Clicks on the Welcome window act even when MindMap is in the background
/// (one click opens a recent map, like the Dock).
private final class WelcomeHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Map windows (DocumentGroup content): Recent Files bookkeeping and
/// closing the Welcome window when a map opens.
struct MapWindowHooks: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        content
            .onAppear { WelcomeWindowController.shared.mapDidOpen() }
            .onChange(of: url, initial: true) { _, url in WelcomeFlow.shared.noteOpened(url) }
    }
}

/// Window ▸ Welcome (⇧⌘1) and Help ▸ Welcome Tour.
struct WelcomeCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .windowArrangement) {
            Button("Welcome") { WelcomeWindowController.shared.show() }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Divider()
        }
        CommandGroup(after: .help) {
            Button("Welcome Tour") { WelcomeWindowController.shared.show(tour: true) }
        }
    }
}

/// WP14b risk fixed in WP13: the title bar's "Move To…" / "Where:" and
/// File ▸ Move To… would move a library map's package out of the library
/// cache, which the sync treats as a deletion (gone from iCloud on every
/// device). For library maps Move To… is disabled and a move is refused
/// with an explanation that offers Export as File… instead.
enum LibraryMoveGuard {
    nonisolated(unsafe) private static var installed = false
    /// Tests: called instead of showing the sheet.
    nonisolated(unsafe) static var onRefused: ((NSDocument) -> Void)?

    @MainActor
    static func isLibraryMap(_ document: NSDocument) -> Bool {
        LibraryService.shared.libraryMapID(of: document.fileURL) != nil
    }

    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = NSDocument.self

        // moveToURL:completionHandler: (title bar "Where:" popup, Move To… panel).
        let moveSelector = #selector(NSDocument.move(to:completionHandler:))
        if let method = class_getInstanceMethod(cls, moveSelector) {
            typealias Completion = @convention(block) (NSError?) -> Void
            typealias Original = @convention(c) (NSDocument, Selector, NSURL, Completion?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let block: @convention(block) (NSDocument, NSURL, Completion?) -> Void = { document, url, completion in
                let refused = MainActor.assumeIsolated { isLibraryMap(document) }
                guard refused else { return original(document, moveSelector, url, completion) }
                completion?(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                MainActor.assumeIsolated { refuse(document) }
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        // File ▸ Move To… / title bar menu item.
        let moveDocument = #selector(NSDocument.move(_:))
        if let method = class_getInstanceMethod(cls, moveDocument) {
            typealias Original = @convention(c) (NSDocument, Selector, AnyObject?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let block: @convention(block) (NSDocument, AnyObject?) -> Void = { document, sender in
                let refused = MainActor.assumeIsolated { isLibraryMap(document) }
                guard refused else { return original(document, moveDocument, sender) }
                MainActor.assumeIsolated { refuse(document) }
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        // Disable those menu items for library maps.
        let validate = #selector(NSDocument.validateUserInterfaceItem(_:))
        if let method = class_getInstanceMethod(cls, validate) {
            typealias Original = @convention(c) (NSDocument, Selector, NSValidatedUserInterfaceItem) -> Bool
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let block: @convention(block) (NSDocument, NSValidatedUserInterfaceItem) -> Bool = { document, item in
                if item.action == moveDocument, MainActor.assumeIsolated({ isLibraryMap(document) }) { return false }
                return original(document, validate, item)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    /// Explains why and offers Export as File… (sheet on the map window).
    @MainActor
    static func refuse(_ document: NSDocument) {
        if let onRefused {
            onRefused(document)
            return
        }
        let name = document.displayName ?? "This map"
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "“\(name)” is in your iCloud Sync library"
        alert.informativeText = "Moving it to a folder would take it out of iCloud Sync and delete it on all your "
            + "devices. To get a .mindmap file, export a copy instead — the map stays in the library."
        alert.addButton(withTitle: "Export as File…")
        alert.addButton(withTitle: "Cancel")
        let export = {
            document.fileURL.flatMap(MapStorageController.controller(forDocumentAt:))?.beginExport()
        }
        if let window = document.windowControllers.first?.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { export() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            export()
        }
    }
}
#endif
