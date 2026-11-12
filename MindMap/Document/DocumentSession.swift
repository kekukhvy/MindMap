#if os(iOS)
import Observation
import UIKit

/// The document of one iPad window. At launch a window reopens its own
/// previous document (scene storage), else — first window only — the last
/// opened document, else creates a new blank map; it never shows a document
/// browser. Operations run one at a time in request order.
@MainActor
@Observable
final class DocumentSession {
    private(set) var document: MindMapUIDocument?
    private(set) var title = ""
    private(set) var isWorking = false
    /// Error / info text shown as an alert.
    var message: String?
    /// Presents the document picker (toolbar or File › Open…).
    var isImporting = false

    /// Window undo manager (editor + system Edit menu); every document of
    /// the window adopts it, which drives UIDocument's dirty state/autosave.
    @ObservationIgnored private weak var windowUndoManager: UndoManager?
    /// Receives the bookmark of each opened document (scene storage).
    @ObservationIgnored var onOpen: ((Data?) -> Void)?

    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var pending = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var scopedURL: URL?
    /// Map of a document this window just created; it is deleted when the
    /// window switches away while it is still unchanged (no "Untitled" litter).
    @ObservationIgnored private var blankMap: MindMap?
    @ObservationIgnored private var stateObserver: NSObjectProtocol?

    /// Documents open in any window (key -> session), to never edit one
    /// file from two windows.
    private static var openDocuments: [String: ObjectIdentifier] = [:]
    private static var launchRestoreClaimed = false
    static var store = LastDocumentStore(defaults: LaunchEnvironment.isTesting
                                         ? UserDefaults(suiteName: "com.kekukh.MindMap.tests") ?? .standard
                                         : .standard)

    #if DEBUG
    struct WeakSession { weak var session: DocumentSession? }
    /// Debug-only registry for in-app tests.
    static var debugInstances: [WeakSession] = []
    init() { Self.debugInstances.append(WeakSession(session: self)) }
    #endif

    // MARK: Requests

    /// Launch: scene's own document, else the last document (first window
    /// of the process only), else a new map.
    func start(sceneBookmark: Data?) {
        guard !started else { return }
        started = true
        enqueue { await self.launch(sceneBookmark: sceneBookmark) }
    }

    func open(_ url: URL) {
        enqueue { _ = await self.openNow(url, reportErrors: true) }
    }

    func newMap() {
        enqueue { await self.createNow() }
    }

    func rename(to name: String) {
        enqueue { await self.renameNow(name) }
    }

    func adopt(_ undoManager: UndoManager?) {
        guard let undoManager, undoManager !== windowUndoManager else { return }
        windowUndoManager = undoManager
        if let document {
            undoManager.removeAllActions()
            document.undoManager = undoManager
        }
    }

    /// Window became active: its document is the one to reopen next launch.
    func didBecomeActive() {
        guard let url = document?.fileURL else { return }
        Task { await self.remember(url) }
    }

