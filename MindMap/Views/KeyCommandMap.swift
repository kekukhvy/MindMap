import SwiftUI

/// Editor actions reachable from the keyboard.
enum EditorCommand: Equatable {
    case addChild, addSibling, delete, edit, toggleCollapse, undo, redo
    case move(MoveDirection)
    /// Start editing replacing the text with the typed characters (XMind).
    case editReplacing(String)
    case zoomIn, zoomOut, zoomToFit
    case addRelationship, addBoundary
    /// Esc: cancel relationship/attach picking, or deselect a relationship/boundary.
    case cancel

    /// Only navigation and zoom repeat while a key is held.
    var isRepeatable: Bool {
        switch self {
        case .move, .zoomIn, .zoomOut: return true
        default: return false
        }
    }
}

/// Pure mapping of a key press (canvas focused, not editing) to a command.
enum KeyCommandMap {
    static func command(key: KeyEquivalent, modifiers rawModifiers: EventModifiers, characters: String) -> EditorCommand? {
        // Arrow keys carry .function / .numericPad on macOS: ignore those.
        let modifiers = rawModifiers.intersection([.command, .shift, .option, .control])
        if modifiers.isEmpty || modifiers == .shift {
            switch key {
            case .tab where modifiers.isEmpty: return .addChild
            case .return: return .addSibling
            case .delete, .deleteForward: return .delete
            case .space: return .edit
            case .escape where modifiers.isEmpty: return .cancel
            case .upArrow: return .move(.up)
            case .downArrow: return .move(.down)
            case .leftArrow: return .move(.left)
            case .rightArrow: return .move(.right)
            default: break
            }
        }
        if modifiers.contains(.command) {
            switch key.character.lowercased() {
            case "z": return modifiers.contains(.shift) ? .redo : .undo
            case "/": return .toggleCollapse
            case "=", "+": return .zoomIn
            case "-": return .zoomOut
            case "0": return .zoomToFit
            case "b" where !modifiers.contains(.shift): return .addBoundary
            case "l" where !modifiers.contains(.shift): return .addRelationship
            default: return nil
            }
        }
        if modifiers.isDisjoint(with: [.command, .control, .option]), isPrintable(characters) {
            return .editReplacing(characters)
        }
        return nil
    }

    private static func isPrintable(_ characters: String) -> Bool {
        guard characters.count == 1, let scalar = characters.unicodeScalars.first else { return false }
        if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return false
        }
        // Private-use range = function keys on macOS (arrows, F-keys...).
        return !(0xE000...0xF8FF).contains(scalar.value)
    }
}
