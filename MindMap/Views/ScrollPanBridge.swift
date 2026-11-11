#if os(iOS)
import SwiftUI
import UIKit

/// iPad trackpad / mouse two-finger scroll pans the canvas. Installs a pan
/// recognizer that accepts only scroll events (no touches) on the window
/// and forwards deltas that start inside this view's bounds.
struct ScrollPanBridge: UIViewRepresentable {
    /// (dx, dy) in points, in the direction the content should move.
    var onPan: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.onPan = onPan
        return view
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        uiView.onPan = onPan
    }

    static func dismantleUIView(_ uiView: BridgeView, coordinator: ()) {
        uiView.uninstall()
    }

    final class BridgeView: UIView {
        var onPan: ((CGFloat, CGFloat) -> Void)?
        private var recognizer: UIPanGestureRecognizer?
        private lazy var gate = Gate(view: self)

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            uninstall()
            guard let window else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.allowedScrollTypesMask = .all
            pan.allowedTouchTypes = []
            pan.cancelsTouchesInView = false
            pan.delegate = gate
            window.addGestureRecognizer(pan)
            recognizer = pan
        }

        func uninstall() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
        }


        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .began || pan.state == .changed else { return }
            let translation = pan.translation(in: self)
            pan.setTranslation(.zero, in: self)
            onPan?(translation.x, translation.y)
        }
    }

    /// Recognizer delegate: begin only over the canvas, never block others.
    final class Gate: NSObject, UIGestureRecognizerDelegate {
        weak var view: UIView?

        init(view: UIView) {
            self.view = view
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let view, view.window != nil else { return false }
            return view.bounds.contains(gestureRecognizer.location(in: view))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
