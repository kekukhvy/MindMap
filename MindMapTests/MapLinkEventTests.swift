#if os(macOS)
import AppKit
import Testing
@testable import MindMap

/// WP10 real-event test (see `CanvasEventHarness`): in a real document
/// window opened from a file, a click on the map-link icon of a topic linked
/// to another map opens that map as a native tab of the same window, at its target topic
/// (collapsed parent expanded); clicking again focuses the existing tab
/// instead of opening the map twice. Cmd+click on that topic only selects
/// it (multi-selection), it never opens the map.
@MainActor
@Suite(.serialized)
struct MapLinkEventTests {
    @Test func iconClickOpensLinkedMapAsTabAndRefocusesIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MapLinkEvent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let deep = Node(text: "Deep Topic")
        let other = MindMap(root: Node(text: "Other Map", layoutStyle: .rightMap,
                                       children: [Node(text: "Folded", isCollapsed: true, children: [deep])]))
        let otherURL = folder.appendingPathComponent("Other.mindmap")
        try MapLinkTests.writeMap(other, to: otherURL)

        var source = Node(text: "Open Other")
        source.link = .map(MapReference(relativePath: "Other.mindmap", targetTopicID: deep.id))
        let main = MindMap(root: Node(text: "Main", layoutStyle: .rightMap, children: [source]))
        let mainURL = folder.appendingPathComponent("Main.mindmap")
        try MapLinkTests.writeMap(main, to: mainURL)

        let harness = try await CanvasEventHarness(realDocumentAt: mainURL)
        let mainWindow = harness.window
        let editor = harness.editor
        #expect(editor.documentURL.map(LaunchEnvironment.key) == LaunchEnvironment.key(mainURL))
        defer {
            for url in [otherURL, mainURL] { MapTabOpener.document(for: url)?.close() }
        }
        let documentsBefore = NSDocumentController.shared.documents.count

        // Cmd+click on the linked topic: selects only, no new document.
        let title = CGPoint(x: harness.screenFrame(of: source.id).maxX - 12, y: harness.center(of: source.id).y)
        try await harness.send(.leftMouseDown, at: title, modifiers: .command)
        try await harness.send(.leftMouseUp, at: title, modifiers: .command)
        try await harness.wait(800)
        #expect(editor.selectedIDs.contains(source.id))
        #expect(NSDocumentController.shared.documents.count == documentsBefore)
        #expect(MapTabOpener.document(for: otherURL) == nil)

        // Click on its map-link icon: opens the map.
        try await harness.click(iconPoint(harness, source.id))
        try await harness.wait(1500)

        let otherDocument = try #require(MapTabOpener.document(for: otherURL))
        let otherWindow = try #require(otherDocument.windowControllers.first?.window)
        #expect(otherWindow !== mainWindow)
        #expect(NSDocumentController.shared.documents.count == documentsBefore + 1)
        #expect((mainWindow.tabbedWindows ?? []).contains { $0 === otherWindow })
        #expect(mainWindow.tabGroup?.selectedWindow === otherWindow)
        // Opened at the target topic: selected, its collapsed parent expanded.
        let otherEditor = try #require(EditorController.debugInstances.compactMap(\.editor).first {
            $0.documentURL.map(LaunchEnvironment.key) == LaunchEnvironment.key(otherURL) })
        #expect(otherEditor.selectedID == deep.id)
        #expect(otherEditor.model.map.collapsedAncestors(of: deep.id).isEmpty)
        #expect(MapRevealCenter.shared.pending(for: otherURL) == nil)

        // Back to the first tab, click the icon again: the existing tab comes to
        // the front, nothing is opened twice.
        mainWindow.makeKeyAndOrderFront(nil)
        try await harness.wait(400)
        #expect(mainWindow.tabGroup?.selectedWindow === mainWindow)
        otherEditor.select(nil)
        // The tab bar took some height: the canvas moved.
        try await harness.click(iconPoint(harness, source.id))
        try await harness.wait(1000)
        #expect(editor.selectedID == source.id)
        #expect(NSDocumentController.shared.documents.count == documentsBefore + 1)
        #expect(mainWindow.tabGroup?.selectedWindow === otherWindow)
        #expect((mainWindow.tabbedWindows ?? []).count == 2)
        #expect(otherEditor.selectedID == deep.id) // revealed again
    }

    /// Center of the link icon drawn before the topic's title.
    private func iconPoint(_ harness: CanvasEventHarness, _ id: UUID) throws -> CGPoint {
        let editor = harness.editor
        let info = try #require(editor.scene.nodes[id])
        let scale = editor.viewport.scale
        let frame = harness.screenFrame(of: id)
        let icon = LinkIconMetrics.iconSize(fontSize: info.appearance.fontSize) * scale
        return CGPoint(x: frame.minX + info.appearance.paddingH * scale + icon / 2, y: frame.midY)
    }
}
#endif
