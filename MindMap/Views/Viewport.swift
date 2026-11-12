import CoreGraphics

/// Pan/zoom transform of the canvas: screen = map * scale + offset (pure).
struct Viewport: Equatable {
    static let minScale: CGFloat = 0.2
    static let maxScale: CGFloat = 4

    var scale: CGFloat = 1
    /// Screen position of the map origin (root center).
    var offset: CGPoint = .zero

    func toScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
    }

    func toScreen(_ rect: CGRect) -> CGRect {
        CGRect(origin: toScreen(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    func toMap(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    static func clamp(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minScale), maxScale)
    }

    /// Zooms keeping the map point under `anchor` (screen) fixed.
    mutating func zoom(to newScale: CGFloat, around anchor: CGPoint) {
        let clamped = Viewport.clamp(newScale)
        let ratio = clamped / scale
        offset = CGPoint(x: anchor.x - (anchor.x - offset.x) * ratio, y: anchor.y - (anchor.y - offset.y) * ratio)
        scale = clamped
    }

    mutating func pan(dx: CGFloat, dy: CGFloat) {
        offset.x += dx
        offset.y += dy
    }

    /// Viewport showing `bounds` centered in `size` (never above `maxScale`).
    static func fitting(_ bounds: CGRect, in size: CGSize, margin: CGFloat = 40, maxScale: CGFloat = 1.5) -> Viewport {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return Viewport(scale: 1, offset: CGPoint(x: size.width / 2, y: size.height / 2))
        }
        let available = CGSize(width: max(size.width - 2 * margin, 1), height: max(size.height - 2 * margin, 1))
        let scale = clamp(min(available.width / bounds.width, available.height / bounds.height, maxScale))
        let offset = CGPoint(x: size.width / 2 - bounds.midX * scale, y: size.height / 2 - bounds.midY * scale)
        return Viewport(scale: scale, offset: offset)
    }

    /// Pans minimally so that map rect `rect` is visible with `margin`.
    mutating func reveal(_ rect: CGRect, in size: CGSize, margin: CGFloat = 24) {
        let screen = toScreen(rect)
        offset.x += Viewport.correction(min: screen.minX, max: screen.maxX, limit: size.width, margin: margin)
        offset.y += Viewport.correction(min: screen.minY, max: screen.maxY, limit: size.height, margin: margin)
    }

    /// Viewport for jumping to `rect` (Go to): unchanged if it is already
    /// fully visible with `margin` at a readable zoom; otherwise `rect` is
    /// centered, zooming in to at least `minScale` (never out).
    func focusing(_ rect: CGRect, in size: CGSize, margin: CGFloat = 40, minScale: CGFloat = 0.6) -> Viewport {
        guard size.width > 0, size.height > 0 else { return self }
        let screen = toScreen(rect)
        let visible = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        if scale >= minScale, visible.contains(screen) { return self }
        let newScale = Viewport.clamp(max(scale, minScale))
        let offset = CGPoint(x: size.width / 2 - rect.midX * newScale, y: size.height / 2 - rect.midY * newScale)
        return Viewport(scale: newScale, offset: offset)
    }

    private static func correction(min lower: CGFloat, max upper: CGFloat, limit: CGFloat, margin: CGFloat) -> CGFloat {
        if lower < margin { return margin - lower }
        if upper > limit - margin { return Swift.max(limit - margin - upper, margin - lower) }
        return 0
    }
}
