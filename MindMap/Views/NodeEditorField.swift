import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Inline text editor of a topic. Return / Esc / focus loss commit,
/// Shift+Return / Option+Return insert a line break (multi-line topics),
/// Tab commits and adds a child (XMind). New topics start with all text
/// selected; typing on a selected topic starts with the caret at the end.
struct NodeEditorField: View {
    @Bindable var editor: EditorController
    let nodeID: UUID
    let font: Font
    let textColor: Color
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: Binding(get: { editor.draftText },
                                    set: { editor.updateDraft($0, editing: nodeID) }),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(textColor)
            .multilineTextAlignment(.center)
            .lineLimit(1...NodeMeasurer.maxLines)
            .focused($isFocused)
            .onSubmit { editor.commitEditing(ifEditing: nodeID) }
            .onKeyPress(.return, phases: .down) { press in
                let modifiers = press.modifiers
                if editor.handleEditorReturn(shift: modifiers.contains(.shift), option: modifiers.contains(.option),
                                             editing: nodeID) {
                    insertLineBreak()
                }
                return .handled
            }
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
            .task { await acquireFocus() }
    }

    /// Makes the field first responder right away (typing replaces the
    /// selected placeholder). A focus request made while the canvas is still
    /// handling the key press / click that created the topic can be dropped
    /// by SwiftUI (the canvas stays first responder, keys are lost), so the
    /// request repeats until the field really has focus.
    private func acquireFocus() async {
        for _ in 0..<40 {
            isFocused = true
            try? await Task.sleep(for: .milliseconds(25))
            if Task.isCancelled { return }
            if isFocused { break }
        }
        #if DEBUG
        NodeEditorField.debugFocusLog.append(isFocused)
        #endif
        guard isFocused else { return }
        applyInitialSelection(selectAll: editor.editSelectsAll)
    }

    #if DEBUG
    /// Focus outcome of each editor (real-app focus probe).
    @MainActor static var debugFocusLog: [Bool] = []
    #endif

    /// Inserts "\n" at the caret of the focused field (replacing a selection).
    private func insertLineBreak() {
        #if os(macOS)
        // The key window's field editor (NSApp.keyWindow can be nil while
        // the app is not frontmost, e.g. a window made key by the tests).
        let window = editor.hostWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: \.isKeyWindow)
        if let fieldEditor = window?.firstResponder as? NSTextView {
            fieldEditor.insertNewlineIgnoringFieldEditor(nil)
        } else {
            NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
        }
        #else
        UIApplication.shared.sendAction(#selector(UIKeyInput.insertText(_:)), to: nil, from: "\n" as NSString, for: nil)
        #endif
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
