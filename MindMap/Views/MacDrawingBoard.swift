#if os(macOS)
import AppKit
import PencilKit
import SwiftUI

/// Mouse tool of the macOS drawing window.
enum MacDrawingTool: String, CaseIterable {
    case view, pen, eraser
}

/// macOS view of a handwritten note. PKCanvasView does not exist on macOS,
/// so the drawing is rendered with `PKDrawing.image(from:scale:)` on a white
/// endless page inside a magnifiable NSScrollView (pinch / ⌘-scroll to zoom;
/// geometry shared with the iPad, see `HandwrittenNote`). Basic
/// mouse drawing: the pen turns a mouse drag into a `PKStroke` (pen ink),
/// the eraser removes whole strokes; each gesture is one `onCommit`.
struct MacDrawingBoard: NSViewRepresentable {
    struct Ink {
        var name: String
        var hex: String
    }

    static let inkColors = [Ink(name: "Black", hex: "#1E1E1E"), Ink(name: "Blue", hex: "#2E6FE0"),
                            Ink(name: "Red", hex: "#D9443B"), Ink(name: "Green", hex: "#2F9D57")]

    static func color(hex: String) -> NSColor {
        guard let rgb = HexColor.parse(hex) else { return .black }
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    let data: Data?
    let revision: Int
    let tool: MacDrawingTool
    let inkColor: NSColor
    let undoManager: UndoManager?
    let onCommit: (Data) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.backgroundColor = NSColor(white: 0.9, alpha: 1)
        scroll.drawsBackground = true
        let page = DrawingPageView(frame: .zero)
        page.drawing = HandwrittenNote.drawing(data)
        page.loadedData = data
        scroll.documentView = page
        context.coordinator.scroll = scroll
        apply(to: page)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.layoutChanged),
                                               name: NSView.frameDidChangeNotification, object: scroll)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.magnified),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.userScrolled),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.postsFrameChangedNotifications = true
        scroll.contentView.postsBoundsChangedNotifications = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let page = scroll.documentView as? DrawingPageView else { return }
        apply(to: page)
        if page.loadedData != data, !page.isTracking {
            page.loadedData = data
            page.drawing = HandwrittenNote.drawing(data)
        }
        context.coordinator.fit()
    }

    private func apply(to page: DrawingPageView) {
        page.tool = tool
        page.inkColor = inkColor
        page.documentUndoManager = undoManager
        page.onCommit = { drawing in
            let data = drawing.dataRepresentation()
            page.loadedData = data
            onCommit(data)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var scroll: NSScrollView?
        /// The user zoomed or scrolled: a window resize no longer re-fits the note.
        private var userMoved = false
        private var fittedSize: CGSize = .zero

        @objc func layoutChanged() { fit() }
        @objc func userScrolled() { userMoved = true }
        @objc func scrolled() { (scroll?.documentView as? DrawingPageView)?.updateContent() }
        @objc func magnified() {
            userMoved = true
            (scroll?.documentView as? DrawingPageView)?.renderIfNeeded()
        }

        /// Like the iPad: the note opens fitted to its ink (the page width
        /// when it fits) and re-fits on resizes until the user zooms or
        /// scrolls; the page keeps room around the ink and the visible rect.
        func fit() {
            guard let scroll, let page = scroll.documentView as? DrawingPageView,
                  scroll.contentSize.width > 0, scroll.contentSize.height > 0 else { return }
            let viewport = scroll.contentSize
            let ink = HandwrittenNote.inkBounds(page.drawing)
            let limits = HandwrittenNote.zoomLimits(ink: ink, viewport: viewport)
            scroll.minMagnification = min(limits.lowerBound, scroll.magnification)
            scroll.maxMagnification = limits.upperBound
            if !userMoved, abs(viewport.width - fittedSize.width) > 0.5 || abs(viewport.height - fittedSize.height) > 0.5 {
                fittedSize = viewport
                let opening = HandwrittenNote.openingView(ink: ink, viewport: viewport)
                page.updateContent(visible: opening.visible)
                // The magnification setter zooms around the center: scroll afterwards.
                scroll.magnification = opening.zoom
                scroll.contentView.scroll(to: opening.visible.origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                page.renderIfNeeded()
            }
            page.updateContent()
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

/// White page showing a PKDrawing (cached bitmap) plus the stroke being drawn.
/// Flipped: top-left origin like PencilKit's coordinates.
final class DrawingPageView: NSView, NSMenuItemValidation {
    var drawing = PKDrawing() {
        didSet {
            image = nil
            updateContent()
            needsDisplay = true
        }
    }

    var loadedData: Data?
    var tool: MacDrawingTool = .pen {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    var inkColor: NSColor = .black
    var inkWidth: CGFloat = 3
    var onCommit: ((PKDrawing) -> Void)?
    weak var documentUndoManager: UndoManager?
    private(set) var isTracking = false

    private var image: NSImage?
    private var imageScale: CGFloat = 0
    private var isUpdatingContent = false
    private var livePoints: [(point: CGPoint, time: TimeInterval)] = []
    private var erased = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Endless page: frame and bounds are both the content rect (drawing
    /// coordinates, see `HandwrittenNote.contentRect`), so the clip view
    /// scrolls in drawing coordinates and growing to the left or up moves
    /// neither the strokes nor the visible part.
    func updateContent(visible: CGRect? = nil) {
        guard let visible = visible ?? enclosingScrollView?.documentVisibleRect, !visible.isEmpty else { return }
        let rect = HandwrittenNote.contentRect(ink: HandwrittenNote.inkBounds(drawing), visible: visible).integral
        guard !isUpdatingContent, frame != rect || bounds.origin != rect.origin else { return }
        // Moving the frame can make the clip view report a scroll: not a new visible rect.
        isUpdatingContent = true
        setFrameOrigin(rect.origin)
        setFrameSize(rect.size)
        setBoundsOrigin(rect.origin)
        isUpdatingContent = false
    }

    // MARK: Rendering

    /// Bitmap scale matching the current zoom and screen (capped in pixels).
    private var wantedScale: CGFloat {
        let magnification = enclosingScrollView?.magnification ?? 1
        let backing = window?.backingScaleFactor ?? 2
        var scale = max(1, magnification * backing)
        let bounds = drawing.bounds
        if !bounds.isNull {
            let pixels = bounds.width * bounds.height * scale * scale
            let limit: CGFloat = 40_000_000
            if pixels > limit { scale *= sqrt(limit / pixels) }
        }
        return (scale * 2).rounded(.up) / 2
    }

    func renderIfNeeded() {
        if abs(wantedScale - imageScale) > 0.01 {
            image = nil
            needsDisplay = true
        }
    }

    /// Ink rendered for a light page (no dark-mode color inversion).
    static func render(_ drawing: PKDrawing, rect: CGRect, scale: CGFloat) -> NSImage {
        var image = NSImage()
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            image = drawing.image(from: rect, scale: scale)
        }
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        let bounds = drawing.bounds
        if !bounds.isNull, !bounds.isEmpty {
            if image == nil {
                imageScale = wantedScale
                image = Self.render(drawing, rect: bounds, scale: imageScale)
            }
            image?.draw(in: bounds)
        }
        if livePoints.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = inkWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: livePoints[0].point)
            for entry in livePoints.dropFirst() { path.line(to: entry.point) }
            inkColor.setStroke()
            path.stroke()
        }
    }

    override func resetCursorRects() {
        switch tool {
        case .view: break
        case .pen: addCursorRect(visibleRect, cursor: .crosshair)
        case .eraser: addCursorRect(visibleRect, cursor: .disappearingItem)
        }
    }

    // MARK: Mouse

    /// ⌘-scroll zooms around the pointer (pinch is handled by NSScrollView).
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let scroll = enclosingScrollView else {
            return super.scrollWheel(with: event)
        }
        let factor = exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
        scroll.setMagnification(scroll.magnification * factor, centeredAt: convert(event.locationInWindow, from: nil))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard tool != .view else { return super.mouseDown(with: event) }
        isTracking = true
        let point = convert(event.locationInWindow, from: nil)
        switch tool {
        case .pen: livePoints = [(point, event.timestamp)]
        case .eraser:
            erased = false
            erase(at: point)
        case .view: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return super.mouseDragged(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        switch tool {
        case .pen:
            if let last = livePoints.last?.point, hypot(point.x - last.x, point.y - last.y) < 0.5 { return }
            livePoints.append((point, event.timestamp))
            let recent = livePoints.suffix(2).map(\.point)
            let dirty = CGRect(x: min(recent[0].x, recent.last!.x), y: min(recent[0].y, recent.last!.y),
                               width: abs(recent[0].x - recent.last!.x), height: abs(recent[0].y - recent.last!.y))
            setNeedsDisplay(dirty.insetBy(dx: -inkWidth * 2, dy: -inkWidth * 2))
        case .eraser:
            erase(at: point)
        case .view: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return super.mouseUp(with: event) }
        isTracking = false
        switch tool {
        case .pen:
            if livePoints.count == 1 {
                // A click draws a dot.
                let p = livePoints[0]
                livePoints.append((CGPoint(x: p.point.x + 0.1, y: p.point.y + 0.1), p.time + 0.01))
            }
            if let stroke = Self.stroke(from: livePoints, color: inkColor, width: inkWidth) {
                livePoints = []
                var updated = drawing
                updated.strokes.append(stroke)
                drawing = updated
                onCommit?(updated)
            }
            livePoints = []
            needsDisplay = true
        case .eraser:
            if erased { onCommit?(drawing) }
        case .view: break
        }
    }

    /// Mouse points → a pen-ink PKStroke (constant width; time offsets from the events).
    static func stroke(from points: [(point: CGPoint, time: TimeInterval)], color: NSColor,
                       width: CGFloat) -> PKStroke? {
        guard let start = points.first?.time, points.count > 1 else { return nil }
        let strokePoints = points.map {
            PKStrokePoint(location: $0.point, timeOffset: $0.time - start, size: CGSize(width: width, height: width),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: color), path: path)
    }

    /// Stroke eraser: removes every stroke passing within a few points of `point`.
    private func erase(at point: CGPoint) {
        let radius: CGFloat = 6
        let hit = drawing.strokes.indices.filter { index in
            let stroke = drawing.strokes[index]
            guard stroke.renderBounds.insetBy(dx: -radius, dy: -radius).contains(point) else { return false }
            let transform = stroke.transform
            return stroke.path.interpolatedPoints(by: .distance(2)).contains { sample in
                let p = sample.location.applying(transform)
                return hypot(p.x - point.x, p.y - point.y) <= radius + sample.size.width / 2
            }
        }
        guard !hit.isEmpty else { return }
        var updated = drawing
        for index in hit.reversed() { updated.strokes.remove(at: index) }
        erased = true
        drawing = updated
    }

    // MARK: Undo (document's manager, like the note window)

    @objc func undo(_ sender: Any?) {
        if documentUndoManager?.canUndo == true { documentUndoManager?.undo() }
    }

    @objc func redo(_ sender: Any?) {
        if documentUndoManager?.canRedo == true { documentUndoManager?.redo() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            if let manager = documentUndoManager { menuItem.title = manager.undoMenuItemTitle }
            return documentUndoManager?.canUndo ?? false
        case #selector(redo(_:)):
            if let manager = documentUndoManager { menuItem.title = manager.redoMenuItemTitle }
            return documentUndoManager?.canRedo ?? false
        default:
            return true
        }
    }
}
#endif
