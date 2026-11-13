import SwiftUI

/// Expanding / collapsing keeps the toggled topic where it is on screen
/// (WP17): after the relayout the viewport shifts by the topic's move, in
/// the same animation as the layout change, so the topic stays still
/// while the rest of the map flows around it.
extension EditorController {
    /// Layout changes and the matching viewport shift animate together.
    static let relayoutAnimation = Animation.snappy(duration: 0.25)

    /// Runs `change` keeping `anchor` at the same screen position; if it
    /// becomes hidden, its nearest ancestor visible before and after.
    func keepingOnScreen(_ anchor: UUID?, _ change: () -> Void) {
        guard let anchor else {
            withAnimation(Self.relayoutAnimation) { change() }
            return
        }
        var chain = [anchor]
        while let parent = model.map.parentID(of: chain[chain.count - 1]) { chain.append(parent) }
        let before = scene.layout.frames
        withAnimation(Self.relayoutAnimation) {
            change()
            let after = scene.layout.frames
            guard let id = chain.first(where: { before[$0] != nil && after[$0] != nil }),
                  let old = before[id], let new = after[id] else { return }
            viewport.offset.x += (old.midX - new.midX) * viewport.scale
            viewport.offset.y += (old.midY - new.midY) * viewport.scale
        }
    }
}
