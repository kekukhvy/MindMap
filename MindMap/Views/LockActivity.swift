import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Auto-lock settings (WP12).
enum LockSettings {
    static let autoLockKey = "MindMap.autoLockMinutes"
    static let defaultMinutes = 5
    /// Menu choices (0 = never by idle time; background / sleep still lock).
    static let choices = [1, 2, 5, 10, 15, 30, 60, 0]
    static let noteInfoKey = "MindMap.didShowNoteLockInfo"

    static func title(minutes: Int) -> String {
        switch minutes {
        case 0: return "Never"
        case 60: return "After 1 Hour"
        case 1: return "After 1 Minute"
        default: return "After \(minutes) Minutes"
        }
    }
}

/// Last user input anywhere in the app (idle auto-lock). macOS: local
/// event monitor; iPad: a passive touch observer on each map window.
@MainActor
final class LockActivity {
    static let shared = LockActivity()

    private(set) var lastActivity = Date()
    #if os(macOS)
    private var monitor: Any?
    #endif

    private init() {}

    func touch(_ date: Date = Date()) {
        if date > lastActivity { lastActivity = date }
    }

    /// Starts observing input (idempotent).
    func start() {
        #if os(macOS)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify, .mouseMoved,
            .leftMouseDragged,
        ]) { event in
            MainActor.assumeIsolated { LockActivity.shared.touch() }
            return event
        }
        #endif
    }
}

#if os(iOS)
/// Installs a recognizer on the window that never recognizes and never
/// delays touches; it only records that the user touched the screen.
struct TouchActivityObserver: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, !(window.gestureRecognizers ?? []).contains(where: { $0 is ActivityRecognizer }) else {
                return
            }
            window.addGestureRecognizer(ActivityRecognizer())
        }
    }

    final class ActivityRecognizer: UIGestureRecognizer {
        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            LockActivity.shared.touch()
            state = .failed
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            LockActivity.shared.touch()
            super.pressesBegan(presses, with: event)
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
#endif
