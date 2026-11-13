import CoreGraphics
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// ⌘C / ⌘X / ⌘V of topics (menus on both platforms; macOS Edit menu via
/// `onCopyCommand` / `onCutCommand` / `onPasteCommand`, iPad hardware
/// keyboard via `KeyCommandMap`). The clipboard carries the topics as
/// `TopicClipboard` JSON (paste into any map, also another window) plus a
/// tab-indented outline as plain text for other apps; pasting plain text
/// from elsewhere makes topics from its lines.
extension EditorController {
    /// Topics a copy / cut acts on: the selection (whole subtrees).
    var clipboardTargets: [UUID] { selectedItem == nil ? targets() : [] }

    var canCopyTopics: Bool { !clipboardTargets.isEmpty }

    /// Cut needs something besides the central topic.
    var canCutTopics: Bool { canEdit && !model.map.movableTopics(clipboardTargets).isEmpty }

    /// Copies the selected topics (central topic included) to the clipboard.
    @discardableResult
    func copySelection() -> Bool {
        commitEditing()
        guard let clip = model.clipboard(for: clipboardTargets) else { return false }
        TopicPasteboard.write(clip)
        return true
    }

    /// Copies, then deletes the selected topics (one "Cut" undo step).
    @discardableResult
    func cutSelection() -> Bool {
        guard requireEditable() else { return false }
        commitEditing()
        let targets = model.map.movableTopics(clipboardTargets)
        guard !targets.isEmpty, let clip = model.clipboard(for: targets) else { return false }
        TopicPasteboard.write(clip)
        let next = targets.first.flatMap(model.map.parentID(of:))
        guard model.cut(targets, undoManager: undoManager) else { return false }
        if let next, model.map.contains(next) { select(next) } else { select(nil) }
        return true
    }

    /// Whether ⌘V would paste topics, text or files.
    var canPaste: Bool { canEdit && TopicPasteboard.hasContent }

    /// ⌘V: topics (or lines of text) as children of the selected topic, else
    /// floating topics in the middle of the view; files attach as before.
    @discardableResult
    func paste() -> Bool {
        guard requireEditable() else { return false }
        commitEditing()
        if let clip = TopicPasteboard.readTopics() { return pasteTopics(clip) }
        if TopicPasteboard.hasFiles {
            pasteFiles()
            return true
        }
        if let text = TopicPasteboard.readText(), let clip = TopicClipboard(plainText: text) {
            return pasteTopics(clip)
        }
        return false
    }

    /// Inserts `clip` under the primary selection (a multi-selection pastes
    /// into its primary topic) or as floating topics at the view center;
    /// the pasted topics become the selection.
    @discardableResult
    func pasteTopics(_ clip: TopicClipboard, into parentID: UUID? = nil) -> Bool {
        let parent = parentID ?? (selectedItem == nil ? selectedID : nil)
        let center = viewport.toMap(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        var ids: [UUID] = []
        keepingOnScreen(parent) {
            ids = model.paste(clip, into: parent, at: center, undoManager: undoManager)
        }
        guard !ids.isEmpty else { return false }
        setSelection(ids, primary: ids.first)
        if let first = ids.first { reveal(first) }
        return true
    }
}

/// The system clipboard for topics (macOS NSPasteboard / iOS UIPasteboard).
enum TopicPasteboard {
    #if os(macOS)
    /// The clipboard used (tests swap in a private named pasteboard).
    nonisolated(unsafe) static var board = NSPasteboard.general
    #else
    nonisolated(unsafe) static var board = UIPasteboard.general
    #endif

    static func write(_ clip: TopicClipboard) {
        guard let data = try? clip.encoded() else { return }
        let text = clip.plainText
        #if os(macOS)
        board.clearContents()
        board.declareTypes([NSPasteboard.PasteboardType(UTType.mindMapTopics.identifier), .string], owner: nil)
        board.setData(data, forType: NSPasteboard.PasteboardType(UTType.mindMapTopics.identifier))
        board.setString(text, forType: .string)
        #else
        board.setItems([[UTType.mindMapTopics.identifier: data,
                                        UTType.utf8PlainText.identifier: text]])
        #endif
    }

    #if os(macOS)
    /// What `onCopyCommand` / `onCutCommand` hand back to SwiftUI, which
    /// rewrites the pasteboard with them: the items `write` just put there.
    static func itemProviders() -> [NSItemProvider] {
        let topicsType = NSPasteboard.PasteboardType(UTType.mindMapTopics.identifier)
        let provider = NSItemProvider()
        if let data = board.data(forType: topicsType) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.mindMapTopics.identifier,
                                                visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        if let text = board.string(forType: .string) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier,
                                                visibility: .all) { completion in
                completion(Data(text.utf8), nil)
                return nil
            }
        }
        return [provider]
    }
    #endif

    static func readTopics() -> TopicClipboard? {
        #if os(macOS)
        let data = board.data(forType: NSPasteboard.PasteboardType(UTType.mindMapTopics.identifier))
        #else
        let data = board.data(forPasteboardType: UTType.mindMapTopics.identifier)
        #endif
        return data.flatMap(TopicClipboard.decode)
    }

    static func readText() -> String? {
        #if os(macOS)
        board.string(forType: .string)
        #else
        board.hasStrings ? board.string : nil
        #endif
    }

    /// Files / images (attached on paste, WP6) rather than text.
    static var hasFiles: Bool {
        #if os(macOS)
        if board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        return board.availableType(from: [.png, .tiff, .pdf]) != nil
        #else
        return board.hasImages || board.contains(pasteboardTypes: [UTType.pdf.identifier, UTType.fileURL.identifier])
        #endif
    }

    static var hasContent: Bool {
        #if os(macOS)
        return board.availableType(from: [NSPasteboard.PasteboardType(UTType.mindMapTopics.identifier), .string]) != nil
            || hasFiles
        #else
        return board.contains(pasteboardTypes: [UTType.mindMapTopics.identifier]) || board.hasStrings || hasFiles
        #endif
    }
}
