#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MindMap

/// macOS Welcome window (WP13) with real windows and events: it closes when
/// a map opens; a synthesized click on a Recent Files row opens that file;
/// Move To… on a library map is refused (WP14b risk); snapshots of the
/// Welcome window and every tour page (Tools/preview).
@MainActor
@Suite(.serialized)
struct WelcomeEventTests {
    private func waitUntil(_ condition: () -> Bool, timeout: Int = 40) async throws {
        for _ in 0..<timeout where !condition() {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func document(at url: URL) -> NSDocument? {
        let key = LaunchEnvironment.key(url)
        return NSDocumentController.shared.documents.first { $0.fileURL.map(LaunchEnvironment.key) == key }
    }

    @Test func welcomeClosesWhenAMapOpens() async throws {
        let controller = WelcomeWindowController.shared
        controller.show()
        try await waitUntil { controller.isShown }
        #expect(controller.isShown)
        // The tour keeps it open (the sample opens behind the tour's end).
        let url = try StorageFixtures.writeFile(MindMap(root: Node(text: "Opened")),
                                                to: StorageFixtures.temporaryFolder("WelcomeOpen")
                                                    .appendingPathComponent("Opened.mindmap"))
        _ = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
        try await waitUntil { !controller.isShown }
        #expect(!controller.isShown)
        let opened = try #require(document(at: url))
        // Recorded for Recent Files.
        #expect(WelcomeFlow.shared.recents.entries().contains { $0.id == LaunchEnvironment.key(url) })
        // Shown again (⇧⌘1) while a map is open: stays until the next map opens.
        controller.show()
        try await waitUntil { controller.isShown }
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.isShown)
        opened.close()
        controller.close()
    }

    @Test func clickingARecentFileOpensItAndClosesWelcome() async throws {
        let flow = WelcomeFlow.shared
        let url = try StorageFixtures.writeFile(MindMap(root: Node(text: "Recent One", children: [Node(text: "A")])),
                                                to: StorageFixtures.temporaryFolder("WelcomeClick")
                                                    .appendingPathComponent("Recent One.mindmap"))
        flow.recents.note(url)
        flow.recentsChanged()
        let controller = WelcomeWindowController.shared
        controller.show()
        // The Welcome window accepts the first click (the hosted test app is inactive).
        let window = try #require(controller.window)
        let key = LaunchEnvironment.key(url)
        try await waitUntil { WelcomeDebug.rowFrames[key] != nil }
        try await Task.sleep(for: .milliseconds(300))
        let frame = try #require(WelcomeDebug.rowFrames[key])
        let content = try #require(window.contentView)
        // SwiftUI global frame (top-left origin) → window coordinates.
        let point = content.convert(CGPoint(x: frame.midX, y: content.isFlipped ? frame.midY
                                                : content.bounds.height - frame.midY), to: nil)
        var time = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            time += 0.05
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 0, clickCount: 1,
                                                        pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(60))
        }
        try await waitUntil { document(at: url) != nil && !controller.isShown }
        let opened = try #require(document(at: url), "clicking the Recent Files row must open the map")
        #expect(!controller.isShown)
        #expect(opened.windowControllers.first?.window?.isVisible == true)
        opened.close()
        flow.removeRecent(url)
    }

    // MARK: Move To… on a library map (WP14b risk)

    @Test func moveToIsRefusedForLibraryMapsButWorksForFiles() async throws {
        let service = LibraryService.shared
        let summary = try service.store.createUntitledMap()
        let id = try #require(summary.libraryID)
        let url = try #require(service.store.packageURL(for: summary.location))
        _ = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
        let library = try #require(document(at: url))
        var refused: [NSDocument] = []
        LibraryMoveGuard.onRefused = { refused.append($0) }
        defer { LibraryMoveGuard.onRefused = nil }

        // Menu item disabled.
        let item = NSMenuItem(title: "Move To…", action: #selector(NSDocument.move(_:)), keyEquivalent: "")
        #expect(!library.validateUserInterfaceItem(item))
        // File ▸ Move To… / title bar menu: refused with the explanation.
        library.move(nil)
        #expect(refused.count == 1)
        // Title bar "Where:" (moveToURL): refused, nothing moved.
        let target = StorageFixtures.temporaryFolder("MoveTarget").appendingPathComponent("Moved.mindmap")
        let error: Error? = await withCheckedContinuation { continuation in
            library.move(to: target) { continuation.resume(returning: $0) }
        }
        #expect((error as? CocoaError)?.code == .userCancelled)
        #expect(refused.count == 2)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(service.store.packageURL(for: .library(id)) != nil)
        #expect(service.libraryMapID(of: library.fileURL) == id)
        #expect(service.store.maps().contains { $0.location == .library(id) })

        // A file document still moves.
        let file = try StorageFixtures.writeFile(MindMap(root: Node(text: "File")),
                                                 to: StorageFixtures.temporaryFolder("MoveFile")
                                                     .appendingPathComponent("File.mindmap"))
        _ = try await NSDocumentController.shared.openDocument(withContentsOf: file, display: true)
        let fileDocument = try #require(document(at: file))
        #expect(fileDocument.validateUserInterfaceItem(item))
        let fileTarget = StorageFixtures.temporaryFolder("MoveFileTarget").appendingPathComponent("File.mindmap")
        let fileError: Error? = await withCheckedContinuation { continuation in
            fileDocument.move(to: fileTarget) { continuation.resume(returning: $0) }
        }
        #expect(fileError == nil)
        #expect(FileManager.default.fileExists(atPath: fileTarget.path))
        #expect(refused.count == 2)

        fileDocument.close()
        library.close()
        try service.store.deleteMap(.library(id))
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
        try await Task.sleep(for: .milliseconds(1200))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WelcomeShots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        print("WELCOME SHOT \(url.path)")
        return url
    }

    @Test func welcomeAndTourSnapshots() async throws {
        let service = await StorageFixtures.service(.unavailable("this build is not signed for iCloud"))
        let flow = WelcomeFlow(service: service, defaults: StorageFixtures.defaults())
        let folder = StorageFixtures.temporaryFolder("WelcomeShots")
        flow.filesFolderOverride = folder
        _ = try await flow.finishTour(choice: .library)
        for (title, minutes) in [("Product Roadmap", -5.0), ("Trip to Lisbon", -90)] {
            let summary = try service.store.importMap(MindMap(root: Node(text: title, children: [
                Node(text: "Research"), Node(text: "Design"), Node(text: "Launch"),
            ]), title: title))
            let url = try #require(service.store.packageURL(for: summary.location))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: minutes * 60)],
                                                  ofItemAtPath: url.appendingPathComponent("map.json").path)
            service.sync.checkForLocalChanges(try #require(summary.libraryID))
        }
        let installer = SampleInstaller(service: service, defaults: StorageFixtures.defaults())
        let features = try installer.install(into: .folder(folder.appendingPathComponent("Maps")))
        let offsite = try StorageFixtures.writeFile(MindMap(root: Node(text: "Team Offsite", children: [
            Node(text: "Agenda", children: [Node(text: "Kick-off"), Node(text: "Workshops")]),
            Node(text: "Travel"), Node(text: "Budget"), Node(text: "Activities"),
        ])), to: folder.appendingPathComponent("Team Offsite.mindmap"))
        let locked = try StorageFixtures.lockedFile(MindMap(root: Node(text: "Salary Review")), files: [:],
                                                    key: LockCrypto.newKey(),
                                                    to: folder.appendingPathComponent("Salary Review.mindmap"))
        for (index, url) in [locked, offsite, features].enumerated() {
            flow.recents.note(url, date: Date(timeIntervalSinceNow: Double(index) * 60))
        }
        flow.recentsChanged()
        let actions = WelcomeActions(newMap: {}, openFile: {}, open: { _ in })
        let welcome = WelcomeView(flow: flow, actions: actions, isShowingTour: .constant(false))
        _ = try await snapshot(welcome, size: CGSize(width: 940, height: 620), name: "welcome-mac.png")

        for page in 0...TourPage.all.count {
            let tour = WelcomeTourView(service: service, isFirstLaunch: page == TourPage.all.count, onFinish: { _ in },
                                       filesFolder: nil, chooseFilesFolder: { _ in }, initialPage: page)
            _ = try await snapshot(tour, size: CGSize(width: 880, height: 660), name: "tour-\(page + 1)-mac.png")
        }
    }
}
#endif
