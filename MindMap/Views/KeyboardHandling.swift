import SwiftUI

/// Hardware keyboard shortcuts on the focused canvas (macOS and iPad).
/// Keys are ignored while a topic is being edited or the find field has
/// focus (keys typed into a text field inside the canvas reach this handler
/// first; see `EditorController.acceptsCanvasKeys`).
struct KeyboardHandling: ViewModifier {
    let editor: EditorController

    func body(content: Content) -> some View {
        content.onKeyPress(phases: [.down, .repeat]) { press in
            guard editor.acceptsCanvasKeys,
                  let command = KeyCommandMap.command(key: press.key, modifiers: press.modifiers,
                                                      characters: press.characters) else {
                return .ignored
            }
            if press.phase == .repeat, !command.isRepeatable { return .ignored }
            if command == .cancel, editor.palette.isRequested {
                editor.keyboardDidAct()
                return .handled
            }
            guard editor.perform(command) else { return .ignored }
            // The touch action palette goes away while the keyboard is used.
            editor.keyboardDidAct()
            return .handled
        }
    }
}

extension View {
    func mindMapKeyboard(_ editor: EditorController) -> some View {
        modifier(KeyboardHandling(editor: editor))
    }
}
