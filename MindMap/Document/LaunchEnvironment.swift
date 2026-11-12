import Foundation

/// What the app opens at launch (pure parts, shared by both platforms).
enum LaunchEnvironment {
    /// Running as the host of the unit tests: no launch restoration and no
    /// files in the user's folders.
    static let isTesting: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil || NSClassFromString("XCTestCase") != nil
    }()

    /// Recent documents to try at launch, most recent first: not already
    /// open (window restoration may have reopened some), at most `limit`.
    static func reopenCandidates(recents: [URL], alreadyOpen: [URL], limit: Int = 3) -> [URL] {
        let open = Set(alreadyOpen.map(key))
        var seen = Set<String>()
        return Array(recents.filter { url in
            let k = key(url)
            return !open.contains(k) && seen.insert(k).inserted
        }.prefix(limit))
    }

    /// Comparable identity of a file URL (standardized, symlinks resolved).
    static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
