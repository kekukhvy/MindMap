import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Store actions of one open map (WP14b): Rename (library title), Import to
/// Library, Move to Library, Export as File…, Duplicate. Used by the store
/// badge, the macOS File menu and the iPad documents menu; presented by
/// `MapStorageModifier` on the map's view.
@MainActor
@Observable
final class MapStorageController {
    @ObservationIgnored private(set) weak var editor: EditorController?
    @ObservationIgnored var service: LibraryService = .shared

    var isRenaming = false
    var renameDraft = ""
    var isExporting = false
    var exportFile: MapPackageFile?
    var exportName = ""
    /// Move to Library… asks first (trash or keep the original file).
    var isConfirmingMove = false
    /// Error / info alert.
    var message: String?

    init(editor: EditorController) {
        self.editor = editor
        Self.controllers[ObjectIdentifier(editor.model)] = Weak(controller: self)
    }

    private struct Weak { weak var controller: MapStorageController? }
    private static var controllers: [ObjectIdentifier: Weak] = [:]

    /// The controller of an open map (iPad documents menu).
    static func controller(for model: MindMapModel) -> MapStorageController? {
        controllers[ObjectIdentifier(model)]?.controller
    }

    var documentURL: URL? { editor?.documentURL }
    /// Library map ID of this document (nil = a `.mindmap` file).
    var libraryID: UUID? { service.libraryMapID(of: documentURL) }
    var isLibraryMap: Bool { libraryID != nil }

    /// Library: the map's title; file: its file name.
    var title: String {
        if isLibraryMap, let model = editor?.model, model.map.title != nil || !model.lock.isMapLocked {
            return LibraryTitle.title(of: model.map)
        }
        return documentURL.map(MapPaths.displayName(of:)) ?? UntitledName.base
    }

    // MARK: Rename

    func beginRename() {
        renameDraft = title
        isRenaming = true
    }

    /// Library map: sets the title (one undo step) and renames the package
    /// (window title). File: renames the file (iPad; macOS uses File ▸ Rename…).
    func commitRename() {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let editor else { return }
        if let id = libraryID {
            if !editor.model.lock.isMapLocked { editor.model.setMapTitle(name, undoManager: editor.undoManager) }
            renamePackage(of: id, to: name)
        } else {
            #if os(iOS)
            documentURL.flatMap(DocumentSession.session(showing:))?.rename(to: name)
            #endif
        }
    }

    private func renamePackage(of id: UUID, to title: String) {
        #if os(iOS)
        if let url = documentURL, let session = DocumentSession.session(showing: url) {
            session.rename(to: MapPaths.fileNameBase(forTopic: title))
            return
        }
        #endif
        do {
            try service.sync.cache.renamePackage(of: id, toTitle: title)
        } catch {
            message = "The map could not be renamed (\(error.localizedDescription))."
        }
    }

    /// The package was renamed outside (macOS File ▸ Rename… / title bar):
    /// a library map takes the new name as its title.
    func documentURLDidChange(to url: URL?) {
        guard let url, service.libraryMapID(of: url) != nil, let editor, !editor.model.lock.isMapLocked else { return }
        let base = MapPaths.displayName(of: url)
        let current = LibraryTitle.title(of: editor.model.map)
        guard MapPaths.fileNameBase(forTopic: current) != base else { return }
        editor.model.setMapTitle(base, undoManager: editor.undoManager)
    }

    // MARK: Import / Move / Export / Duplicate

    /// Import to Library: copies the map into the library (the file stays
    /// open); the library copy opens in a new tab (macOS) / stays for later (iPad).
    func importToLibrary() {
        guard !isLibraryMap else { return }
        Task {
            guard let source = await currentContentURL() else {
                message = "Save the map first."
                return
            }
            do {
                let summary = try service.store.importPackage(at: source, title: title)
                message = "“\(summary.title)” was copied to the library. Open it from File ▸ Open from Library…"
            } catch {
                message = "The map could not be copied to the library (\(error.localizedDescription))."
            }
        }
    }

    func beginMove() {
        guard !isLibraryMap else { return }
        isConfirmingMove = true
    }

    /// Move to Library: copies the map into the library, shows the library
    /// map instead of the file and, if asked, moves the file to the Trash.
    func moveToLibrary(trashOriginal: Bool) {
        guard !isLibraryMap else { return }
        Task {
            guard let source = await currentContentURL() else {
                message = "Save the map first."
                return
            }
            let original = documentURL
            do {
                let summary = try service.store.importPackage(at: source, title: title)
                guard let url = service.store.packageURL(for: summary.location) else { return }
                guard await openMap(url, replacing: original) else { return }
                if trashOriginal, let original { try MapPackageIO.trash(original) }
            } catch {
                message = "The map could not be moved to the library (\(error.localizedDescription))."
            }
        }
    }

    func beginExport() {
        guard let id = libraryID else { return }
        Task {
            _ = await currentContentURL()
            do {
                exportFile = MapPackageFile(wrapper: try service.store.exportWrapper(id))
                exportName = MapPaths.fileNameBase(forTopic: title)
                isExporting = true
            } catch {
                message = "The map could not be exported (\(error.localizedDescription))."
            }
        }
    }

