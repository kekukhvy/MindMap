#if os(iOS)
import PencilKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Lets SwiftUI controls (toolbar Undo/Redo) commit strokes that are still
/// waiting for the debounce before acting on the undo stack.
final class DrawingFlusher {
    fileprivate var action: (() -> Void)?
    func flush() { action?() }
}

/// Undo manager the canvas exposes to UIKit/PencilKit.
///
/// Undo design: the drawing's history lives on the DOCUMENT's undo manager
/// (one "Draw" step per batch of strokes, written by the coordinator through
/// `setAttachmentContent`), like the Markdown note. PencilKit would register
/// its own per-stroke undo on the responder chain's manager (= the window's,
/// which is the document's on iPad) – that would double every step and leave
/// actions targeting a canvas that is gone once the sheet closes. So the
/// canvas gets this manager instead: registration is disabled (PencilKit's
/// registrations are dropped), while undo/redo requests that reach it
/// (three-finger swipe, ⌘Z, Edit menu, tool picker) flush pending strokes
/// and are forwarded to the document's manager.
final class DrawingUndoForwarder: UndoManager {
    /// The document's undo manager. Its change notifications are re-posted
    /// with this manager as the object, so PencilKit's tool picker (which
    /// watches the first responder's manager) updates its Undo/Redo buttons.
    weak var target: UndoManager? {
        didSet {
            guard target !== oldValue else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let target else { return }
            for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                         .NSUndoManagerDidRedoChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: target, queue: nil) {
                    [weak self] note in
                    guard let self else { return }
                    NotificationCenter.default.post(name: note.name, object: self)
                })
            }
        }
    }

    private var observers: [NSObjectProtocol] = []
    var willForward: (() -> Void)?
    var hasPendingChanges: () -> Bool = { false }

    override init() {
        super.init()
        groupsByEvent = false
        disableUndoRegistration()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var canUndo: Bool { hasPendingChanges() || target?.canUndo == true }
    override var canRedo: Bool { !hasPendingChanges() && target?.canRedo == true }
    override var undoActionName: String { hasPendingChanges() ? "Draw" : target?.undoActionName ?? "" }
    override var redoActionName: String { target?.redoActionName ?? "" }
    override var undoMenuItemTitle: String { target?.undoMenuItemTitle ?? super.undoMenuItemTitle }
    override var redoMenuItemTitle: String { target?.redoMenuItemTitle ?? super.redoMenuItemTitle }

    override func undo() {
        willForward?()
        if target?.canUndo == true { target?.undo() }
    }

    override func redo() {
        willForward?()
        if target?.canRedo == true { target?.redo() }
    }
}

/// PKCanvasView on an endless canvas (see `HandwrittenNote`: opens fitted to
/// the ink, extends as the user scrolls or writes), white paper in light ink
/// colors even in Dark Mode.
final class PencilCanvasView: PKCanvasView {
    let forwarder = DrawingUndoForwarder()
    var onLayout: (() -> Void)?
    /// Editable canvas: becomes first responder once it is in a window, so its
    /// tool picker shows and PencilKit's Pencil double-tap / squeeze work.
    /// (SwiftUI adds the view to the window after `makeUIView`, so an earlier
    /// `becomeFirstResponder` fails.)
    var takesFocusInWindow = false

    override var undoManager: UndoManager? { forwarder }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, takesFocusInWindow, !isFirstResponder { becomeFirstResponder() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override var keyCommands: [UIKeyCommand]? {
        let undo = UIKeyCommand(title: "Undo", action: #selector(undoDocument), input: "z", modifierFlags: .command)
        let redo = UIKeyCommand(title: "Redo", action: #selector(redoDocument), input: "z",
                                modifierFlags: [.command, .shift])
        undo.wantsPriorityOverSystemBehavior = true
        redo.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [undo, redo]
    }

    @objc func undoDocument() { forwarder.undo() }
    @objc func redoDocument() { forwarder.redo() }
}

/// Notices the touch resting still at the end of a stroke (Apple Notes' "draw
/// a shape and hold"). It only observes: it never recognizes, never cancels
/// or delays touches, and runs alongside PencilKit's drawing recognizer.
final class StrokeHoldRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// How long the touch must rest (Notes: about half a second).
    static let holdDuration: TimeInterval = 0.5
    /// How far it may wander while resting (screen points).
    static let holdRadius: CGFloat = 8

    /// A touch went down (a new stroke starts).
    var onBegin: (() -> Void)?
    /// The touch has rested for `holdDuration`.
    var onHold: (() -> Void)?
    private var anchor: CGPoint?
    private var timer: Timer?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        onBegin?()
        guard numberOfTouches == 1, let touch = touches.first else { return stopWaiting() }
        restart(at: touch.location(in: nil))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first, let anchor else { return }
        let location = touch.location(in: nil)
        if hypot(location.x - anchor.x, location.y - anchor.y) > Self.holdRadius { restart(at: location) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        stopWaiting()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        stopWaiting()
        state = .failed
    }

    override func reset() {
        super.reset()
        stopWaiting()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func restart(at location: CGPoint) {
        anchor = location
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onHold?() }
        }
    }

