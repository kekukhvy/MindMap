import Foundation

/// Pencil barrel double-tap in a handwritten note: switches the note's
/// drawing tool as the user's setting says (Settings > Apple Pencil).
/// Tools are compared by identity (`Tool`: the tool picker item identifier).
enum NotePencilPolicy {
    /// The tool the tap selects, nil = leave the tool as it is.
    /// - "Switch between current tool and eraser": the eraser, or back from
    ///   it to the tool used before (`fallback` when there is none).
    /// - "Switch between current tool and last used": the tool used before.
    /// - Other settings are not a tool switch (palettes, shortcut, off): the
    ///   tool picker or the system handles them.
    static func tool<Tool: Equatable>(preference: PencilPreference, current: Tool, previous: Tool?, eraser: Tool,
                                      fallback: Tool) -> Tool? {
        switch preference {
        case .switchEraser:
            guard current == eraser else { return eraser }
            return previous.flatMap { $0 == eraser ? nil : $0 } ?? fallback
        case .switchPrevious:
            return previous
        case .ignore, .showColorPalette, .showInkAttributes, .showContextualPalette, .runSystemShortcut, .other:
            return nil
        }
    }

    /// PencilKit's tool picker switches the tool itself when its own Pencil
    /// interaction receives the tap. The note switches only if the picker
    /// did not change for that tap (`toolChangedAt` and `tapAt`: system
    /// uptime), so a tap never switches twice.
    static func shouldSwitch(toolChangedAt: TimeInterval?, tapAt: TimeInterval) -> Bool {
        guard let toolChangedAt else { return true }
        return toolChangedAt < tapAt
    }
}
