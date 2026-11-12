#if os(macOS)
import AppKit
import SwiftUI

/// macOS attachment windows are ordinary document-style windows: titled,
/// closable, miniaturizable, resizable, never tabbed into the map window
/// and never full screen themselves. Over a full-screen map they float in
/// the same space (`.fullScreenAuxiliary`) instead of becoming a tab that
/// fills the screen without window controls. Each kind remembers its last
/// frame (clamped to a visible screen); first time: a default size centered
/// on the map window.
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

    static func frameKey(for kind: AttachmentKind?) -> String {
        "MindMap.attachmentWindowFrame.\(kind?.rawValue ?? "markdown")"
    }

    /// Applies the window rules and the initial frame.
    @MainActor
    static func configure(_ window: NSWindow, kind: AttachmentKind?, defaults: UserDefaults = .standard) {
        applyRules(window)
        window.setFrame(initialFrame(for: window, kind: kind, defaults: defaults), display: true)
    }

    /// Window controls, no tabbing, auxiliary in full-screen spaces. SwiftUI
    /// may reset the collection behavior while setting the window up, so
    /// this is re-applied when the window becomes key.
    @MainActor
    static func applyRules(_ window: NSWindow) {
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        window.tabbingMode = .disallowed
        var behavior = window.collectionBehavior
        behavior.remove([.fullScreenPrimary, .fullScreenNone])
        behavior.insert([.fullScreenAuxiliary, .managed])
        if behavior != window.collectionBehavior { window.collectionBehavior = behavior }
        if window.contentMinSize != minSize { window.contentMinSize = minSize }
    }

    /// Saved frame of this kind if it is still on a screen, else the default
    /// size centered on the key (map) window / main screen.
    @MainActor
    static func initialFrame(for window: NSWindow, kind: AttachmentKind?, defaults: UserDefaults) -> CGRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        if let string = defaults.string(forKey: frameKey(for: kind)) {
            let saved = NSRectFromString(string)
            if let visible = screens.first(where: { $0.intersects(saved) }), saved.width >= minSize.width {
                return clamp(saved, to: visible)
            }
        }
        let content = defaultSize(for: kind)
        let size = window.frameRect(forContentRect: CGRect(origin: .zero, size: content)).size
        let anchor = NSApp.windows.first { $0 !== window && $0.isVisible && $0.isMainWindow }?.frame
            ?? window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let visible = screens.first { $0.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }
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

/// Hooks `AttachmentWindowChrome` into the hosting window.
struct AttachmentWindowConfigurator: NSViewRepresentable {
    let kind: AttachmentKind?

    func makeNSView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.kind = kind
        return view
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.kind = kind
    }

    final class ConfiguratorView: NSView {
        var kind: AttachmentKind?
        private weak var configured: NSWindow?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== configured else { return }
            configured = window
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            // After SwiftUI has applied its own size / restoration.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                AttachmentWindowChrome.configure(window, kind: self.kind)
                let names: [Notification.Name] = [NSWindow.didEndLiveResizeNotification,
                                                  NSWindow.didMoveNotification, NSWindow.willCloseNotification]
                self.observers = names.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self, weak window] _ in
                        MainActor.assumeIsolated {
                            guard let self, let window else { return }
                            AttachmentWindowChrome.save(window, kind: self.kind)
                        }
                    }
                }
                self.observers.append(NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak window] _ in
                    MainActor.assumeIsolated {
                        if let window { AttachmentWindowChrome.applyRules(window) }
                    }
                })
                // SwiftUI finishes the window setup asynchronously.
                for delay in [0.2, 0.6] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                        if let window { AttachmentWindowChrome.applyRules(window) }
                    }
                }
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
#endif
