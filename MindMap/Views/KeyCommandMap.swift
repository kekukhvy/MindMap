import SwiftUI

/// Editor actions reachable from the keyboard.
enum EditorCommand: Equatable {
    case addChild, addSibling, delete, edit, toggleCollapse, undo, redo
    case move(MoveDirection)
    /// Start editing replacing the text with the typed characters (XMind).
    case editReplacing(String)
    case zoomIn, zoomOut, zoomToFit
    case addRelationship, addBoundary
    /// Cmd+Shift+N: open the selected topic's note, or add one (XMind).
    case note
    /// Cmd+Shift+D: open the selected topic's handwritten note, or add one.
    case handwrittenNote
    /// Cmd+Shift+A: attach files to the selected topic (file picker).
    case attachFile
    /// Cmd+Option+1...4: show topics down to that level; Cmd+Option+0: expand all.
    case collapseToLevel(Int), expandAll
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
        if characters == f2, modifiers.isEmpty { return .edit }
        if modifiers == [.command, .option], let digit = Int(String(key.character)), (0...4).contains(digit) {
            return digit == 0 ? .expandAll : .collapseToLevel(digit)
        }
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
        if modifiers.contains(.command), !modifiers.contains(.option) {
            switch key.character.lowercased() {
            case "z": return modifiers.contains(.shift) ? .redo : .undo
            case "/": return .toggleCollapse
            case "=", "+": return .zoomIn
            case "-": return .zoomOut
            case "0": return .zoomToFit
            case "b" where !modifiers.contains(.shift): return .addBoundary
            case "l" where !modifiers.contains(.shift): return .addRelationship
            case "n" where modifiers.contains(.shift): return .note
            case "d" where modifiers.contains(.shift): return .handwrittenNote
            case "a" where modifiers.contains(.shift): return .attachFile
            default: return nil
            }
        }
        if modifiers.isDisjoint(with: [.command, .control, .option]), isPrintable(characters) {
            return .editReplacing(characters)
        }
        return nil
    }

    /// NSF2FunctionKey (macOS) - F2 = rename, as in XMind / Windows.
    static let f2 = "\u{F705}"

    private static func isPrintable(_ characters: String) -> Bool {
        guard characters.count == 1, let scalar = characters.unicodeScalars.first else { return false }
        if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return false
        }
        // Private-use range = function keys on macOS (arrows, F-keys...).
        return !(0xE000...0xF8FF).contains(scalar.value)
    }
}