    func finishExport(_ result: Result<URL, Error>) {
        exportFile = nil
        if case let .failure(error) = result, (error as? CocoaError)?.code != .userCancelled {
            message = "The map could not be exported (\(error.localizedDescription))."
        }
    }

    /// Library: a copy in the library; file: a copy next to it (macOS:
    /// the standard untitled duplicate).
    func duplicate() {
        Task {
            guard let source = await currentContentURL() else { return }
            do {
                if let id = libraryID {
                    let summary = try service.store.duplicateMap(id)
                    if let url = service.store.packageURL(for: summary.location) { await openMap(url, replacing: nil) }
                    return
                }
                #if os(macOS)
                hostDocument?.duplicate(nil)
                #else
                let copy = try Self.fileCopy(of: source)
                await openMap(copy, replacing: nil)
                #endif
            } catch {
                message = "The map could not be duplicated (\(error.localizedDescription))."
            }
        }
    }

    #if os(iOS)
    /// "<name> copy.mindmap" next to the file, else in the app's documents.
    private static func fileCopy(of source: URL) throws -> URL {
        let wrapper = try MapPackageIO.read(source)
        let sibling = MapPackageIO.copyURL(for: source, in: source.deletingLastPathComponent())
        do {
            try MapPackageIO.write(wrapper, to: sibling)
            return sibling
        } catch {
            let copy = MapPackageIO.copyURL(for: source, in: DocumentLocations.localDocuments)
            try FileManager.default.createDirectory(at: DocumentLocations.localDocuments, withIntermediateDirectories: true)
            try MapPackageIO.write(wrapper, to: copy)
            return copy
        }
    }
    #endif

    // MARK: Platform

    #if os(macOS)
    private var hostDocument: NSDocument? {
        if let document = editor?.hostWindow?.windowController?.document as? NSDocument { return document }
        return documentURL.flatMap(MapTabOpener.document(for:))
    }
    #endif

    /// Saves pending changes; the package holding the current content
    /// (macOS untitled document: its autosave file).
    private func currentContentURL() async -> URL? {
        #if os(macOS)
        guard let document = hostDocument else { return documentURL }
        if document.isDocumentEdited || document.fileURL == nil {
            _ = await withCheckedContinuation { continuation in
                document.autosave(withImplicitCancellability: false) { continuation.resume(returning: $0) }
            }
        }
        return document.fileURL ?? document.autosavedContentsFileURL
        #else
        guard let url = documentURL else { return nil }
        if let session = DocumentSession.session(showing: url) { _ = await session.saveNow() }
        return url
        #endif
    }

    /// Opens `url` as a tab of this window (macOS; then closes this map if
    /// `original` is set) / in this window (iPad). False if it failed.
    @discardableResult
    private func openMap(_ url: URL, replacing original: URL?) async -> Bool {
        #if os(macOS)
        let window = editor?.hostWindow
        let document = original == nil ? nil : hostDocument
        let failure: String? = await withCheckedContinuation { continuation in
            MapHost.open(url, from: window) { continuation.resume(returning: $0) }
        }
        if let failure {
            message = failure
            return false
        }
        document?.close()
        return true
        #else
        guard let current = documentURL, let session = DocumentSession.session(showing: current) else { return false }
        return await session.openAndWait(url)
        #endif
    }
}

/// A map package for Export as File… (`fileExporter`).
struct MapPackageFile: FileDocument {
    static var readableContentTypes: [UTType] { [.mindMap] }
    /// Read once, then only written out by the exporter.
    nonisolated(unsafe) let wrapper: FileWrapper

    init(wrapper: FileWrapper) {
        self.wrapper = wrapper
    }

    init(configuration: ReadConfiguration) throws {
        wrapper = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        wrapper
    }
}

/// Alerts / panels of `MapStorageController` on a map view.
struct MapStorageModifier: ViewModifier {
    @Bindable var storage: MapStorageController

    func body(content: Content) -> some View {
        content
            .alert(storage.isLibraryMap ? "Rename Map" : "Rename File", isPresented: $storage.isRenaming) {
                TextField("Name", text: $storage.renameDraft)
                Button("Rename") { storage.commitRename() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Move “\(storage.title)” to the Library?", isPresented: $storage.isConfirmingMove) {
                Button("Move and Trash File", role: .destructive) { storage.moveToLibrary(trashOriginal: true) }
                Button("Move and Keep File") { storage.moveToLibrary(trashOriginal: false) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The map is copied into the iCloud library and opens from there. The original file can go "
                    + "to the Trash or stay where it is (it is no longer updated).")
            }
            .alert("Map", isPresented: Binding(get: { storage.message != nil },
                                               set: { if !$0 { storage.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(storage.message ?? "")
            }
            .background {
                Color.clear.fileExporter(isPresented: $storage.isExporting, document: storage.exportFile,
                                         contentType: .mindMap, defaultFilename: storage.exportName) { result in
                    storage.finishExport(result)
                }
            }
    }
}
