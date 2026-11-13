#if os(macOS)
import AppKit
import SwiftUI

/// macOS scroll wheel / two-finger trackpad scroll over the canvas:
/// scroll pans; Cmd or Option + scroll zooms around the cursor. Also
/// reports right / Ctrl clicks (before the context menu opens) so the item
/// under the cursor can be selected first.
struct ScrollWheelHandler: NSViewRepresentable {
    /// (delta in points, location in view coordinates, zoom requested)
    var onScroll: (CGSize, CGPoint, Bool) -> Void
    /// Location in view coordinates of a secondary click.
    var onSecondaryClick: (CGPoint) -> Void = { _ in }
    /// Plain scrolls at this location go to the view under the pointer
    /// instead (the Tasks panel's scrolling list).
    var passesScroll: (CGPoint) -> Bool = { _ in false }
    /// Modifier keys of the latest left-mouse event in the window (Option-drag).
    @MainActor static var lastMouseModifiers: NSEvent.ModifierFlags = []

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.onSecondaryClick = onSecondaryClick
        view.passesScroll = passesScroll
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onSecondaryClick = onSecondaryClick
        nsView.passesScroll = passesScroll
    }

    static func dismantleNSView(_ nsView: CatcherView, coordinator: ()) {
        nsView.removeMonitor()
    }

    final class CatcherView: NSView {
        var onScroll: ((CGSize, CGPoint, Bool) -> Void)?
        var onSecondaryClick: ((CGPoint) -> Void)?
        var passesScroll: ((CGPoint) -> Bool)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .rightMouseDown, .leftMouseDown, .leftMouseDragged]) {
                [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if event.type == .leftMouseDown || event.type == .leftMouseDragged {
                    ScrollWheelHandler.lastMouseModifiers = event.modifierFlags
                }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }
                switch event.type {
                case .scrollWheel:
                    let zoomKeys = !event.modifierFlags.intersection([.command, .option]).isEmpty
                    if !zoomKeys, self.passesScroll?(location) == true { return event }
                    let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                    let delta = CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor)
                    let zoom = !event.modifierFlags.intersection([.command, .option]).isEmpty
                    self.onScroll?(delta, location, zoom)
                    return nil
                case .rightMouseDown:
                    self.onSecondaryClick?(location)
                case .leftMouseDown where event.modifierFlags.contains(.control):
                    self.onSecondaryClick?(location)
                default:
                    break
                }
                return event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
