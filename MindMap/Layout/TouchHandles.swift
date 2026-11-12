import CoreGraphics
import Foundation

/// "+" handle on the child side of the selected (or Pencil-hovered) topic
/// (iPad): tap = add a child and name it. Sits beyond the collapse toggle
/// when that is shown on the same edge. Pure geometry + hit testing
/// (screen points).
enum AddChildHandle {
    /// Drawn circle.
    static let diameter: CGFloat = 24
    /// Touch target (Apple HIG minimum).
    static let hitDiameter: CGFloat = 44
    /// Gap between the topic edge (or the toggle) and the drawn circle, so
    /// the touch target never reaches into the topic.
    static let gap: CGFloat = (hitDiameter - diameter) / 2

    /// Center of the handle of a topic with screen `frame`.
    /// - Parameter toggleExtent: how far the collapse toggle sticks out of
    ///   the same edge (0 = no toggle).
    static func center(frame: CGRect, edge: BadgeEdge, toggleExtent: CGFloat) -> CGPoint {
        let offset = toggleExtent + gap + diameter / 2
        switch edge {
        case .trailing: return CGPoint(x: frame.maxX + offset, y: frame.midY)
        case .leading: return CGPoint(x: frame.minX - offset, y: frame.midY)
        case .bottom: return CGPoint(x: frame.midX, y: frame.maxY + offset)
        }
    }

    /// Extent of `CollapseToggle` beyond the topic edge (mirrors its
    /// metrics: 4·scale gap, capsule ≥ 16·scale; "+N" text is wider) plus
    /// the 3 pt of its enlarged touch shape.
    static func toggleExtent(isShown: Bool, edge: BadgeEdge, isCollapsed: Bool, hiddenCount: Int,
                             scale: CGFloat) -> CGFloat {
        guard isShown else { return 0 }
        let size = max(16 * scale, 12)
        var length = size
        if isCollapsed, edge != .bottom {
            let label = hiddenCount > 0 ? "+\(hiddenCount)" : "+"
            let font = max(10 * scale, 8)
            length = max(size, CGFloat(label.count) * font * 0.62 + 8 * scale)
        }
        return 4 * scale + length + 3
    }

    /// Point within the touch target of a handle at `center`.
    static func contains(_ point: CGPoint, center: CGPoint) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= hitDiameter / 2
    }

    /// Handle under `point` (nearest when targets overlap), never one whose
    /// target overlaps the touched topic itself.
    static func target(at point: CGPoint, handles: [UUID: CGPoint], topicFrames: [UUID: CGRect] = [:]) -> UUID? {
        if topicFrames.values.contains(where: { $0.contains(point) }) { return nil }
        return handles.filter { contains(point, center: $0.value) }
            .min { hypot(point.x - $0.value.x, point.y - $0.value.y) < hypot(point.x - $1.value.x, point.y - $1.value.y) }?
            .key
    }

    /// Handle visibility: the single selected topic (not while editing,
    /// dragging, picking or in Select mode) and the Pencil-hovered topic.
    static func isShown(for id: UUID, selection: Set<UUID>, hoveredID: UUID?, editingID: UUID?,
                        isBusy: Bool) -> Bool {
        guard editingID != id, !isBusy else { return false }
        return hoveredID == id || selection == [id]
    }
}

/// Apple Pencil settings (mirror of `UIPencilPreferredAction`, so the
/// decisions are testable on every platform).
enum PencilPreference: Equatable {
    case ignore, switchEraser, switchPrevious, showColorPalette, showInkAttributes
    case showContextualPalette, runSystemShortcut
    /// A value added by a later iPadOS.
    case other
}

/// What a Pencil barrel double-tap / squeeze does on the map canvas.
enum PencilMapAction: Equatable {
    /// Add a child to the selected topic and name it.
    case addChild(UUID)
    /// Show the action palette for the current selection.
    case showPalette
    /// Select the topic under the Pencil and show its palette.
    case selectAndShowPalette(UUID)
    /// Insert palette at a screen point over empty canvas.
    case insertMenu(CGPoint)
}

/// Decisions for Pencil gestures on the map (the drawing-note editor has its
/// own PencilKit tool picker, which handles them there).
///
/// Double-tap: the user's setting picks a *drawing tool* (eraser, previous
/// tool, color palette, ink attributes); the map has no drawing tools, so
/// those settings mean "the app's primary quick action" = add a child to
/// the selected topic. "Off" (`.ignore`) and "Run System Shortcut" (handled
/// by the system) do nothing; "Show Contextual Palette" shows our palette.
/// Squeeze (Pencil Pro): its default is "Show Contextual Palette" — the
/// action palette (topic) or the Insert palette (empty canvas); every
/// setting except Off / System Shortcut shows it (the tool settings have no
/// meaning on the map either).
enum PencilPolicy {
    static func doubleTapAction(preference: PencilPreference, selectedID: UUID?, isMultiSelection: Bool,
                                fallbackPoint: CGPoint) -> PencilMapAction? {
        switch preference {
        case .ignore, .runSystemShortcut:
            return nil
        case .showContextualPalette:
            return selectedID == nil ? .insertMenu(fallbackPoint) : .showPalette
        case .switchEraser, .switchPrevious, .showColorPalette, .showInkAttributes, .other:
            guard let selectedID, !isMultiSelection else { return selectedID == nil ? nil : .showPalette }
            return .addChild(selectedID)
        }
    }

    /// - Parameters:
    ///   - hoverPoint: Pencil hover location (screen) at the squeeze, if any.
    ///   - topicAtHover: topic under `hoverPoint`.
    ///   - lastPoint: last known Pencil location (hover / touch).
    ///   - viewCenter: fallback for the Insert palette.
    static func squeezeAction(preference: PencilPreference, hoverPoint: CGPoint?, topicAtHover: UUID?,
                              selectedID: UUID?, lastPoint: CGPoint?, viewCenter: CGPoint) -> PencilMapAction? {
        switch preference {
        case .ignore, .runSystemShortcut: return nil
        default: break
        }
        if let topicAtHover { return .selectAndShowPalette(topicAtHover) }
        if let hoverPoint { return .insertMenu(hoverPoint) }
        if selectedID != nil { return .showPalette }
        return .insertMenu(lastPoint ?? viewCenter)
    }
}

/// Topics Scribble may write into (UIIndirectScribbleInteraction elements):
/// visible topics whose screen frame meets the writing rect, front-most first.
enum ScribbleTargets {
    static func topics(in rect: CGRect, frames: [UUID: CGRect], order: [UUID]) -> [UUID] {
        order.reversed().filter { id in frames[id].map { $0.intersects(rect) } ?? false }
    }

    /// Topic under a point (front-most), for squeeze / hover targets.
    static func topic(at point: CGPoint, frames: [UUID: CGRect], order: [UUID]) -> UUID? {
        order.last { frames[$0]?.contains(point) == true }
    }
}