    /// Window inactive / in background: write pending changes now.
    func saveIfNeeded() {
        guard let document, document.hasUnsavedChanges else { return }
        document.autosave(completionHandler: nil)
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        pending += 1
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await operation()
            self.pending -= 1
        }
    }

    // MARK: Operations

    private func launch(sceneBookmark: Data?) async {
        let mayRestoreLast = !Self.launchRestoreClaimed && !LaunchEnvironment.isTesting
        Self.launchRestoreClaimed = true
        // A document from Files (onOpenURL) is already queued behind.
        guard pending == 1 else { return }
        if let sceneBookmark, let url = try? SystemBookmarkCoder().resolve(sceneBookmark).url,
           LastDocumentStore.itemExists(url), await openNow(url, reportErrors: false) {
            return
        }
        if mayRestoreLast, let url = Self.store.resolve(roots: await DocumentLocations.roots()),
           await openNow(url, reportErrors: false) {
            return
        }
        await createNow()
    }

    private func openNow(_ url: URL, reportErrors: Bool) async -> Bool {
        let key = LaunchEnvironment.key(url)
        if let current = document, LaunchEnvironment.key(current.fileURL) == key { return true }
        let name = url.deletingPathExtension().lastPathComponent
        if let owner = Self.openDocuments[key], owner != ObjectIdentifier(self) {
            if reportErrors { message = "“\(name)” is already open in another window." }
            return false
        }
        isWorking = true
        defer { isWorking = false }
        let scoped = url.startAccessingSecurityScopedResource()
        let opened = MindMapUIDocument(fileURL: url)
        guard await opened.open() else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            if reportErrors { message = "“\(name)” could not be opened." }
            return false
        }
        await closeCurrent()
        await install(opened, scopedURL: scoped ? url : nil, blank: false)
        return true
    }

    private func createNow() async {
        isWorking = true
        defer { isWorking = false }
        await closeCurrent()
        do {
            let url = try await DocumentLocations.newDocumentURL()
            let created = MindMapUIDocument(fileURL: url)
            guard await created.save(to: url, for: .forCreating) else { throw CocoaError(.fileWriteUnknown) }
            await install(created, scopedURL: nil, blank: true)
        } catch {
            message = "A new map could not be created (\(error.localizedDescription))."
        }
    }

    private func install(_ opened: MindMapUIDocument, scopedURL: URL?, blank: Bool) async {
        if let windowUndoManager {
            windowUndoManager.removeAllActions()
            opened.undoManager = windowUndoManager
        }
        document = opened
        title = opened.fileURL.deletingPathExtension().lastPathComponent
        self.scopedURL = scopedURL
        blankMap = blank ? opened.model.map : nil
        Self.openDocuments[LaunchEnvironment.key(opened.fileURL)] = ObjectIdentifier(self)
        stateObserver = NotificationCenter.default.addObserver(
            forName: UIDocument.stateChangedNotification, object: opened, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.documentStateChanged() }
        }
        onOpen?(try? SystemBookmarkCoder().bookmark(for: opened.fileURL))
        await remember(opened.fileURL)
    }

    private func documentStateChanged() {
        guard let document else { return }
        if document.documentState.contains(.inConflict) { document.resolveConflictsKeepingCurrent() }
        if document.documentState.contains(.savingError) {
            message = "Changes to “\(title)” could not be saved."
        }
    }

    /// Saves and closes the current document; an unchanged map this window
    /// created is deleted instead.
    private func closeCurrent() async {
        guard let current = document else { return }
        let url = current.fileURL
        let discard = blankMap != nil && current.model.map == blankMap
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
        stateObserver = nil
        Self.openDocuments[LaunchEnvironment.key(url)] = nil
        document = nil
        blankMap = nil
        windowUndoManager?.removeAllActions()
        current.undoManager = UndoManager()
        _ = await current.close()
        if discard { await Self.removeItem(at: url) }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    private func renameNow(_ rawName: String) async {
        guard let current = document else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            message = "“\(rawName)” is not a valid name."
            return
        }
        let old = current.fileURL
        let new = old.deletingLastPathComponent().appendingPathComponent(name)
            .appendingPathExtension(old.pathExtension)
        guard LaunchEnvironment.key(new) != LaunchEnvironment.key(old) else { return }
        guard !FileManager.default.fileExists(atPath: new.path) else {
            message = "A map named “\(name)” already exists there."
            return
        }
        do {
            try await Self.moveItem(at: old, to: new)
        } catch {
            message = "The map could not be renamed (\(error.localizedDescription))."
            return
        }
        Self.openDocuments[LaunchEnvironment.key(old)] = nil
        Self.openDocuments[LaunchEnvironment.key(new)] = ObjectIdentifier(self)
        title = name
        blankMap = nil
        onOpen?(try? SystemBookmarkCoder().bookmark(for: new))
        await remember(new)
    }

    private func remember(_ url: URL) async {
        Self.store.remember(url, roots: await DocumentLocations.roots())
    }

    // MARK: File coordination (off the main thread)

    private static func moveItem(at source: URL, to destination: URL) async throws {
        try await Task.detached {
            var coordinationError: NSError?
            var moveError: Error?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(writingItemAt: source, options: .forMoving,
                                   writingItemAt: destination, options: .forReplacing,
                                   error: &coordinationError) { from, to in
                do {
                    coordinator.item(at: from, willMoveTo: to)
                    try FileManager.default.moveItem(at: from, to: to)
                    coordinator.item(at: from, didMoveTo: to)
                } catch { moveError = error }
            }
            if let error = coordinationError ?? moveError { throw error }
        }.value
    }

    private static func removeItem(at url: URL) async {
        await Task.detached {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: nil) { target in
                try? FileManager.default.removeItem(at: target)
            }
        }.value
    }
}
#endif
