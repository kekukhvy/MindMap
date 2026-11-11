import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Inline text editor of a topic. Return / Esc / focus loss commit,
/// Tab commits and adds a child (XMind). New topics start with all text
/// selected; typing on a selected topic starts with the caret at the end.
struct NodeEditorField: View {
    @Bindable var editor: EditorController
    let nodeID: UUID
    let font: Font
    let textColor: Color
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $editor.draftText)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(textColor)
            .multilineTextAlignment(.center)
            .focused($isFocused)
            .onSubmit { editor.commitEditing(ifEditing: nodeID) }
            .onKeyPress(.escape) {
                editor.commitEditing(ifEditing: nodeID)
                return .handled
            }
            .onKeyPress(.tab) {
                editor.commitEditing(ifEditing: nodeID)
                editor.addChild()
                return .handled
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { editor.commitEditing(ifEditing: nodeID) }
            }
            .task {
                isFocused = true
                try? await Task.sleep(for: .milliseconds(30))
                applyInitialSelection(selectAll: editor.editSelectsAll)
            }
    }

    private func applyInitialSelection(selectAll: Bool) {
        #if os(macOS)
        let action = selectAll ? #selector(NSResponder.selectAll(_:)) : #selector(NSResponder.moveToEndOfDocument(_:))
        NSApp.sendAction(action, to: nil, from: nil)
        #else
        if selectAll {
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
        #endif
    }
}
