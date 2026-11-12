import Combine
import Foundation

extension UndoManager {
    /// Changes of `manager`'s stacks (group closed, undo, redo) delivered on
    /// the main run loop, for refreshing Undo/Redo button state.
    ///
    /// Deliberately NOT `NSUndoManagerCheckpoint`: `canUndo` / `canRedo`
    /// themselves post a checkpoint, so two views refreshing their state on
    /// checkpoints ping-pong forever (100% CPU on the main thread; found with
    /// the handwriting editor open over the map).
    static func changes(of manager: UndoManager?) -> AnyPublisher<Notification, Never> {
        let center = NotificationCenter.default
        return Publishers.MergeMany(
            center.publisher(for: .NSUndoManagerDidCloseUndoGroup),
            center.publisher(for: .NSUndoManagerDidUndoChange),
            center.publisher(for: .NSUndoManagerDidRedoChange)
        )
        .filter { [weak manager] in manager != nil && $0.object as AnyObject? === manager }
        .receive(on: RunLoop.main)
        .eraseToAnyPublisher()
    }
}
