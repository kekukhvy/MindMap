import CloudKit
import Foundation
import Network
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// App-wide wiring of the map library (WP14): cache + sync + store +
/// settings, the CloudKit engine when the account is available, a file
/// presenter that notices saves of library packages, fetch on launch and
/// when the app becomes active. Not started in the unit-test host (tests
/// build their own `LibrarySync` with mocks).
@MainActor
@Observable
final class LibraryService {
    static let shared = LibraryService()

    let sync: LibrarySync
    let store: LibraryMapStore
    let settings: StorageSettings
    private(set) var availability: LibraryAvailability = .checking
    /// Network reachable (Offline status).
    private(set) var isOnline = true
    /// Bumped on every library / sync change (lists and badges observe it).
    private(set) var revision = 0
    /// Plain `.md` copies of the library for Obsidian (Settings).
    let mirror: LibraryMirror

    @ObservationIgnored private let accounts: LibraryAccountProviding
    @ObservationIgnored private var engine: LibrarySyncEngine?
    @ObservationIgnored private var monitor: LibraryChangeMonitor?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var revisionScheduled = false

    init(cache: LibraryCache = .shared, accounts: LibraryAccountProviding = CloudKitAccountProvider(),
         settings: StorageSettings? = nil, mirrorSettings: LibraryMirrorSettings? = nil) {
        sync = LibrarySync(cache: cache)
        store = LibraryMapStore(sync: sync)
        self.settings = settings ?? StorageSettings(defaults: Self.defaults)
        self.accounts = accounts
        mirror = LibraryMirror(store: store, settings: mirrorSettings ?? LibraryMirrorSettings(defaults: Self.defaults))
        sync.onStateChanged = { [weak self] in self?.libraryDidChange() }
        sync.onLibraryChanged = { [weak self] in self?.libraryDidChange() }
    }

    /// The app's defaults; a separate suite in the unit-test host (the test
    /// host shares the app's container with the real Debug app).
    static let defaults: UserDefaults = LaunchEnvironment.isTesting
        ? UserDefaults(suiteName: "com.kekukh.MindMap.tests") ?? .standard
        : .standard

    /// Library status (Settings line, badges).
    var status: LibrarySyncStatus {
        _ = revision
        return LibrarySyncStatus.make(availability: availability, isOnline: isOnline,
                                      hasPendingChanges: sync.hasPendingChanges)
    }

    /// Status of one library map (its window badge).
    func status(of id: UUID) -> LibrarySyncStatus {
        _ = revision
        return LibrarySyncStatus.make(availability: availability, isOnline: isOnline,
                                      hasPendingChanges: sync.isPending(id))
    }

    /// The library map whose package is `url` (nil = a file).
    func libraryMapID(of url: URL?) -> UUID? {
        url.flatMap { sync.cache.mapID(containing: $0) }
    }

    /// Coalesces change callbacks into one `revision` bump per run loop
    /// turn; the mirror follows (debounced there).
    private func libraryDidChange() {
        guard !revisionScheduled else { return }
        revisionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            revisionScheduled = false
            revision += 1
            mirror.scheduleUpdate()
        }
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                self.revision += 1
            }
        }
        monitor.start(queue: DispatchQueue(label: "MindMap.network"))
        pathMonitor = monitor
    }

    /// Launch: local bookkeeping always; CloudKit when available.
    func start() async {
        guard !started else { return }
        started = true
        let monitor = LibraryChangeMonitor(folder: sync.cache.mapsFolder) { [weak self] id in
            Task { @MainActor in self?.sync.localMapDidChange(id) }
        }
        monitor.start()
        self.monitor = monitor
        observeActivation()
        startNetworkMonitor()
        mirror.scheduleUpdate()
        await refreshAvailability()
    }

    /// Re-checks the account; attaches / detaches the engine.
    func refreshAvailability() async {
        let availability = await accounts.availability()
        self.availability = availability
        revision += 1
        settings.isLibraryAvailable = availability.isAvailable
        if availability.isAvailable, engine == nil, let container = accounts.makeContainer() {
            let engine = CloudKitSyncEngine(database: container.privateCloudDatabase, sync: sync)
            self.engine = engine
            sync.attach(engine)
            await sync.integrateStagedChanges()
            registerForPushNotifications()
            try? await engine.fetchChanges()
        } else if !availability.isAvailable, engine != nil {
            engine = nil
            sync.attach(nil)
        } else {
            sync.scanForLocalChanges()
        }
    }

    /// For tests / a debug hook: use this engine (mock) instead of CloudKit.
    func attachEngine(_ engine: LibrarySyncEngine?) {
        self.engine = engine
        sync.attach(engine)
    }

    /// Sync now: re-checks the account when there is no engine, else scans
    /// for local changes, fetches and sends. Runs on app activation and when
    /// the sync badge is tapped. Never called from inside an engine callback.
    func syncNow() async {
        if engine == nil {
            await refreshAvailability()
        } else {
            sync.scanForLocalChanges()
            try? await engine?.fetchChanges()
            try? await engine?.sendChanges()
        }
    }

    @discardableResult
    func appDidBecomeActive() -> Task<Void, Never> {
        Task { await syncNow() }
    }

    private func observeActivation() {
        #if os(macOS)
        let name = NSApplication.didBecomeActiveNotification
        #else
        let name = UIApplication.didBecomeActiveNotification
        #endif
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            _ = MainActor.assumeIsolated { self?.appDidBecomeActive() }
        })
    }

    /// CKSyncEngine fetches on the pushes of its own database subscription;
    /// the app only has to be registered for (silent) remote notifications.
    private func registerForPushNotifications() {
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// Starts the library once per process (not in the unit-test host).
    static func startAtLaunch() {
        guard !LaunchEnvironment.isTesting else { return }
        Task { @MainActor in
            await shared.start()
            #if DEBUG
            LibraryDebugHook.runIfRequested(shared)
            #endif
        }
    }
}

