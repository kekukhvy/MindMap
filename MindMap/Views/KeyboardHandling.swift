import SwiftUI

/// Hardware keyboard shortcuts on the focused canvas (macOS and iPad).
/// Keys are ignored while a topic is being edited (the text field has focus).
struct KeyboardHandling: ViewModifier {
    let editor: EditorController

    func body(content: Content) -> some View {
        content.onKeyPress(phases: [.down, .repeat]) { press in
            guard editor.editingID == nil, editor.labelEditing == nil,
                  let command = KeyCommandMap.command(key: press.key, modifiers: press.modifiers,
                                                      characters: press.characters) else {
                return .ignored
            }
            if press.phase == .repeat, !command.isRepeatable { return .ignored }
            return editor.perform(command) ? .handled : .ignored
        }
    }
}

extension View {
    func mindMapKeyboard(_ editor: EditorController) -> some View {
        modifier(KeyboardHandling(editor: editor))
    }
}
