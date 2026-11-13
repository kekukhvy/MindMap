#if DEBUG
import Foundation

/// DEBUG launch hook for Welcome screenshots (`MINDMAP_DEBUG_WELCOME`,
/// comma-separated): `reset` = behave like the very first launch (tour,
/// then samples); `tour=N` = the tour starts at page N (0-based; 6 = the
/// storage choice); `seed` = tour done + library maps + recent files
/// (the samples, a plain and a locked file) so Welcome has content.
@MainActor
enum WelcomeDebugHook {
    static var tourPage = 0

    private static var options: [String] {
        (ProcessInfo.processInfo.environment["MINDMAP_DEBUG_WELCOME"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// App init (before any window decides what to show).
    static func prepare() {
        let options = options
        guard !options.isEmpty, !LaunchEnvironment.isTesting else { return }
        let flow = WelcomeFlow.shared
        if options.contains("reset") {
            flow.resetFirstLaunch()
            flow.recents.removeAll()
        }
        for option in options where option.hasPrefix("tour=") {
            tourPage = Int(option.dropFirst(5)) ?? 0
        }
        if options.contains("seed") {
            flow.defaults.set(true, forKey: WelcomeFlow.tourCompletedKey)
            flow.defaults.set(true, forKey: WelcomeFlow.sampleOpenedKey)
            flow.showsWelcomeOnLaunch = true
            Task { await seed(flow) }
        }
    }

    private static func seed(_ flow: WelcomeFlow) async {
        LibraryDebugHook.seedSamples(flow.service)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WelcomeSeed", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        flow.recents.removeAll()
        let plain = folder.appendingPathComponent("Team Offsite.mindmap")
        let map = MindMap(root: Node(text: "Team Offsite", children: [
            Node(text: "Agenda", children: [Node(text: "Kick-off"), Node(text: "Workshops")]),
            Node(text: "Travel", children: [Node(text: "Train"), Node(text: "Hotel")]),
            Node(text: "Budget"),
            Node(text: "Activities", children: [Node(text: "Hike"), Node(text: "Dinner")]),
        ]))
        try? MindMapPackage.fileWrapper(for: map).write(to: plain, options: [], originalContentsURL: nil)
        let locked = folder.appendingPathComponent("Salary Review.mindmap")
        if let sealed = try? LockedPackage.seal(map: MindMap(root: Node(text: "Salary Review")), attachments: [:],
                                                header: LockHeader(keyID: UUID()), key: LockCrypto.newKey(),
                                                cache: nil) {
            try? FileManager.default.removeItem(at: locked)
            try? sealed.write(to: locked, options: [], originalContentsURL: nil)
        }
        let samples = (try? flow.installer.install(into: .folder(folder.appendingPathComponent("Samples"))))
        var urls = [locked, plain]
        if let samples {
            urls.insert(samples.deletingLastPathComponent().appendingPathComponent(SampleMaps.roadmapName + ".mindmap"),
                        at: 0)
            urls.append(samples)
        }
        for (index, url) in urls.enumerated() {
            flow.recents.note(url, date: Date(timeIntervalSinceNow: Double(index - urls.count) * 3600))
        }
        flow.recentsChanged()
    }
}
#endif