/// Notices writes to library packages (documents save through file
/// coordination, which notifies other presenters of the same folder) and
/// reports the map ID.
final class LibraryChangeMonitor: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable (UUID) -> Void
    private let mapsKey: String

    init(folder: URL, onChange: @escaping @Sendable (UUID) -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        presentedItemURL = folder
        mapsKey = LaunchEnvironment.key(folder) + "/"
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        self.onChange = onChange
    }

    func start() { NSFileCoordinator.addFilePresenter(self) }
    func stop() { NSFileCoordinator.removeFilePresenter(self) }

    func presentedSubitemDidChange(at url: URL) { report(url) }
    func presentedSubitemDidAppear(at url: URL) { report(url) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { report(newURL) }

    /// The map ID of a URL inside `Maps/<UUID>/…`.
    func mapID(of url: URL) -> UUID? {
        let path = LaunchEnvironment.key(url)
        guard path.hasPrefix(mapsKey) else { return nil }
        return path.dropFirst(mapsKey.count).split(separator: "/").first.flatMap { UUID(uuidString: String($0)) }
    }

    private func report(_ url: URL) {
        if let id = mapID(of: url) { onChange(id) }
    }
}

#if DEBUG
/// DEBUG launch hook: `MINDMAP_DEBUG_LIBRARY=status` writes
/// `<tmp>/library-report.txt` (availability, storage mode, maps, pending
/// changes); `=create` also creates a library map "Library Test" and opens
/// it in the normal editor (new tab / window); `=settings` / `=browser`
/// (iPad screenshots) seed sample library maps, open one and show the
/// Settings sheet / library sheet.
@MainActor
enum LibraryDebugHook {
    static func runIfRequested(_ service: LibraryService) {
        guard let mode = ProcessInfo.processInfo.environment["MINDMAP_DEBUG_LIBRARY"] else { return }
        if mode == "create", let summary = try? service.store.createMap(titled: "Library Test"),
           let url = service.store.packageURL(for: summary.location) {
            open(url)
        }
        if mode == "settings" || mode == "browser" {
            seedSamples(service)
            if let first = service.store.maps().first(where: { $0.title == "Product Roadmap" }),
               let url = service.store.packageURL(for: first.location) {
                open(url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NotificationCenter.default.post(name: presentRequest, object: mode)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { writeReport(service) }
    }

    private static func open(_ url: URL) {
        #if os(macOS)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        #else
        NotificationCenter.default.post(name: openRequest, object: url)
        #endif
    }

    /// iPad: the window's `DocumentSession` opens the URL (DocumentWindow).
    static let openRequest = Notification.Name("MindMapLibraryDebugOpen")
    /// iPad: show the Settings ("settings") / library ("browser") sheet.
    static let presentRequest = Notification.Name("MindMapLibraryDebugPresent")

    /// Sample maps for screenshots (once per cache).
    static func seedSamples(_ service: LibraryService) {
        guard !service.store.maps().contains(where: { $0.title == "Product Roadmap" }) else { return }
        let samples: [(String, [String], Double)] = [
            ("Product Roadmap", ["Research", "Design", "Launch"], -5),
            ("Trip to Lisbon", ["Flights", "Hotel", "Food"], -90),
            ("Reading List", ["Fiction", "Science"], -60 * 30),
        ]
        for (title, topics, minutes) in samples {
            let map = MindMap(root: Node(text: title, children: topics.map { Node(text: $0) }), title: title)
            guard let summary = try? service.store.importMap(map),
                  let url = service.store.packageURL(for: summary.location) else { continue }
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: minutes * 60)],
                                                   ofItemAtPath: url.appendingPathComponent("map.json").path)
            if case let .library(id) = summary.location { service.sync.checkForLocalChanges(id) }
        }
        // A locked map (random key: shows the lock icon only).
        if let sealed = try? LockedPackage.seal(map: MindMap(root: Node(text: "Finances")), attachments: [:],
                                                header: LockHeader(keyID: UUID()), key: LockCrypto.newKey(),
                                                cache: nil) {
            let id = UUID()
            _ = try? service.sync.cache.writePackage(sealed, for: id, title: "Finances")
            service.sync.checkForLocalChanges(id)
        }
    }

    static func writeReport(_ service: LibraryService) {
        var lines = [
            "availability: \(service.availability.statusText)",
            "storageMode: \(service.settings.storageMode.rawValue) explicit=\(service.settings.hasExplicitChoice)",
            "container: \(CloudKitAccountProvider.bundleContainerIdentifier ?? "none")",
            "cache: \(service.sync.cache.root.path)",
        ]
        for map in service.store.maps() {
            if case let .library(id) = map.location {
                let meta = service.sync.state.maps[id]
                lines.append("map \(id) \"\(map.title)\" locked=\(map.isLocked) onServer=\(meta?.isOnServer ?? false) "
                    + "url=\(service.store.packageURL(for: map.location)?.path ?? "nil")")
            }
        }
        if let error = service.sync.lastError { lines.append("lastError: \(error)") }
        #if os(macOS)
        for document in NSDocumentController.shared.documents {
            lines.append("document \(document.displayName ?? "?") url=\(document.fileURL?.path ?? "nil")")
        }
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("library-report.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
