import SwiftUI
import UniformTypeIdentifiers

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
    /// Off on a read-only map (WP15): the text can be selected and copied only.
    var isEditable = true
    /// Called synchronously for every user edit (before SwiftUI's next
    /// update), so the document has the text even if the window closes at
    /// once (empty notes are removed on close).
    var onEdit: ((String) -> Void)?
    /// A pasted / dropped image: stores it and returns the link to insert
    /// (nil = refused, e.g. a locked note).
    var imageLink: ((Data) -> String?)?

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
    var imageLink: ((Data) -> String?)?

    /// Puts the image's link on its own line at `range` (the selection by default).
    /// False when the image was refused (locked note, not an image).
    @discardableResult
    func insertImage(_ data: Data, at range: NSRange? = nil) -> Bool {
        guard isEditable, let link = imageLink?(data) else { return false }
        let result = NoteImage.inserting(link, into: string, selection: range ?? selectedRange())
        string = result.text
        setSelectedRange(NSRange(location: result.caret, length: 0))
        didChangeText()
        return true
    }

    override func paste(_ sender: Any?) {
        if isEditable, let data = NoteImagePasteboard.imageData(.general), insertImage(data) { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isEditable && NoteImagePasteboard.containsImage(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isEditable && NoteImagePasteboard.containsImage(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isEditable, let data = NoteImagePasteboard.imageData(sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        insertImage(data, at: NSRange(location: index, length: 0))
        return true
    }

    @objc func undo(_ sender: Any?) {
        if documentUndoManager?.canUndo == true { documentUndoManager?.undo() }
    }

    @objc func redo(_ sender: Any?) {
        if documentUndoManager?.canRedo == true { documentUndoManager?.redo() }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(paste(_:)) where isEditable && NoteImagePasteboard.containsImage(.general):
            return true
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
        textView.registerForDraggedTypes(textView.registeredDraggedTypes + [.fileURL, .png, .tiff])
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
        if focusOnAppear, isEditable, !context.coordinator.didFocus, let window = textView.window {
            context.coordinator.didFocus = true
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    private func apply(to textView: NoteTextView) {
        textView.documentUndoManager = undoManager
        textView.imageLink = imageLink
        let size = Self.fontSize(monospaced: monospaced)
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFont.systemFont(ofSize: size)
        if textView.font != font { textView.font = font }
        textView.textColor = .textColor
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
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
final class NoteUITextView: UITextView, UIDropInteractionDelegate {
    weak var documentUndoManager: UndoManager?
    var imageLink: ((Data) -> String?)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addInteraction(UIDropInteraction(delegate: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Puts the image's link on its own line at `range` (the selection by default).
    /// False when the image was refused (locked note, not an image).
    @discardableResult
    func insertImage(_ data: Data, at range: NSRange? = nil) -> Bool {
        guard isEditable, let link = imageLink?(data) else { return false }
        let result = NoteImage.inserting(link, into: text, selection: range ?? selectedRange)
        text = result.text
        selectedRange = NSRange(location: result.caret, length: 0)
        delegate?.textViewDidChange?(self)
        return true
    }

    override func paste(_ sender: Any?) {
        if isEditable, let data = NoteImagePasteboard.imageData, insertImage(data) { return }
        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, NoteImagePasteboard.containsImage { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        isEditable && session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        guard let provider = session.items.first(where: {
            $0.itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        })?.itemProvider else { return }
        let point = session.location(in: self)
        NoteImagePasteboard.loadImageData(from: provider) { data in
            guard let data else { return }
            DispatchQueue.main.async {
                let position = self.closestPosition(to: point) ?? self.endOfDocument
                let index = self.offset(from: self.beginningOfDocument, to: position)
                self.insertImage(data, at: NSRange(location: index, length: 0))
            }
        }
    }
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
        if focusOnAppear, isEditable, !context.coordinator.didFocus, textView.window != nil {
            context.coordinator.didFocus = true
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
                textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
            }
        }
    }

    private func apply(to textView: NoteUITextView) {
        textView.documentUndoManager = undoManager
        textView.imageLink = imageLink
        let size = Self.fontSize(monospaced: monospaced)
        let font = monospaced ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : UIFont.systemFont(ofSize: size)
        if textView.font != font { textView.font = font }
        textView.textColor = .label
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
    }
}

extension MarkdownTextView.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        parent.onEdit?(textView.text)
        if parent.text != textView.text { parent.text = textView.text }
    }
}
#endif
