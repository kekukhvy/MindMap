#if os(iOS)
import Foundation
import UniformTypeIdentifiers

/// Where iPad documents live. New maps go to the app's iCloud Drive folder
/// ("MindMap" in iCloud Drive) when the iCloud capability is configured,
/// otherwise to the local Documents folder ("On My iPad › MindMap" in
/// Files: UISupportsDocumentBrowser / LSSupportsOpeningDocumentsInPlace /
/// UIFileSharingEnabled). Unit-test runs use a temporary folder.
enum DocumentLocations {
    static let localDocuments: URL = {
        if LaunchEnvironment.isTesting {
            return FileManager.default.temporaryDirectory.appendingPathComponent("MindMapTestDocuments")
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    /// iCloud container Documents folder, nil without iCloud entitlement or
    /// account. Resolved once, off the main thread (it can block).
    static func ubiquitousDocuments() async -> URL? {
        if LaunchEnvironment.isTesting { return nil }
        if let cached = await Cache.shared.value { return cached.url }
        let url = await Task.detached(priority: .userInitiated) {
            FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents")
        }.value
        await Cache.shared.store(url)
        return url
    }

    /// Folders the app owns (fallback lookup of the last document).
    static func roots() async -> [URL] {
        [await ubiquitousDocuments(), localDocuments].compactMap { $0 }
    }

    /// URL for a new "Untitled[ n].mindmap" in the preferred folder.
    static func newDocumentURL() async throws -> URL {
        let folder = await ubiquitousDocuments() ?? localDocuments
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let name = UntitledName.next(existing: names, pathExtension: UTType.mindMap.preferredFilenameExtension ?? "mindmap")
        return folder.appendingPathComponent(name, isDirectory: true)
    }

    private actor Cache {
        static let shared = Cache()
        struct Entry { let url: URL? }
        private(set) var value: Entry?
        func store(_ url: URL?) { value = Entry(url: url) }
    }
}
#endif
