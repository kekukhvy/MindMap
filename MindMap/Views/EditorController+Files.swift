import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where imported files go.
enum FileImportDestination: Equatable {
    /// Attached to this topic.
    case topic(UUID)
    /// Empty canvas (screen point): a new floating topic per file, named
    /// after it (a drop is a spatial gesture; attaching to a far-away
    /// selected topic would be invisible).
    case canvas(CGPoint)
}

/// File attachments: picker, drag & drop, paste (copies happen off the
/// main thread, then each file is one undo step).
extension EditorController {
    /// "Attach File…": shows the file picker for `id` (default: selection).
    func beginAttachFile(to id: UUID? = nil) {
        commitEditing()
        guard let target = id ?? selectedID, model.map.node(withID: target) != nil else { return }
        select(target)
        fileImportTarget = target
        isFileImporterPresented = true
    }

    /// Picker result: copies the files and attaches them to the picker's topic.
    func attachPickedFiles(_ result: Result<[URL], Error>) {
        guard let target = fileImportTarget else { return }
        fileImportTarget = nil
        switch result {
        case let .success(urls): importFiles(urls, to: .topic(target))
        case let .failure(error): fileImportError = error.localizedDescription
        }
    }

    func importFiles(_ urls: [URL], to destination: FileImportDestination,
                     completion: (() -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        AttachmentImporter.copy(urls, into: model.attachmentStore.scratchDirectory) { [weak self] results in
            self?.finishImport(results, to: destination)
            completion?()
        }
    }

    /// Dropped / pasted items.
    func importItems(_ providers: [NSItemProvider], to destination: FileImportDestination,
                     completion: (() -> Void)? = nil) {
        let files = providers.filter(AttachmentImporter.isFileLike)
        guard !files.isEmpty else { return }
        AttachmentImporter.load(files, into: model.attachmentStore.scratchDirectory) { [weak self] results in
            self?.finishImport(results, to: destination)
            completion?()
        }
    }

    /// Adds the copied files (one undo step each) and reports failures.
    func finishImport(_ results: [Result<ImportedFile, Error>], to destination: FileImportDestination) {
        commitEditing()
        var failures: [String] = []
        var lastTopic: UUID?
        var offset: CGFloat = 0
        for result in results {
            switch result {
            case let .success(file):
                switch destination {
                case let .topic(id):
                    if model.addFile(file, to: id, undoManager: undoManager) != nil {
                        lastTopic = id
                    } else {
                        failures.append(file.originalName)
                    }
                case let .canvas(point):
                    var position = viewport.toMap(point)
                    position.y += offset
                    if let added = model.addFileTopic(file, at: position, undoManager: undoManager) {
                        lastTopic = added.topic
                        offset += 56
                    } else {
                        failures.append(file.originalName)
                    }
                }
            case let .failure(error):
                failures.append(error.localizedDescription)
            }
        }
        if let lastTopic { select(lastTopic) }
        if !failures.isEmpty {
            fileImportError = "Could not attach:\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: Drag & drop

    /// Topic under a screen point (file drops).
    func topic(atScreen point: CGPoint) -> UUID? {
        DropTargetFinder.target(at: viewport.toMap(point), frames: scene.layout.frames, excluding: [])
    }

    /// Files dropped at `point` (screen): onto a topic = attach, on empty
    /// canvas = new floating topic per file.
    @discardableResult
    func dropFiles(_ providers: [NSItemProvider], at point: CGPoint) -> Bool {
        fileDropTargetID = nil
        guard providers.contains(where: AttachmentImporter.isFileLike) else { return false }
        let destination: FileImportDestination = topic(atScreen: point).map { .topic($0) } ?? .canvas(point)
        importItems(providers, to: destination)
        return true
    }

    // MARK: Paste

    /// Pastes files from the clipboard onto `id` (default: selection; no
    /// selection = floating topics at the view center).
    func pasteFiles(to id: UUID? = nil) {
        let destination: FileImportDestination = (id ?? selectedID).map { .topic($0) }
            ?? .canvas(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        #if os(macOS)
        let urls = PasteboardFiles.fileURLs()
        if !urls.isEmpty { return importFiles(urls, to: destination) }
        #endif
        let providers = PasteboardFiles.itemProviders()
        if providers.contains(where: AttachmentImporter.isFileLike) {
            importItems(providers, to: destination)
        } else {
            fileImportError = "The clipboard contains no files."
        }
    }
}

/// Files on the system clipboard.
enum PasteboardFiles {
    #if os(macOS)
    static func fileURLs() -> [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    #endif

    static func itemProviders() -> [NSItemProvider] {
        #if os(macOS)
        (NSPasteboard.general.pasteboardItems ?? []).compactMap { item in
            guard let type = item.types.first(where: { $0 != .string }), let data = item.data(forType: type) else {
                return nil
            }
            let provider = NSItemProvider(item: data as NSData, typeIdentifier: type.rawValue)
            provider.suggestedName = "Pasted Item"
            return provider
        }
        #else
        UIPasteboard.general.itemProviders
        #endif
    }
}
