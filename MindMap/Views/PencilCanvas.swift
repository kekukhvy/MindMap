#if os(iOS)
import PencilKit
import SwiftUI
import UIKit

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

/// PKCanvasView on a fixed-width page (`HandwrittenNote.pageWidth`, zoomed to
/// fit the width), white paper in light ink colors even in Dark Mode.
final class PencilCanvasView: PKCanvasView {
    let forwarder = DrawingUndoForwarder()
    var onLayout: (() -> Void)?

    override var undoManager: UndoManager? { forwarder }

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

/// SwiftUI wrapper of the iPad handwriting canvas. Changes are debounced
/// (`commitDelay` after the last stroke, at most `maxCommitDelay` after the
/// first) and committed as one "Draw" undo step; also committed when the
/// canvas goes away (Done), before undo/redo, and when the app resigns active.
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

        let picker = PKToolPicker()
        picker.colorUserInterfaceStyle = .light
        picker.addObserver(canvas)
        picker.setVisible(true, forFirstResponder: canvas)
        coordinator.toolPicker = picker
        apply(to: canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
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
        canvas.resignFirstResponder()
    }

    private func apply(to canvas: PencilCanvasView) {
        canvas.forwarder.target = undoManager
        let policy: PKCanvasViewDrawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
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
        private var fittedWidth: CGFloat = 0
        private var resignObserver: NSObjectProtocol?

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

        /// Commits pending strokes as one "Draw" step on the document's undo manager.
        func flush() {
            timer?.invalidate()
            timer = nil
            guard pending != nil, let canvas else { return }
            pending = nil
            let data = canvas.drawing.dataRepresentation()
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
            canvas.drawing = HandwrittenNote.drawing(stored)
            isReloading = false
            updateContentSize()
        }

        // MARK: Page geometry

        /// Fits the page width to the view (on first layout and size changes)
        /// and keeps room below the writing.
        func updateLayout() {
            guard let canvas, canvas.bounds.width > 0 else { return }
            let fit = canvas.bounds.width / HandwrittenNote.pageWidth
            if abs(canvas.bounds.width - fittedWidth) > 0.5 {
                let wasFitted = fittedWidth == 0 || canvas.zoomScale <= canvas.minimumZoomScale + 0.001
                fittedWidth = canvas.bounds.width
                canvas.minimumZoomScale = fit
                canvas.maximumZoomScale = fit * 5
                if wasFitted || canvas.zoomScale < fit { canvas.zoomScale = fit }
            }
            updateContentSize()
        }

        func updateContentSize() {
            guard let canvas, canvas.bounds.height > 0 else { return }
            let zoom = canvas.zoomScale
            let height = HandwrittenNote.pageHeight(for: canvas.drawing, minHeight: canvas.bounds.height / zoom)
            let size = CGSize(width: HandwrittenNote.pageWidth * zoom, height: height * zoom)
            if abs(canvas.contentSize.width - size.width) > 0.5 || abs(canvas.contentSize.height - size.height) > 0.5 {
                canvas.contentSize = size
            }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            updateContentSize()
        }
    }
}
#endif
