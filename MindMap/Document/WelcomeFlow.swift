import Foundation
import Observation

/// What the app shows at launch and the first-launch sequence (WP13):
/// very first launch → Welcome Tour (last page = storage choice) → the
/// sample maps are copied into the chosen store and "MindMap Features"
/// opens — exactly once. Later launches: the Welcome screen ("Show Welcome
/// on launch", default on) or, with it off, the old behaviour (reopen the
/// last document).
@MainActor
@Observable
final class WelcomeFlow {
    static let shared = WelcomeFlow(service: .shared, defaults: LibraryService.defaults)

    enum LaunchAction: Equatable {
        /// First launch: Welcome with the tour on top.
        case tour
        case welcome
        /// "Show Welcome on launch" off: reopen the last document.
        case reopenLast
    }

    static let showOnLaunchKey = "MindMap.welcome.showOnLaunch"
    static let tourCompletedKey = "MindMap.welcome.tourCompleted"
    static let sampleOpenedKey = "MindMap.samples.firstOpenDone"
    static let filesFolderKey = "MindMap.filesFolder"

    @ObservationIgnored let service: LibraryService
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var bundle: Bundle = .main

    /// The macOS Welcome window presents the tour (iPad: per window, `DocumentSession`).
    var isShowingTour = false
    /// Bumped when the recent list changes (Welcome re-reads it).
    private(set) var recentsRevision = 0
    var showsWelcomeOnLaunch: Bool {
        didSet { defaults.set(showsWelcomeOnLaunch, forKey: Self.showOnLaunchKey) }
    }

    init(service: LibraryService, defaults: UserDefaults) {
        self.service = service
        self.defaults = defaults
        showsWelcomeOnLaunch = defaults.object(forKey: Self.showOnLaunchKey) as? Bool ?? true
    }

    var isTourCompleted: Bool { defaults.bool(forKey: Self.tourCompletedKey) }

    func launchAction() -> LaunchAction {
        if !isTourCompleted { return .tour }
        return showsWelcomeOnLaunch ? .welcome : .reopenLast
    }

    var recents: RecentMapsStore { RecentMapsStore(defaults: defaults) }

    /// A map document was opened: remembered for Recent Files (library
    /// maps are listed in the Library section instead).
    func noteOpened(_ url: URL?) {
        guard let url, service.libraryMapID(of: url) == nil else { return }
        recents.note(url)
        recentsRevision += 1
    }

    func removeRecent(_ url: URL) {
        recents.remove(url)
        recentsChanged()
    }

    /// The recent list changed outside `noteOpened` / `removeRecent`.
    func recentsChanged() {
        recentsRevision += 1
    }

    // MARK: Tour and samples

    /// The tour's last page was confirmed (`choice`) or the tour was
    /// skipped (nil = keep the current mode). The first time only: copies
    /// the samples into the chosen store and returns "MindMap Features" to
    /// open; nil afterwards.
    func finishTour(choice: StorageMode?) async throws -> URL? {
        if let choice { service.settings.storageMode = choice }
        defaults.set(true, forKey: Self.tourCompletedKey)
        guard !defaults.bool(forKey: Self.sampleOpenedKey) else { return nil }
        defaults.set(true, forKey: Self.sampleOpenedKey)
        return try installer.featuresURL(installingInto: await sampleDestination())
    }

    /// "Open Sample": the copy made earlier, or a new copy (deleted / never
    /// made) in the current default store.
    func sampleURL() async throws -> URL {
        try installer.featuresURL(installingInto: await sampleDestination())
    }

    var installer: SampleInstaller {
        SampleInstaller(service: service, defaults: defaults, bundle: bundle)
    }

    /// Default store for the samples: the library, or the files folder.
    func sampleDestination() async -> SampleDestination {
        switch service.settings.storageMode {
        case .library: return .library
        case .files: return .folder(await filesFolder())
        }
    }

    // MARK: Files folder

    /// Override for tests.
    @ObservationIgnored var filesFolderOverride: URL?

    /// Where Files-mode samples go. macOS: the folder chosen on the tour's
    /// storage page (security-scoped, kept accessible), else the app's
    /// Documents folder. iPad: the app's iCloud Drive folder, else
    /// "On My iPad › MindMap".
    func filesFolder() async -> URL {
        if let filesFolderOverride { return filesFolderOverride }
        #if os(macOS)
        if let url = chosenFilesFolder { return url }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        return await DocumentLocations.ubiquitousDocuments() ?? DocumentLocations.localDocuments
        #endif
    }

    /// macOS: the folder picked for Files (nil = none yet).
    var chosenFilesFolder: URL? {
        guard let data = defaults.data(forKey: Self.filesFolderKey), let url = try? FolderBookmark.resolve(data) else {
            return nil
        }
        if !Self.accessed.contains(url.path) {
            // Kept for the process: documents in it are opened and saved later.
            _ = url.startAccessingSecurityScopedResource()
            Self.accessed.insert(url.path)
        }
        return url
    }

    func setFilesFolder(_ url: URL) throws {
        defaults.set(try FolderBookmark.make(url), forKey: Self.filesFolderKey)
        _ = chosenFilesFolder
    }

    private static var accessed: Set<String> = []

    #if DEBUG
    /// Tests / screenshots: forget the first-launch state.
    func resetFirstLaunch() {
        for key in [Self.tourCompletedKey, Self.sampleOpenedKey, SampleInstaller.locationKey, Self.showOnLaunchKey] {
            defaults.removeObject(forKey: key)
        }
        showsWelcomeOnLaunch = true
    }
    #endif
}
