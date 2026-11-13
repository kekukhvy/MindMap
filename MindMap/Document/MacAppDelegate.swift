#if os(macOS)
import AppKit
import ObjectiveC

/// macOS launch: no open panel. Window restoration / autosaved untitled
/// documents may reopen windows on their own; AppKit asks the app delegate
/// `applicationShouldOpenUntitledFile` only when nothing was restored or
/// opened, and then (WP13) the Welcome window appears — with the Welcome
/// Tour on the very first launch — or, with "Show Welcome on launch" off,
/// the most recent document is reopened (falling back to the next recent
/// one, then a new map). A Dock click with no windows shows Welcome too
/// (when it is on).
///
/// SwiftUI's own app delegate answers that question itself and does not
/// forward it to the adaptor delegate, so the answer is intercepted on
/// SwiftUI's delegate class (public NSApplicationDelegate selector).
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private static var handledLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Untitled document instead of the "app-centric" open panel (shown
        // at launch and on Dock reopen when iCloud Drive is enabled).
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        Self.interceptUntitledDecision()
        LibraryMoveGuard.install()
        #if DEBUG
        LaunchReport.scheduleIfRequested()
        #endif
    }

    /// The very first launch shows the Welcome Tour even when window
    /// restoration reopened maps (then AppKit never asks for an untitled
    /// document), e.g. the first launch after an update.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !LaunchEnvironment.isTesting else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let flow = WelcomeFlow.shared
            guard flow.launchAction() == .tour, !WelcomeWindowController.shared.isShown else { return }
            #if DEBUG
            LaunchReport.note("first launch with restored windows: tour")
            #endif
            WelcomeWindowController.shared.show(tour: true)
        }
    }

    /// Used if a future SwiftUI forwards the call to the adaptor delegate.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !MainActor.assumeIsolated { Self.reopenRecentAtLaunch() }
    }

    /// Untitled request (launch with nothing restored, or Dock click with
    /// no windows): true if it was answered here (Welcome window / reopened
    /// recent; the caller must then not open an untitled document). Test
    /// runs keep the standard new map.
    @MainActor
    static func reopenRecentAtLaunch() -> Bool {
        guard !LaunchEnvironment.isTesting else { return false }
        guard !handledLaunch else {
            // Dock click with no windows.
            guard WelcomeFlow.shared.showsWelcomeOnLaunch else { return false }
            WelcomeWindowController.shared.show()
            return true
        }
        handledLaunch = true
        let action = WelcomeFlow.shared.launchAction()
        #if DEBUG
        LaunchReport.note("untitled request at launch: \(action)")
        #endif
        switch action {
        case .tour:
            DispatchQueue.main.async { WelcomeWindowController.shared.show(tour: true) }
            return true
        case .welcome:
            DispatchQueue.main.async { WelcomeWindowController.shared.show() }
            return true
        case .reopenLast:
            break
        }
        let controller = NSDocumentController.shared
        let candidates = LaunchEnvironment.reopenCandidates(
            recents: controller.recentDocumentURLs,
            alreadyOpen: controller.documents.compactMap(\.fileURL))
        #if DEBUG
        LaunchReport.note("reopen candidates=\(candidates.map(\.lastPathComponent))")
        #endif
        guard !candidates.isEmpty else { return false }
        reopen(candidates[...])
        return true
    }

    private static func reopen(_ urls: ArraySlice<URL>) {
        let controller = NSDocumentController.shared
        guard let url = urls.first else {
            controller.newDocument(nil)
            return
        }
        controller.openDocument(withContentsOf: url, display: true) { document, _, error in
            #if DEBUG
            LaunchReport.note("reopen \(url.lastPathComponent): "
                + (document == nil ? "failed (\(error?.localizedDescription ?? "?"))" : "ok"))
            #endif
            if document == nil { reopen(urls.dropFirst()) }
        }
    }

    /// Wraps SwiftUI's `applicationShouldOpenUntitledFile:` so the launch
    /// request reopens the last document first.
    private static func interceptUntitledDecision() {
        guard let delegate = NSApp.delegate, !(delegate is MacAppDelegate) else { return }
        let cls: AnyClass = type(of: delegate)
        let selector = #selector(NSApplicationDelegate.applicationShouldOpenUntitledFile(_:))
        guard let method = class_getInstanceMethod(cls, selector),
              class_getInstanceMethod(class_getSuperclass(cls), selector) != method else { return }
        typealias Original = @convention(c) (AnyObject, Selector, NSApplication) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject, NSApplication) -> Bool = { object, app in
            MainActor.assumeIsolated { reopenRecentAtLaunch() } ? false : original(object, selector, app)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}

#if DEBUG
/// Debug-only launch diagnostics (no screen-recording / accessibility
/// permission needed). Environment:
/// - `MINDMAP_LAUNCH_REPORT=1`: 6 s after launch writes notes, windows and
///   documents to `<container>/tmp/launch-report.txt`.
/// - `MINDMAP_DEBUG_RECENT=<path>`: adds that file to the recent documents.
/// - `MINDMAP_SIMULATE_LAUNCH_OPEN=1`: if AppKit's launch "open app" event
///   never arrives (app started from a non-GUI shell is not activated),
///   asks the app delegate exactly like AppKit does for that event.
enum LaunchReport {
    nonisolated(unsafe) private static var notes: [String] = []

    static func note(_ text: String) { notes.append(text) }

    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let path = env["MINDMAP_DEBUG_RECENT"] {
            NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
        }
        if env["MINDMAP_SIMULATE_LAUNCH_OPEN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard NSDocumentController.shared.documents.isEmpty, let delegate = NSApp.delegate else {
                    note("simulate: skipped (documents already open)")
                    return
                }
                let shouldOpen = delegate.applicationShouldOpenUntitledFile?(NSApp) ?? true
                note("simulate: shouldOpenUntitled=\(shouldOpen)")
                if shouldOpen { _ = delegate.applicationOpenUntitledFile?(NSApp) }
            }
        }
        guard env["MINDMAP_LAUNCH_REPORT"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            var lines = notes
            lines.append("recents=\(NSDocumentController.shared.recentDocumentURLs.map(\.lastPathComponent))")
            for window in NSApp.windows where window.isVisible {
                lines.append("window \(type(of: window)) title=\"\(window.title)\" panel=\(window is NSPanel)")
            }
            lines.append("welcome=\(WelcomeWindowController.shared.isShown) tour=\(WelcomeFlow.shared.isShowingTour)")
            for document in NSDocumentController.shared.documents {
                lines.append("document \(document.displayName ?? "?") url=\(document.fileURL?.path ?? "nil")")
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("launch-report.txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
#endif
#endif
