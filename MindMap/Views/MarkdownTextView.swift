import SwiftUI

/// Plain-text Markdown editor (no rich text, no smart quotes/dashes).
/// The text view's own typing undo is off: every change is written to the
/// document through `MindMapModel.setAttachmentContent` (coalesced undo steps
/// on the DOCUMENT's undo manager), and Cmd+Z / Cmd+Shift+Z in the editor
/// undo / redo on that manager. So the map and the note share one history,
/// the document gets dirty / autosaved, and no undo action ever targets a
/// text view that is gone after its sheet / window closed.
struct MarkdownTextView {
    @Binding var text: String
    var monospaced: Bool
    /// The document's undo manager.
    var undoManager: UndoManager?
    var focusOnAppear = true
    /// Called synchronously for every user edit (before SwiftUI's next
    /// update), so the document has the text even if the window closes at
    /// once (empty notes are removed on close).
    var onEdit: ((String) -> Void)?

    final class Coordinator: NSObject {
        var parent: MarkdownTextView
        var didFocus = false
        init(_ parent: MarkdownTextView) { self.parent = parent }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Where the first character is drawn (container inset + line padding),
    /// for the empty-note placeholder.
    static var textOrigin: EdgeInsets {
        #if os(macOS)
        EdgeInsets(top: 12, leading: 19, bottom: 0, trailing: 19)
        #else
        EdgeInsets(top: 12, leading: 17, bottom: 0, trailing: 17)
        #endif
    }

    static let placeholder = "Write your note… Markdown works: # Heading, - list, **bold**"

    static func fontSize(monospaced: Bool) -> CGFloat {
        #if os(macOS)
        monospaced ? 13 : 14
        #else
        monospaced ? 15 : 17
        #endif
    }
}

#if os(macOS)
import AppKit

/// NSTextView routing Undo/Redo (Edit menu, Cmd+Z) to the document's manager.
final class NoteTextView: NSTextView {
    weak var documentUndoManager: UndoManager?

    @objc func undo(_ sender: Any?) {
        if documentUndoManager?.canUndo == true { documentUndoManager?.undo() }
    }

    @objc func redo(_ sender: Any?) {
        if documentUndoManager?.canRedo == true { documentUndoManager?.redo() }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            if let menuItem = item as? NSMenuItem, let manager = documentUndoManager {
                menuItem.title = manager.undoMenuItemTitle
            }
            return documentUndoManager?.canUndo ?? false
        case #selector(redo(_:)):
            if let menuItem = item as? NSMenuItem, let manager = documentUndoManager {
                menuItem.title = manager.redoMenuItemTitle
            }
            return documentUndoManager?.canRedo ?? false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

extension MarkdownTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let textView = NoteTextView(frame: .zero)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.string = text
        textView.delegate = context.coordinator
        scroll.documentView = textView
        apply(to: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NoteTextView else { return }
        apply(to: textView)
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        if focusOnAppear, !context.coordinator.didFocus, let window = textView.window {
            context.coordinator.didFocus = true
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    private func apply(to textView: NoteTextView) {
        textView.documentUndoManager = undoManager
        let size = Self.fontSize(monospaced: monospaced)
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFont.systemFont(ofSize: size)
        if textView.font != font { textView.font = font }
        textView.textColor = .textColor
    }
}

extension MarkdownTextView.Coordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        parent.onEdit?(textView.string)
        if parent.text != textView.string { parent.text = textView.string }
    }
}

#else
import UIKit

/// UITextView whose typing undo is not recorded; Cmd+Z / Cmd+Shift+Z act on
/// the document's undo manager instead.
final class NoteUITextView: UITextView {
    weak var documentUndoManager: UndoManager?
    private let unusedUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()

    override var undoManager: UndoManager? { unusedUndoManager }

    override var keyCommands: [UIKeyCommand]? {
        let undo = UIKeyCommand(title: "Undo", action: #selector(undoDocument), input: "z", modifierFlags: .command)
        let redo = UIKeyCommand(title: "Redo", action: #selector(redoDocument), input: "z",
                                modifierFlags: [.command, .shift])
        undo.wantsPriorityOverSystemBehavior = true
        redo.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [undo, redo]
    }

    @objc func undoDocument() {
        if documentUndoManager?.canUndo == true { documentUndoManager?.undo() }
    }

    @objc func redoDocument() {
        if documentUndoManager?.canRedo == true { documentUndoManager?.redo() }
    }
}

extension MarkdownTextView: UIViewRepresentable {
    func makeUIView(context: Context) -> NoteUITextView {
        let textView = NoteUITextView()
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.autocapitalizationType = .sentences
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.text = text
        textView.delegate = context.coordinator
        apply(to: textView)
        return textView
    }

    func updateUIView(_ textView: NoteUITextView, context: Context) {
        context.coordinator.parent = self
        apply(to: textView)
        if textView.text != text {
            let selection = textView.selectedRange
            textView.text = text
            let length = (text as NSString).length
            textView.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        }
        if focusOnAppear, !context.coordinator.didFocus, textView.window != nil {
            context.coordinator.didFocus = true
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
                textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
            }
        }
    }

    private func apply(to textView: NoteUITextView) {
        textView.documentUndoManager = undoManager
        let size = Self.fontSize(monospaced: monospaced)
        let font = monospaced ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : UIFont.systemFont(ofSize: size)
        if textView.font != font { textView.font = font }
        textView.textColor = .label
    }
}

extension MarkdownTextView.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        parent.onEdit?(textView.text)
        if parent.text != textView.text { parent.text = textView.text }
    }
}
#endif
