import CoreGraphics
import Foundation

/// Everything the canvas needs to draw the virtual Favorites panel.
struct FavoritesPanelContent: Equatable {
    var entries: [FavoriteEntry]
    var isCollapsed: Bool
    /// More rows than `TaskPanelLayout.maxRows`: they scroll inside a list of that height.
    var scrollsRows: Bool
    /// Panel rect in map coordinates (before any live drag).
    var frame: CGRect
    var isAutoPositioned: Bool
}

/// Geometry of the Favorites panel: same look and sizes as the Tasks panel
/// (`TaskPanelLayout`), no footer. Automatic position: below the Tasks
/// panel when that one is shown, else where the Tasks panel would be.
enum FavoritesPanelLayout {
    /// Space between the Tasks panel and the Favorites panel below it.
    static let gap: CGFloat = 12

    static func isVisible(_ map: MindMap) -> Bool {
        map.trees.contains { $0.allNodes.contains(where: \.isFavorite) }
    }

    static func size(rows: Int, isCollapsed: Bool) -> CGSize {
        TaskPanelLayout.size(visibleRows: min(rows, TaskPanelLayout.maxRows), hasFooter: false,
                             isCollapsed: isCollapsed)
    }

    /// Frame of a panel the user dragged somewhere, without building its
    /// rows (topics keep clear of it); nil when automatic or hidden.
    static func fixedFrame(map: MindMap) -> CGRect? {
        guard let state = map.favoritesPanel, let origin = state.position, isVisible(map) else { return nil }
        return CGRect(origin: origin, size: size(rows: map.favorites.count, isCollapsed: state.isCollapsed))
    }

    /// Builds the panel for `map` (nil = hidden). `tasksFrame`: the Tasks
    /// panel as drawn now, to stay clear of it.
    static func content(map: MindMap, contentBounds: CGRect, tasksFrame: CGRect?) -> FavoritesPanelContent? {
        let entries = map.favorites
        guard !entries.isEmpty else { return nil }
        let state = map.favoritesPanel ?? TaskPanelState()
        var origin = TaskPanelLayout.defaultOrigin(contentBounds: contentBounds)
        if let tasksFrame { origin.y = tasksFrame.maxY + gap }
        let size = size(rows: entries.count, isCollapsed: state.isCollapsed)
        return FavoritesPanelContent(entries: entries, isCollapsed: state.isCollapsed,
                                     scrollsRows: entries.count > TaskPanelLayout.maxRows,
                                     frame: CGRect(origin: state.position ?? origin, size: size),
                                     isAutoPositioned: state.position == nil)
    }
}
