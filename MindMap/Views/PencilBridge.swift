#if os(iOS)
import SwiftUI
import UIKit

/// Apple Pencil on the map canvas (WP11), installed on the canvas window:
/// - `UIPencilInteraction`: barrel double-tap / Pencil Pro squeeze →
///   `EditorController.pencilDoubleTap` / `pencilSqueeze` (decisions in
///   `PencilPolicy`, honoring the user's Pencil settings);
/// - `UIHoverGestureRecognizer` (Pencil hover, iPad Pro M2+/M4): hovered
///   topic highlight + "+" handle, squeeze location;
/// - `UIIndirectScribbleInteraction`: handwriting over a topic starts
///   renaming it and Scribble writes into its inline editor.
/// Everything is off while a sheet / full-screen cover is up (the drawing
/// note's PencilKit canvas handles the Pencil there).
struct PencilBridge: UIViewRepresentable {
    let editor: EditorController
    /// No attachment sheet / cover is up. A plain input (read in the caller's
    /// body): SwiftUI does not re-run `updateUIView` for observable state read
    /// only inside it, so the interaction stayed on above the drawing note and
    /// competed with PencilKit's tool picker for double-tap / squeeze.
    let isMapFrontmost: Bool

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.editor = editor
        view.isMapFrontmost = isMapFrontmost
        return view
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        uiView.editor = editor
        uiView.isMapFrontmost = isMapFrontmost
        uiView.updateEnabled()
    }

    static func dismantleUIView(_ uiView: BridgeView, coordinator: ()) {
        uiView.uninstall()
    }

    final class BridgeView: UIView, UIPencilInteractionDelegate, UIIndirectScribbleInteractionDelegate,
        UIGestureRecognizerDelegate {
        typealias ElementIdentifier = UUID

        weak var editor: EditorController?
        var isMapFrontmost = true
        private var pencil: UIPencilInteraction?
        private var scribble: UIIndirectScribbleInteraction<BridgeView>?
        private var hover: UIHoverGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            uninstall()
            guard let window else { return }
            // On the window: this background view takes no touches itself.
            let pencil = UIPencilInteraction()
            pencil.delegate = self
            window.addInteraction(pencil)
            self.pencil = pencil
            let scribble = UIIndirectScribbleInteraction(delegate: self)
            window.addInteraction(scribble)
            self.scribble = scribble
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            hover.cancelsTouchesInView = false
            hover.delegate = self
            window.addGestureRecognizer(hover)
            self.hover = hover
            updateEnabled()
        }

        func uninstall() {
            if let pencil { pencil.view?.removeInteraction(pencil) }
            if let scribble { scribble.view?.removeInteraction(scribble) }
            if let hover { hover.view?.removeGestureRecognizer(hover) }
            pencil = nil
            scribble = nil
            hover = nil
        }

        func updateEnabled() {
            pencil?.isEnabled = isMapFrontmost
        }

        /// The map is what the user sees (no sheet / cover / alert above it).
        private var isFrontmost: Bool {
            guard let window, let editor, editor.presentedAttachment == nil, !isHidden else { return false }
            return window.rootViewController?.presentedViewController == nil
        }

        // MARK: Hover

        @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
            guard let editor else { return }
            let point = recognizer.location(in: self)
            // zOffset > 0 only for a hovering Pencil (0 for trackpad pointers).
            let isPencil = recognizer.zOffset > 0
            switch recognizer.state {
            case .began, .changed:
                editor.pencilHover(at: isPencil && isFrontmost && bounds.contains(point) ? point : nil)
            default:
                editor.pencilHover(at: nil)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: Double-tap / squeeze

        static func preference(_ action: UIPencilPreferredAction) -> PencilPreference {
            if #available(iOS 17.5, *) {
                if action == .showContextualPalette { return .showContextualPalette }
                if action == .runSystemShortcut { return .runSystemShortcut }
            }
            switch action {
            case .ignore: return .ignore
            case .switchEraser: return .switchEraser
            case .switchPrevious: return .switchPrevious
            case .showColorPalette: return .showColorPalette
            case .showInkAttributes: return .showInkAttributes
            default: return .other
            }
        }

        private static var tapPreference: PencilPreference {
            preference(UIPencilInteraction.preferredTapAction)
        }

        @available(iOS, deprecated: 17.5, message: "iOS 17.0-17.4 path; 17.5+ calls didReceiveTap")
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            handleTap()
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            if let location = tap.hoverPose?.location {
                editor?.lastPencilPoint = convert(location, from: interaction.view)
            }
            handleTap()
        }

        private func handleTap() {
            guard isFrontmost, let editor else { return }
            editor.pencilDoubleTap(preference: Self.tapPreference)
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction,
                               didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended, isFrontmost, let editor else { return }
            var point: CGPoint?
            if let location = squeeze.hoverPose?.location {
                let local = convert(location, from: interaction.view)
                if bounds.contains(local) { point = local }
            }
            editor.pencilSqueeze(preference: Self.preference(UIPencilInteraction.preferredSqueezeAction),
                                 hoverPoint: point)
        }

        // MARK: Scribble over topics

        func indirectScribbleInteraction(_ interaction: any UIInteraction, requestElementsIn rect: CGRect,
                                         completion: @escaping ([UUID]) -> Void) {
            guard isFrontmost, let editor else {
                completion([])
                return
            }
            let local = convert(rect, from: interaction.view).intersection(bounds)
            completion(local.isNull ? [] : editor.scribbleTopics(inScreenRect: local))
        }

        func indirectScribbleInteraction(_ interaction: any UIInteraction, isElementFocused elementIdentifier: UUID)
            -> Bool {
            editor?.editingID == elementIdentifier
        }

        func indirectScribbleInteraction(_ interaction: any UIInteraction, frameForElement elementIdentifier: UUID)
            -> CGRect {
            guard let frame = editor?.screenFrame(of: elementIdentifier) else { return .null }
            return convert(frame, to: interaction.view)
        }

        func indirectScribbleInteraction(_ interaction: any UIInteraction, focusElementIfNeeded elementIdentifier: UUID,
                                         referencePoint focusReferencePoint: CGPoint,
                                         completion: @escaping ((any UIResponder & UITextInput)?) -> Void) {
            guard let editor else {
                completion(nil)
                return
            }
            editor.beginScribble(on: elementIdentifier)
            waitForTextInput(attempts: 40, completion: completion)
        }

        func indirectScribbleInteraction(_ interaction: any UIInteraction,
                                         willBeginWritingInElement elementIdentifier: UUID) {
            editor?.beginCanvasGesture(.scribble)
        }

        func indirectScribbleInteraction(_ interaction: any UIInteraction,
                                         didFinishWritingInElement elementIdentifier: UUID) {
            editor?.endCanvasGesture(.scribble)
        }

        /// The inline editor becomes first responder asynchronously
        /// (`NodeEditorField.acquireFocus`): hand it to Scribble once it is.
        private func waitForTextInput(attempts: Int, completion: @escaping ((any UIResponder & UITextInput)?) -> Void) {
            if let input = UIResponder.mindMapCurrentFirstResponder() as? (UIResponder & UITextInput),
               (input as? UIView)?.window === window {
                completion(input)
                return
            }
            guard attempts > 0 else {
                completion(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                guard let self else {
                    completion(nil)
                    return
                }
                self.waitForTextInput(attempts: attempts - 1, completion: completion)
            }
        }
    }
}

extension UIResponder {
    private static weak var mindMapFoundResponder: UIResponder?

    /// The first responder of the key window (sendAction to nil).
    static func mindMapCurrentFirstResponder() -> UIResponder? {
        mindMapFoundResponder = nil
        UIApplication.shared.sendAction(#selector(UIResponder.mindMapCaptureFirstResponder(_:)), to: nil, from: nil,
                                        for: nil)
        return mindMapFoundResponder
    }

    @objc private func mindMapCaptureFirstResponder(_ sender: Any?) {
        UIResponder.mindMapFoundResponder = self
    }
}
#endif
