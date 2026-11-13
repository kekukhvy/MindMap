#if os(iOS)
import SwiftUI
import UIKit

/// Reports the hardware-keyboard modifiers (⌘ / ⇧) held when a touch or
/// pointer click starts anywhere in the canvas window, before SwiftUI's tap
/// gesture ends (SwiftUI's `onModifierKeysChanged` is macOS-only). A
/// passive recognizer on the window: it never recognizes, never delays or
/// cancels touches.
struct ModifierTouchBridge: UIViewRepresentable {
    var onModifiers: (EventModifiers) -> Void

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.isUserInteractionEnabled = false
        view.probe.onModifiers = onModifiers
        return view
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        uiView.probe.onModifiers = onModifiers
    }

    static func modifiers(_ flags: UIKeyModifierFlags) -> EventModifiers {
        var result: EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    final class BridgeView: UIView {
        let probe = ModifierProbe()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            probe.view?.removeGestureRecognizer(probe)
            window?.addGestureRecognizer(probe)
        }
    }

    final class ModifierProbe: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var onModifiers: ((EventModifiers) -> Void)?

        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onModifiers?(ModifierTouchBridge.modifiers(event.modifierFlags))
            state = .failed
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif
