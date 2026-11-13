import CoreGraphics
import Foundation
import PencilKit

/// Helpers for handwritten notes: the attachment file is exactly
/// `PKDrawing.dataRepresentation()` (`attachments/<UUID>.drawing`).
///
/// Coordinates: PencilKit's, origin at the top left. Notes made before the
/// endless canvas live on a page `pageWidth` points wide starting at the
/// origin; the canvas is now endless (Freeform-like): ink may lie anywhere,
/// including negative coordinates. Stored strokes are never moved: the views
/// extend their scrollable area around the ink instead (iPad and macOS
/// alike; the iPad canvas shows the drawing shifted, see `canvasOrigin`).
enum HandwrittenNote {
    /// Width of the original page; an empty note opens with this width fitted to the view.
    static let pageWidth: CGFloat = 1024
    /// Empty room around the ink when a note opens fitted to its ink (drawing points).
    static let fitPadding: CGFloat = 40
    /// How far the minimum zoom goes below "everything fits".
    static let zoomOutRoom: CGFloat = 2
    /// Maximum zoom relative to the page-width fit.
    static let maxZoomFactor: CGFloat = 8

    static var emptyData: Data { PKDrawing().dataRepresentation() }

    /// Decodes stored data; nil/empty/corrupt data is an empty drawing.
    static func drawing(_ data: Data?) -> PKDrawing {
        guard let data, !data.isEmpty, let drawing = try? PKDrawing(data: data) else { return PKDrawing() }
        return drawing
    }

    /// Bounds of the ink, nil for an empty drawing.
    static func inkBounds(_ drawing: PKDrawing) -> CGRect? {
        let bounds = drawing.bounds
        return bounds.isNull || bounds.isEmpty ? nil : bounds
    }

    /// Zoom at which the page width fills a viewport `viewport` points wide (the empty note's zoom).
    static func pageZoom(viewport: CGSize) -> CGFloat { viewport.width / pageWidth }

    /// Zoom at which `ink` plus `fitPadding` fits in `viewport`.
    static func fitZoom(ink: CGRect, viewport: CGSize) -> CGFloat {
        let target = ink.insetBy(dx: -fitPadding, dy: -fitPadding)
        return min(viewport.width / target.width, viewport.height / target.height)
    }

    /// Zoom range: out until all the ink fits with room to spare, in to `maxZoomFactor` × the page fit.
    static func zoomLimits(ink: CGRect?, viewport: CGSize) -> ClosedRange<CGFloat> {
        let page = pageZoom(viewport: viewport)
        let fit = ink.map { min(page, fitZoom(ink: $0, viewport: viewport)) } ?? page
        return fit / zoomOutRoom ... page * maxZoomFactor
    }

    /// What a note shows when it opens in `viewport` (screen points): the
    /// page at its fitted width from the origin, as before the endless canvas,
    /// while that shows all the ink; otherwise the ink fitted and centred.
    /// `visible` is in drawing coordinates.
    static func openingView(ink: CGRect?, viewport: CGSize) -> (zoom: CGFloat, visible: CGRect) {
        let page = pageZoom(viewport: viewport)
        let pageView = CGRect(x: 0, y: 0, width: viewport.width / page, height: viewport.height / page)
        guard let ink, !pageView.contains(ink) else { return (page, pageView) }
        let zoom = min(page, fitZoom(ink: ink, viewport: viewport))
        let size = CGSize(width: viewport.width / zoom, height: viewport.height / zoom)
        return (zoom, CGRect(x: ink.midX - size.width / 2, y: ink.midY - size.height / 2,
                             width: size.width, height: size.height))
    }

    /// Scrollable area (drawing coordinates) while `visible` is on screen:
    /// the original page, the ink and the visible rect, plus one visible
    /// rect of empty room on every side. Recomputed as the view scrolls,
    /// zooms or the ink grows, so the canvas extends in every direction.
    static func contentRect(ink: CGRect?, visible: CGRect) -> CGRect {
        var rect = visible.union(CGRect(x: 0, y: 0, width: pageWidth, height: visible.height))
        if let ink { rect = rect.union(ink) }
        return rect.insetBy(dx: -visible.width, dy: -visible.height)
    }

    /// Drawing coordinates of the iPad canvas's content origin. PencilKit
    /// takes strokes only between the content origin and `contentSize`, so
    /// the canvas never uses negative content coordinates: it shows the
    /// drawing moved by `-origin`, and the origin stays at or above-left of
    /// `content`. It moves only up / left and then `room` further, so the
    /// drawing is shifted once per screen of scrolling, not on every frame;
    /// integral, so moving the strokes back on save is exact.
    static func canvasOrigin(current: CGPoint, content: CGRect, room: CGSize) -> CGPoint {
        CGPoint(x: content.minX < current.x ? (content.minX - room.width).rounded(.down) : current.x,
                y: content.minY < current.y ? (content.minY - room.height).rounded(.down) : current.y)
    }

    /// Default title of the `index`-th (0-based) handwritten note of a topic.
    static func defaultTitle(index: Int) -> String {
        index == 0 ? "Handwritten Note" : "Handwritten Note \(index + 1)"
    }
}