    private func stopWaiting() {
        timer?.invalidate()
        timer = nil
        anchor = nil
    }
}

/// SwiftUI wrapper of the iPad handwriting canvas. Changes are debounced
/// (`commitDelay` after the last stroke, at most `maxCommitDelay` after the
/// first) and committed as one "Draw" undo step; also committed when the
/// canvas goes away (Done), before undo/redo, and when the app resigns active.
/// Drawing a line, circle, ellipse, rectangle or triangle and holding at the
/// end replaces the stroke with the clean shape (`ShapeRecognizer`), within
/// the same "Draw" step.
struct PencilCanvas: UIViewRepresentable {
    static let fingerDrawingKey = "MindMap.drawWithFinger"
    static let commitDelay: TimeInterval = 0.6
    static let maxCommitDelay: TimeInterval = 2

    let model: MindMapModel
    let attachmentID: UUID
    let fileName: String
    /// Store revision of the file: a change (undo/redo, revert) reloads the canvas.
    let revision: Int
    let undoManager: UndoManager?
    let fingerDrawing: Bool
    /// Read-only map (WP15): scroll / zoom only, no ink, no tool picker.
    var isReadOnly = false
    let flusher: DrawingFlusher

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PencilCanvasView {
        let canvas = PencilCanvasView()
        let coordinator = context.coordinator
        coordinator.canvas = canvas
        canvas.overrideUserInterfaceStyle = .light
        canvas.backgroundColor = .white
        canvas.alwaysBounceVertical = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        coordinator.lastData = model.content(of: attachmentID)
        canvas.drawing = HandwrittenNote.drawing(coordinator.lastData)
        canvas.delegate = coordinator
        canvas.forwarder.willForward = { [weak coordinator] in coordinator?.flush() }
        canvas.forwarder.hasPendingChanges = { [weak coordinator] in coordinator?.pending != nil }
        canvas.onLayout = { [weak coordinator] in coordinator?.updateLayout() }
        flusher.action = { [weak coordinator] in coordinator?.flush() }
        let hold = StrokeHoldRecognizer()
        hold.onBegin = { [weak coordinator] in coordinator?.strokeBegan() }
        hold.onHold = { [weak coordinator] in coordinator?.strokeHeld() }
        canvas.addGestureRecognizer(hold)

        let picker = PKToolPicker()
        picker.colorUserInterfaceStyle = .light
        picker.addObserver(canvas)
        picker.setVisible(!isReadOnly, forFirstResponder: canvas)
        coordinator.toolPicker = picker
        coordinator.installPencilTap()
        apply(to: canvas)
        return canvas
    }

    func updateUIView(_ canvas: PencilCanvasView, context: Context) {
        context.coordinator.parent = self
        apply(to: canvas)
        context.coordinator.reloadIfChanged()
    }

    static func dismantleUIView(_ canvas: PencilCanvasView, coordinator: Coordinator) {
        coordinator.flush()
        coordinator.toolPicker?.setVisible(false, forFirstResponder: canvas)
        coordinator.toolPicker?.removeObserver(canvas)
        coordinator.toolPicker?.removeObserver(coordinator)
        canvas.resignFirstResponder()
    }

