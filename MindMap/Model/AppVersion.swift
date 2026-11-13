import Foundation

/// The app's own version, shown in Settings and the macOS About panel:
/// "Version 1.0 (142, 3f3fd45)" = marketing version, build number (git commit count)
/// and the commit the build came from. Tools/xcb/xcb.sh fills the build number and the
/// commit on every command-line build; an Xcode IDE build has the project default
/// build number and no commit, and the commit part is then left out.
enum AppVersion {
    static let commitInfoKey = "MindMapCommit"

    /// "Version 1.0 (142, 3f3fd45)", or "Version 1.0 (142)" without a commit.
    static func text(version: String, build: String, commit: String) -> String {
        "Version \(version) (\(buildDetail(build: build, commit: commit)))"
    }

    /// "142, 3f3fd45", or "142" without a commit: the part in parentheses.
    static func buildDetail(build: String, commit: String) -> String {
        commit.isEmpty ? build : "\(build), \(commit)"
    }

    /// Version text of this running app.
    static var text: String { text(version: marketingVersion, build: build, commit: commit) }

    /// The build part of this running app, for the About panel.
    static var buildDetail: String { buildDetail(build: build, commit: commit) }

    private static var marketingVersion: String { string(for: "CFBundleShortVersionString") }
    private static var build: String { string(for: kCFBundleVersionKey as String) }
    private static var commit: String { string(for: commitInfoKey) }

    private static func string(for key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }
}
