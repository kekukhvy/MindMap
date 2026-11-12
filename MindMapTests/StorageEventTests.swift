#if os(macOS)
import AppKit
import CryptoKit
import SwiftUI
import Testing
@testable import MindMap

/// Real-event tests of the storage UI on macOS: ⌘N typed into a real map
/// window goes through the app's File menu (`StorageCommands`) and, in
/// library mode, creates and opens a library map; renaming its package
/// (File ▸ Rename… / title bar do this) becomes the map's title. Plus
/// snapshots of Settings and the library browser (Tools/preview).
@MainActor
@Suite(.serialized)
struct StorageEventTests {
    private func pressCommandN(in window: NSWindow) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "n", charactersIgnoringModifiers: "n",
                isARepeat: false, keyCode: 45))
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func libraryDocuments(_ service: LibraryService) -> [NSDocument] {
        NSDocumentController.shared.documents.filter { service.libraryMapID(of: $0.fileURL) != nil }
    }

    @Test func commandNInLibraryModeCreatesAndOpensALibraryMap() async throws {
        let service = LibraryService.shared
        let settings = service.settings
        let previousMode = settings.hasExplicitChoice ? settings.storageMode : nil
        defer { if let previousMode { settings.storageMode = previousMode } }
        settings.storageMode = .library

        let harness = try await CanvasEventHarness(realDocumentWith: MindMap(root: Node(text: "Host")))
        defer { harness.close() }
        let mapsBefore = Set(service.store.maps().map(\.location))
        let openBefore = Set(libraryDocuments(service).map(ObjectIdentifier.init))

        try await pressCommandN(in: harness.window)
        var created: NSDocument?
        for _ in 0..<40 where created == nil {
            try await Task.sleep(for: .milliseconds(100))
            created = libraryDocuments(service).first { !openBefore.contains(ObjectIdentifier($0)) }
        }
        let document = try #require(created, "⌘N must open a new library map")
        defer { document.close() }
        let newMaps = service.store.maps().filter { !mapsBefore.contains($0.location) }
        #expect(newMaps.count == 1)
        let summary = try #require(newMaps.first)
        #expect(summary.title.hasPrefix("Untitled"))
        let url = try #require(service.store.packageURL(for: summary.location))
        #expect(document.fileURL.map(LaunchEnvironment.key) == LaunchEnvironment.key(url))
        #expect(document.windowControllers.first?.window?.isVisible == true)
        let editor = try #require(EditorController.debugInstances.compactMap(\.editor).last {
            $0.documentURL.map(LaunchEnvironment.key) == LaunchEnvironment.key(url) })
        #expect(editor.storage.isLibraryMap)
        #expect(editor.model.map.root.text == "Central Topic")

        // Package renamed outside the editor (File ▸ Rename… does this) →
        // the document follows and the map takes the name as its title.
        let id = try #require(summary.libraryID)
        try service.sync.cache.renamePackage(of: id, toTitle: "Renamed Map")
        for _ in 0..<30 where editor.model.map.title != "Renamed Map" {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(document.fileURL?.lastPathComponent == "Renamed Map.mindmap")
        #expect(editor.model.map.title == "Renamed Map")
        #expect(editor.storage.title == "Renamed Map")

        // Files mode: ⌘N makes an ordinary untitled document.
        settings.storageMode = .files
        let countBefore = service.store.maps().count
        let documentsBefore = Set(NSDocumentController.shared.documents.map(ObjectIdentifier.init))
        try await pressCommandN(in: harness.window)
        var untitled: NSDocument?
        for _ in 0..<40 where untitled == nil {
            try await Task.sleep(for: .milliseconds(100))
            untitled = NSDocumentController.shared.documents.first { !documentsBefore.contains(ObjectIdentifier($0)) }
        }
        let fileDocument = try #require(untitled)
        defer { fileDocument.close() }
        #expect(fileDocument.fileURL == nil)
        #expect(service.store.maps().count == countBefore)

        document.close()
        try service.store.deleteMap(summary.location)
    }

    // MARK: Snapshots

    private func snapshot<V: View>(_ view: V, size: CGSize, name: String) async throws -> URL {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(900))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    @Test func settingsAndLibrarySnapshots() async throws {
        let service = await StorageFixtures.service(.unavailable("this build is not signed for iCloud"))
        service.settings.storageMode = .library
        let folder = StorageFixtures.temporaryFolder()
        for (title, minutes) in [("Product Roadmap", -5.0), ("Trip to Lisbon", -90), ("Reading List", -60 * 30)] {
            let summary = try service.store.importMap(MindMap(root: Node(text: title), title: title))
            let url = try #require(service.store.packageURL(for: summary.location))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: minutes * 60)],
                                                  ofItemAtPath: url.appendingPathComponent("map.json").path)
            service.sync.checkForLocalChanges(try #require(summary.libraryID))
        }
        let locked = try StorageFixtures.lockedFile(MindMap(root: Node(text: "Finances")), files: [:],
                                                    key: LockCrypto.newKey(),
                                                    to: folder.appendingPathComponent("Finances.mindmap"))
        try service.store.importPackage(at: locked)

        let library = try await snapshot(LibraryBrowserView(service: service, onOpen: { _ in }, onNewMap: {},
                                                            onCancel: {}),
                                         size: CGSize(width: 520, height: 440), name: "library-mac.png")
        let settings = try await snapshot(SettingsView(service: service, showsFix: true), size: CGSize(width: 540, height: 760),
                                          name: "settings-mac.png")
        #expect(FileManager.default.fileExists(atPath: library.path))
        #expect(FileManager.default.fileExists(atPath: settings.path))
    }
}
#endif