    private func apply(to canvas: PencilCanvasView) {
        canvas.forwarder.target = undoManager
        canvas.takesFocusInWindow = !isReadOnly
        let policy: PKCanvasViewDrawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
        if canvas.drawingGestureRecognizer.isEnabled == isReadOnly {
            canvas.drawingGestureRecognizer.isEnabled = !isReadOnly
            if isReadOnly, canvas.isFirstResponder { canvas.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilCanvas
        weak var canvas: PencilCanvasView?
        var toolPicker: PKToolPicker?
        /// Data last loaded into / committed from the canvas.
        var lastData: Data?
        /// First uncommitted change (nil = nothing pending).
        private(set) var pending: Date?
        private var timer: Timer?
        private var isReloading = false
        private var resignObserver: NSObjectProtocol?
        /// Between PencilKit's begin / end of using the tool (a stroke is being drawn).
        private var isUsingTool = false
        /// Strokes on the canvas when the current stroke was held: the stroke
        /// that comes next is snapped to its shape.
        private var heldStrokeCount: Int?
        /// Tool picker selection (item identifiers) for the Pencil double-tap
        /// (`PencilCanvas+PencilTap.swift`): the current tool, the one before
        /// it, and when the selection last changed (system uptime).
        var currentToolID: String?
        var previousToolID: String?
        var toolChangedAt: TimeInterval?

        init(_ parent: PencilCanvas) {
            self.parent = parent
            super.init()
            resignObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }

        deinit {
            timer?.invalidate()
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }

        // MARK: Changes

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            updateContentSize()
            guard !isReloading else { return }
            snapHeldStroke()
            let now = Date()
            if pending == nil { pending = now }
            timer?.invalidate()
            let first = pending ?? now
            let delay = min(PencilCanvas.commitDelay,
                            max(0, PencilCanvas.maxCommitDelay - now.timeIntervalSince(first)))
            timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { isUsingTool = true }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { isUsingTool = false }

        // MARK: Shape snapping (draw and hold)

        func strokeBegan() { heldStrokeCount = nil }

        /// The touch rests while drawing with an inking tool (not eraser or lasso).
        func strokeHeld() {
            guard isUsingTool, let canvas, canvas.tool is PKInkingTool else { return }
            heldStrokeCount = canvas.drawing.strokes.count
        }

        /// Replaces the held stroke, once PencilKit adds it, with its shape. It
        /// changes the drawing inside this same change, so it is committed in
        /// the same "Draw" step.
        private func snapHeldStroke() {
            guard let held = heldStrokeCount, let canvas, canvas.drawing.strokes.count == held + 1 else { return }
            heldStrokeCount = nil
            var drawing = canvas.drawing
            guard let snapped = ShapeRecognizer.snapped(drawing.strokes[held]) else { return }
            drawing.strokes[held] = snapped
            canvas.drawing = drawing
            if #available(iOS 17.5, *) {
                let bounds = snapped.renderBounds
                let zoom = canvas.zoomScale
                UICanvasFeedbackGenerator(view: canvas)
                    .alignmentOccurred(at: CGPoint(x: bounds.midX * zoom, y: bounds.midY * zoom))
            }
        }

        /// Commits pending strokes as one "Draw" step on the document's undo manager.
        func flush() {
            timer?.invalidate()
            timer = nil
            guard pending != nil, let canvas else { return }
            pending = nil
            let data = storedDrawing(canvas.drawing).dataRepresentation()
            lastData = data
            parent.model.setAttachmentContent(data, for: parent.attachmentID, actionName: "Draw",
                                              coalescing: false, undoManager: parent.undoManager)
        }

        /// The stored file changed (undo/redo/revert): show it.
        func reloadIfChanged() {
            guard pending == nil, let canvas else { return }
            let stored = parent.model.content(of: parent.attachmentID)
            guard stored != lastData else { return }
            lastData = stored
            isReloading = true
            canvas.drawing = canvasDrawing(HandwrittenNote.drawing(stored))
            isReloading = false
            updateContentSize()
        }

        // MARK: Endless canvas geometry

        /// Content coordinates are canvas drawing coordinates × zoom
        /// (PencilKit's mapping), and PencilKit takes strokes only between
        /// the content origin and `contentSize`. So the canvas shows the
        /// drawing moved by `-origin` (`HandwrittenNote.canvasOrigin`): the
        /// scrollable area `content` (stored drawing coordinates) starts at
        /// or after the content origin, and every visible point can be
        /// written on. Growing up / left shifts the canvas strokes and the
        /// offset together: the visible ink stays put; saving moves the
        /// strokes back, so stored strokes keep their coordinates.
        private var content: CGRect = .null
        /// Stored drawing coordinates of the content origin.
        private(set) var origin: CGPoint = .zero
        private var laidOutSize: CGSize = .zero
        /// The user scrolled or zoomed: a size change no longer re-fits the note.
        private var userMoved = false
        private var isAdjusting = false

        /// Visible part of the drawing (stored drawing coordinates).
        var visibleRect: CGRect {
            guard let canvas, canvas.zoomScale > 0 else { return .null }
            let zoom = canvas.zoomScale
            return CGRect(x: origin.x + canvas.contentOffset.x / zoom, y: origin.y + canvas.contentOffset.y / zoom,
                          width: canvas.bounds.width / zoom, height: canvas.bounds.height / zoom)
        }

        /// Stored drawing → canvas drawing.
        private func canvasDrawing(_ stored: PKDrawing) -> PKDrawing {
            stored.transformed(using: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        }

        /// Canvas drawing → stored drawing (as saved).
        private func storedDrawing(_ shown: PKDrawing) -> PKDrawing {
            shown.transformed(using: CGAffineTransform(translationX: origin.x, y: origin.y))
        }

        /// Ink bounds in stored drawing coordinates.
        private var storedInk: CGRect? {
            canvas.flatMap { HandwrittenNote.inkBounds($0.drawing) }?.offsetBy(dx: origin.x, dy: origin.y)
        }

        /// First layout and size changes: open fitted to the ink (or the page
        /// width when empty) until the user scrolls or zooms.
        func updateLayout() {
            guard let canvas, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
            let size = canvas.bounds.size
            guard abs(size.width - laidOutSize.width) > 0.5 || abs(size.height - laidOutSize.height) > 0.5 else {
                return
            }
            laidOutSize = size
            let ink = storedInk
            let limits = HandwrittenNote.zoomLimits(ink: ink, viewport: size)
            canvas.minimumZoomScale = limits.lowerBound
            canvas.maximumZoomScale = limits.upperBound
            if userMoved {
                canvas.zoomScale = min(max(canvas.zoomScale, limits.lowerBound), limits.upperBound)
                updateContentSize()
                return
            }
            let opening = HandwrittenNote.openingView(ink: ink, viewport: size)
            isAdjusting = true
            canvas.zoomScale = opening.zoom
            isAdjusting = false
            apply(HandwrittenNote.contentRect(ink: ink, visible: opening.visible), room: opening.visible.size)
            isAdjusting = true
            canvas.contentOffset = CGPoint(x: (opening.visible.minX - origin.x) * opening.zoom,
                                           y: (opening.visible.minY - origin.y) * opening.zoom)
            isAdjusting = false
        }

        /// Keeps room around the ink and the visible rect; lowers the minimum
        /// zoom when the ink grows (never above the current zoom: no jump).
        func updateContentSize() {
            guard let canvas, canvas.bounds.height > 0, !isAdjusting, !canvas.isZooming else { return }
            let ink = storedInk
            let lower = HandwrittenNote.zoomLimits(ink: ink, viewport: canvas.bounds.size).lowerBound
            if lower < canvas.minimumZoomScale { canvas.minimumZoomScale = lower }
            let visible = visibleRect
            apply(HandwrittenNote.contentRect(ink: ink, visible: visible), room: visible.size)
        }

        /// Makes `rect` (stored drawing coordinates) the scrollable area. The
        /// origin moves only between strokes (moving the drawing would end
        /// the stroke being drawn); there is a screen of room until then.
        private func apply(_ rect: CGRect, room: CGSize) {
            guard let canvas, !rect.isNull else { return }
            content = rect
            isAdjusting = true
            defer { isAdjusting = false }
            let newOrigin = HandwrittenNote.canvasOrigin(current: origin, content: rect, room: room)
            if newOrigin != origin, !isUsingTool { move(to: newOrigin) }
            let zoom = canvas.zoomScale
            let size = CGSize(width: (rect.maxX - origin.x) * zoom, height: (rect.maxY - origin.y) * zoom)
            if abs(canvas.contentSize.width - size.width) > 0.5 || abs(canvas.contentSize.height - size.height) > 0.5 {
                canvas.contentSize = size
            }
        }

        /// Moves the content origin: the canvas strokes and the offset shift
        /// by the same amount, so nothing moves on screen.
        private func move(to newOrigin: CGPoint) {
            guard let canvas else { return }
            let shift = CGPoint(x: origin.x - newOrigin.x, y: origin.y - newOrigin.y)
            origin = newOrigin
            let wasReloading = isReloading
            isReloading = true
            canvas.drawing = canvas.drawing.transformed(using: CGAffineTransform(translationX: shift.x, y: shift.y))
            isReloading = wasReloading
            let zoom = canvas.zoomScale
            canvas.contentOffset = CGPoint(x: canvas.contentOffset.x + shift.x * zoom,
                                           y: canvas.contentOffset.y + shift.y * zoom)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { userMoved = true }
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { userMoved = true }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { updateContentSize() }

        /// While pinching UIKit scales `contentSize` itself (the origin stays
        /// put). A programmatic zoom recomputes the whole area.
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let canvas, !content.isNull, !isAdjusting, !canvas.isZooming else { return }
            updateContentSize()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            updateContentSize()
        }
    }
}
#endif
