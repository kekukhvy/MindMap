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
    /// Library browser sheet (File › Open from Library…).
    var isShowingLibrary = false
    /// Settings sheet.
    var isShowingSettings = false
    /// Welcome screen over the open map (folder button ▸ Welcome); without
    /// a map the window shows Welcome anyway (WP13).
    var isShowingWelcome = false
    /// Welcome Tour sheet on this window's Welcome screen.
    var isShowingTour = false
    /// Maps this window showed before following map links in place (no
    /// multi-window support): Back returns to the last one.
    private(set) var backStack: [MapBackEntry] = []
    /// The window's scene session (to bring this window to the front when
    /// a link in another window points at its map).
    @ObservationIgnored weak var sceneSession: UISceneSession?

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
    /// Live sessions (find the window showing a map).
    private static var sessions: [ObjectIdentifier: WeakSession] = [:]
    /// Maps requested for new windows (map links), consumed by the next
    /// window that starts; also delivered as the scene's user activity.
    static var pendingWindowOpens: [URL] = []
    private static var launchRestoreClaimed = false
    static var store = LastDocumentStore(defaults: LaunchEnvironment.isTesting
                                         ? UserDefaults(suiteName: "com.kekukh.MindMap.tests") ?? .standard
                                         : .standard)

    struct WeakSession { weak var session: DocumentSession? }
    #if DEBUG
    /// Debug-only registry for in-app tests.
    static var debugInstances: [WeakSession] = []
    #endif

    init() {
        Self.sessions[ObjectIdentifier(self)] = WeakSession(session: self)
        #if DEBUG
        Self.debugInstances.append(WeakSession(session: self))
        #endif
    }

    // MARK: Requests

    /// Launch: scene's own document, else the last document (first window
    /// of the process only), else a new map.
    func start(sceneBookmark: Data?) {
        guard !started else { return }
        started = true
        if !Self.pendingWindowOpens.isEmpty {
            // A window opened for a map link.
            let url = Self.pendingWindowOpens.removeFirst()
            Self.launchRestoreClaimed = true
            enqueue { if await !self.openNow(url, reportErrors: true) { await self.createNow() } }
            return
        }
        enqueue { await self.launch(sceneBookmark: sceneBookmark) }
    }

    /// The scene was created for a map link (`MapLinkActivity`).
    func open(activity: NSUserActivity) {
        guard let url = MapLinkActivity.url(from: activity) else { return }
        Self.pendingWindowOpens.removeAll { LaunchEnvironment.key($0) == LaunchEnvironment.key(url) }
        open(url)
    }

    func open(_ url: URL) {
        enqueue { _ = await self.openNow(url, reportErrors: true) }
    }

    /// Opens `url` in this window once the queue gets to it.
    func openAndWait(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            enqueue { continuation.resume(returning: await self.openNow(url, reportErrors: true)) }
        }
    }

    /// Writes pending changes now (before copying the package).
    func saveNow() async -> Bool {
        guard let document, document.hasUnsavedChanges else { return true }
        return await document.save(to: document.fileURL, for: .forOverwriting)
    }

    /// The window showing the document at `url`.
    static func session(showing url: URL) -> DocumentSession? {
        openDocuments[LaunchEnvironment.key(url)].flatMap { sessions[$0]?.session }
    }

    /// The library map at `url` is being deleted: a window showing it
    /// switches to a new map first.
    static func closeLibraryMap(_ url: URL) async {
        guard let session = session(showing: url) else { return }
        await withCheckedContinuation { continuation in
            session.enqueue {
                await session.createNow()
                continuation.resume()
            }
        }
    }

    func newMap() {
        enqueue { await self.createNow() }
    }

    /// Help ▸ Welcome Tour: the Welcome screen with the tour on top.
    func showTour() {
        if document != nil { isShowingWelcome = true }
        isShowingTour = true
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

    /// Window became active: its document is the one to reopen next launch,
    /// and it reads a file changed while the app was suspended. (Not queued:
    /// `launch` expects to be the only pending operation.)
    func didBecomeActive() {
        guard let document else { return }
        Task {
            await document.revertIfOutdated()
            await self.remember(document.fileURL)
        }
    }

    /// Window inactive / in background: write pending changes now.
    func saveIfNeeded() {
        guard let document, document.hasUnsavedChanges else { return }
        document.autosave(completionHandler: nil)
    }

    // MARK: Map links

    /// Map link Go to: the map opens in its own window (a new scene) when
    /// the device supports several windows — like a new tab on the Mac;
    /// already open in a window → that window comes to the front.
    /// Otherwise this window switches to the map and Back returns.
    func openLinkedMap(_ url: URL, revealing topicID: UUID?, completion: @escaping (String?) -> Void) {
        let key = LaunchEnvironment.key(url)
        if let topicID { MapRevealCenter.shared.request(topicID, in: url) }
        if let current = document, LaunchEnvironment.key(current.fileURL) == key {
            completion(nil)
            return
        }
        // Failures of scene requests arrive later (after completion(nil)).
        if let ownerID = Self.openDocuments[key], let owner = Self.sessions[ownerID]?.session, owner !== self {
            guard let sceneSession = owner.sceneSession else {
                completion("It is already open in another window.")
                return
            }
            UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: sceneSession)) { error in
                completion(error.localizedDescription)
            }
            completion(nil)
            return
        }
        if Self.usesSeparateWindows {
            Self.pendingWindowOpens.append(url)
            let request = UISceneSessionActivationRequest(role: .windowApplication,
                                                          userActivity: MapLinkActivity.make(for: url))
            UIApplication.shared.activateSceneSession(for: request) { error in
                Self.pendingWindowOpens.removeAll { LaunchEnvironment.key($0) == key }
                completion(error.localizedDescription)
            }
            completion(nil)
            return
        }
        enqueue {
            let previous = self.document.map { MapBackEntry(url: $0.fileURL, title: self.title) }
            if await self.openNow(url, reportErrors: false) {
                if let previous { self.backStack.append(previous) }
                completion(nil)
            } else {
                completion("It could not be opened.")
            }
        }
    }

    /// Several windows (iPad multitasking). Tests: never (in-window switch).
    static var usesSeparateWindows: Bool {
        !LaunchEnvironment.isTesting && UIApplication.shared.supportsMultipleScenes
    }

    /// Back (in-window map links): reopens the previous map.
    func goBackToPreviousMap() {
        guard let entry = backStack.popLast() else { return }
        enqueue { _ = await self.openNow(entry.url, reportErrors: true) }
    }

    fileprivate func enqueue(_ operation: @escaping @MainActor () async -> Void) {
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
        let isFirstWindow = !Self.launchRestoreClaimed && !LaunchEnvironment.isTesting
        let mayRestoreLast = isFirstWindow
        Self.launchRestoreClaimed = true
        // A document from Files (onOpenURL) / a map link is already queued
        // behind or was opened.
        guard pending == 1, document == nil else { return }
        if isFirstWindow {
            // WP13: the first window starts on the Welcome screen (with the
            // tour on the very first launch) unless Welcome is turned off.
            switch WelcomeFlow.shared.launchAction() {
            case .tour:
                isShowingTour = true
                return
            case .welcome:
                return
            case .reopenLast:
                break
            }
        }
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
        if let current = document, LaunchEnvironment.key(current.fileURL) == key {
            // Back from Welcome: the open document may have missed a newer file.
            await current.revertIfOutdated()
            return true
        }
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

    /// New map per storage mode (WP14b): library map, else a new file.
    private func createNow() async {
        isWorking = true
        defer { isWorking = false }
        await closeCurrent()
        do {
            if case let .library(url) = try MapCreation.prepareNewMap() {
                let created = MindMapUIDocument(fileURL: url)
                guard await created.open() else { throw CocoaError(.fileReadUnknown) }
                await install(created, scopedURL: nil, blank: true)
                return
            }
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
        isShowingWelcome = false
        WelcomeFlow.shared.noteOpened(opened.fileURL)
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
        if discard {
            if let id = LibraryService.shared.libraryMapID(of: url) {
                try? LibraryService.shared.store.deleteMap(.library(id))
            } else {
                await Self.removeItem(at: url)
            }
        }
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
        WelcomeFlow.shared.noteOpened(new)
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

/// A map this window showed before following a map link in place.
struct MapBackEntry: Equatable {
    var url: URL
    var title: String
}

/// User activity that creates a new iPad window for a map link.
@MainActor
enum MapLinkActivity {
    static let type = "com.kekukh.MindMap.openMap"

    static func make(for url: URL) -> NSUserActivity {
        let activity = NSUserActivity(activityType: type)
        var info: [String: Any] = ["path": url.path]
        if let bookmark = try? SystemBookmarkCoder().bookmark(for: url) { info["bookmark"] = bookmark }
        activity.userInfo = info
        activity.targetContentIdentifier = DocumentWindow.sceneID
        return activity
    }

    static func url(from activity: NSUserActivity) -> URL? {
        guard activity.activityType == type else { return nil }
        if let data = activity.userInfo?["bookmark"] as? Data, let url = try? SystemBookmarkCoder().resolve(data).url {
            return url
        }
        return (activity.userInfo?["path"] as? String).map { URL(fileURLWithPath: $0) }
    }
}
#endif
