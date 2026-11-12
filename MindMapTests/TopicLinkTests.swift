import CoreGraphics
import Foundation
import Testing
@testable import MindMap

/// WP7 topic links: model ops + undo, JSON, broken links, Go to / Back,
/// URL normalisation, node size, link editor candidates, picking.
struct TopicLinkTests {
    /// Central -> [Alpha, Beta (collapsed) -> [Gamma -> [Delta]]], floating "Free".
    static func makeMap() -> (map: MindMap, root: UUID, alpha: UUID, beta: UUID, gamma: UUID, delta: UUID, free: UUID) {
        let delta = Node(text: "Delta")
        let gamma = Node(text: "Gamma", isCollapsed: true, children: [delta])
        let beta = Node(text: "Beta", isCollapsed: true, children: [gamma])
        let alpha = Node(text: "Alpha")
        let root = Node(text: "Central", layoutStyle: .rightMap, children: [alpha, beta])
        let free = Node(text: "Free")
        let map = MindMap(root: root, floatingTopics: [FloatingTopic(node: free, position: CGPoint(x: 0, y: 300))])
        return (map, root.id, alpha.id, beta.id, gamma.id, delta.id, free.id)
    }

    private static let url = URL(string: "https://example.com/docs")!

    // MARK: Model ops + undo

    @Test func setEditRemoveLinkAreSingleUndoSteps() throws {
        let t = Self.makeMap()
        let model = MindMapModel(map: t.map)
        let undo = UndoTests.makeUndoManager()
        #expect(model.setLink(.web(Self.url), for: t.alpha, undoManager: undo))
        #expect(undo.undoActionName == "Add Link")
        #expect(model.map.link(of: t.alpha) == .web(Self.url))
        #expect(model.setLink(.topic(t.delta), for: t.alpha, undoManager: undo))
        #expect(undo.undoActionName == "Edit Link")
        #expect(model.removeLink(from: t.alpha, undoManager: undo))
        #expect(undo.undoActionName == "Remove Link")
        #expect(model.map.link(of: t.alpha) == nil)
        undo.undo()
        #expect(model.map.link(of: t.alpha) == .topic(t.delta))
        undo.undo()
        #expect(model.map.link(of: t.alpha) == .web(Self.url))
        undo.undo()
        #expect(model.map == t.map)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(model.map.link(of: t.alpha) == .web(Self.url))
    }

    @Test func invalidOrUnchangedLinksAreRejected() {
        let t = Self.makeMap()
        let model = MindMapModel(map: t.map)
        let undo = UndoTests.makeUndoManager()
        #expect(!model.setLink(.topic(t.alpha), for: t.alpha, undoManager: undo)) // self
        #expect(!model.setLink(.topic(UUID()), for: t.alpha, undoManager: undo)) // missing target
        #expect(!model.setLink(.web(Self.url), for: UUID(), undoManager: undo)) // missing topic
        #expect(!model.removeLink(from: t.alpha, undoManager: undo)) // nothing to remove
        #expect(model.setLink(.topic(t.free), for: t.alpha, undoManager: undo)) // floating target
        #expect(!model.setLink(.topic(t.free), for: t.alpha, undoManager: undo)) // unchanged
        #expect(model.setLink(.topic(t.root), for: t.free, undoManager: undo)) // from a floating topic
        #expect(!undo.canRedo)
    }

    // MARK: JSON

    @Test func jsonRoundTripAndShape() throws {
        let t = Self.makeMap()
        let model = MindMapModel(map: t.map)
        model.setLink(.web(Self.url), for: t.alpha, undoManager: nil)
        model.setLink(.topic(t.delta), for: t.free, undoManager: nil)
        let data = try JSONEncoder().encode(model.map)
        let decoded = try JSONDecoder().decode(MindMap.self, from: data)
        #expect(decoded == model.map)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""kind":"web""#) && json.contains(#""kind":"topic""#))
        #expect(json.contains(#""url":"https:\/\/example.com\/docs""#))
        #expect(json.contains(#""topicID":"\#(t.delta.uuidString)""#))
        // Topics without a link do not write the key.
        let plain = try JSONEncoder().encode(Node(text: "x"))
        #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("link"))
    }

    @Test func oldAndUnknownLinkJSONDecodeTolerantly() throws {
        let id = UUID()
        let old = #"{"id":"\#(id.uuidString)","text":"Old"}"#
        let node = try JSONDecoder().decode(Node.self, from: Data(old.utf8))
        #expect(node.link == nil && node.text == "Old")
        // A future link kind ("file") or a bad value: no link for this
        // version (kept verbatim for saving, see MapLinkTests), rest intact.
        for link in [#"{"kind":"file","path":"a.pdf"}"#, #"{"kind":"web"}"#, #""https://x.com""#,
                     #"{"kind":"topic","topicID":"nope"}"#] {
            let json = #"{"id":"\#(id.uuidString)","text":"T","link":\#(link),"children":[{"id":"\#(UUID().uuidString)"}]}"#
            let decoded = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
            #expect(decoded.link?.isKnown != true && decoded.text == "T" && decoded.children.count == 1)
            #expect(MindMap(root: decoded).link(of: id) == nil)
        }
        let web = #"{"id":"\#(id.uuidString)","link":{"kind":"web","url":"mailto:a@b.com"}}"#
        #expect(try JSONDecoder().decode(Node.self, from: Data(web.utf8)).link == .web(URL(string: "mailto:a@b.com")!))
    }

    // MARK: Broken links

    @Test func deletingTargetLeavesBrokenLinkUntilUndo() throws {
        let t = Self.makeMap()
        let model = MindMapModel(map: t.map)
        let undo = UndoTests.makeUndoManager()
        model.setLink(.topic(t.gamma), for: t.alpha, undoManager: undo)
        #expect(model.map.resolvedLink(of: t.alpha) == .topic(t.gamma))
        #expect(model.delete(t.beta, undoManager: undo)) // removes Gamma with its parent
        #expect(model.map.link(of: t.alpha) == .topic(t.gamma)) // kept
        #expect(model.map.resolvedLink(of: t.alpha) == .brokenTopic(t.gamma))
        let alpha = try #require(model.map.node(withID: t.alpha))
        let summary = try #require(LinkSummary(of: alpha, in: model.map))
        #expect(summary.isBroken && summary.tooltip == "Target topic was deleted" && summary.kind == .topic)
        undo.undo()
        #expect(model.map.resolvedLink(of: t.alpha) == .topic(t.gamma))
        #expect(LinkSummary(of: alpha, in: model.map)?.isBroken == false)
    }

    @Test func goToBrokenLinkShowsNotice() {
        let t = Self.makeMap()
        let editor = EditorController(model: MindMapModel(map: t.map))
        editor.undoManager = UndoTests.makeUndoManager()
        editor.model.setLink(.topic(t.free), for: t.alpha, undoManager: nil)
        editor.model.delete(t.free, undoManager: nil)
        editor.goToLink(of: t.alpha)
        #expect(editor.linkMessage == "Target topic was deleted")
        #expect(editor.selectedID == t.alpha)
        #expect(editor.navigationHistory.isEmpty)
    }

    // MARK: Navigation

    @Test func goToTopicExpandsAncestorsInOneStepAndBackReturns() throws {
        let t = Self.makeMap()
        let editor = EditorController(model: MindMapModel(map: t.map))
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        editor.updateViewSize(CGSize(width: 800, height: 600))
        editor.model.setLink(.topic(t.delta), for: t.alpha, undoManager: nil)
        #expect(editor.scene.nodes[t.delta] == nil)
        #expect(editor.model.map.collapsedAncestors(of: t.delta) == [t.gamma, t.beta])
        editor.select(t.alpha)
        editor.goToLink()
        #expect(editor.selectedID == t.delta)
        #expect(editor.model.map.node(withID: t.beta)?.isCollapsed == false)
        #expect(editor.model.map.node(withID: t.gamma)?.isCollapsed == false)
        #expect(editor.scene.nodes[t.delta] != nil)
        #expect(undo.undoActionName == "Show Topic")
        // Target is now on screen.
        let frame = editor.viewport.toScreen(try #require(editor.scene.layout.frames[t.delta]))
        #expect(CGRect(origin: .zero, size: editor.viewSize).contains(frame))
        #expect(editor.backTargetID == t.alpha)
        #expect(editor.commandState.canGoBack)
        #expect(editor.perform(.goBack))
        #expect(editor.selectedID == t.alpha)
        #expect(editor.backTargetID == nil)
        #expect(!editor.perform(.goBack))
        // One undo step re-collapses both ancestors.
        undo.undo()
        #expect(editor.model.map.node(withID: t.beta)?.isCollapsed == true)
        #expect(editor.model.map.node(withID: t.gamma)?.isCollapsed == true)
        // Already visible target: no extra undo step.
        editor.model.setLink(.topic(t.free), for: t.alpha, undoManager: nil)
        #expect(undo.canRedo)
        editor.goToLink(of: t.alpha)
        #expect(editor.selectedID == t.free)
        #expect(undo.canRedo) // nothing registered (it would clear redo)
    }

    @Test func backSkipsDeletedTopicsAndChainsJumps() {
        let t = Self.makeMap()
        let editor = EditorController(model: MindMapModel(map: t.map))
        editor.undoManager = UndoTests.makeUndoManager()
        let model = editor.model
        model.setLink(.topic(t.free), for: t.alpha, undoManager: nil)
        model.setLink(.topic(t.root), for: t.free, undoManager: nil)
        editor.goToLink(of: t.alpha) // alpha -> free
        editor.goToLink(of: t.free) // free -> root
        #expect(editor.selectedID == t.root)
        #expect(editor.navigationHistory.entries == [t.alpha, t.free])
        model.delete(t.free, undoManager: nil)
        #expect(editor.backTargetID == t.alpha)
        editor.goBack()
        #expect(editor.selectedID == t.alpha)
        #expect(editor.navigationHistory.isEmpty)
    }

    @Test func historyPushDedupesAndIsBounded() {
        var history = TopicNavigationHistory()
        let a = UUID(), b = UUID()
        history.push(a)
        history.push(a)
        history.push(b)
        #expect(history.entries == [a, b])
        #expect(history.pop { _ in true } == b)
        #expect(history.pop { $0 != a } == nil)
        #expect(history.isEmpty)
        for _ in 0..<(TopicNavigationHistory.limit + 10) { history.push(UUID()) }
        #expect(history.entries.count == TopicNavigationHistory.limit)
    }

    @Test func goToWebLinkOpensURL() {
        let t = Self.makeMap()
        let editor = EditorController(model: MindMapModel(map: t.map))
        var opened: [URL] = []
        editor.openURL = { opened.append($0) }
        editor.model.setLink(.web(Self.url), for: t.alpha, undoManager: nil)
        editor.goToLink(of: t.alpha)
        #expect(opened == [Self.url])
        #expect(editor.selectedID == t.alpha)
        #expect(editor.navigationHistory.isEmpty)
        // No link: nothing happens.
        editor.goToLink(of: t.root)
        #expect(opened.count == 1)
    }

    @Test func viewportFocusingCentersOffscreenRect() {
        let viewport = Viewport(scale: 1, offset: CGPoint(x: 400, y: 300))
        let size = CGSize(width: 800, height: 600)
        let visible = CGRect(x: -50, y: -20, width: 100, height: 40)
        #expect(viewport.focusing(visible, in: size) == viewport)
        let far = CGRect(x: 2000, y: 900, width: 100, height: 40)
        let moved = viewport.focusing(far, in: size)
        let center = moved.toScreen(CGPoint(x: far.midX, y: far.midY))
        #expect(approx(center.x, 400) && approx(center.y, 300) && moved.scale == 1)
        // Zoomed far out: zooms in to a readable scale.
        let tiny = Viewport(scale: 0.25, offset: CGPoint(x: 400, y: 300)).focusing(visible, in: size)
        #expect(tiny.scale == 0.6)
    }

    // MARK: URL normalisation

    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("  www.apple.com/mac  ", "https://www.apple.com/mac"),
        ("http://x.org/a?b=1#c", "http://x.org/a?b=1#c"),
        ("HTTPS://Example.com", "HTTPS://Example.com"),
        ("localhost:8080/api", "https://localhost:8080/api"),
        ("example.com:8443", "https://example.com:8443"),
        ("//cdn.site.io/x", "https://cdn.site.io/x"),
        ("mailto:me@example.com", "mailto:me@example.com"),
        ("obsidian://open?vault=a", "obsidian://open?vault=a"),
        ("192.168.0.1", "https://192.168.0.1"),
    ])
    func normalizesURLs(input: String, expected: String) {
        #expect(LinkURL.normalize(input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "nohost", "https://", "http:// spaced.com", "mailto:", "https://exa mple.com"])
    func rejectsInvalidURLs(input: String) {
        #expect(LinkURL.normalize(input) == nil)
    }

    @Test func urlDisplayString() {
        #expect(LinkURL.displayString(URL(string: "https://www.example.com/")!) == "example.com")
        #expect(LinkURL.displayString(URL(string: "http://a.io/x/y")!) == "a.io/x/y")
        #expect(LinkURL.displayString(URL(string: "mailto:a@b.c")!) == "mailto:a@b.c")
    }

    // MARK: Node size / scene

    @Test func nodeSizeIncludesLinkIcon() throws {
        let measurer = NodeMeasurer()
        let appearance = NodeAppearance.resolve(shape: nil, border: nil, level: 1, colorHex: "#EE7471")
        let plain = measurer.nodeSize(text: "Topic", appearance: appearance)
        let linked = measurer.nodeSize(text: "Topic", appearance: appearance, hasLink: true)
        #expect(approx(linked.width - plain.width, LinkIconMetrics.width(fontSize: appearance.fontSize)))
        #expect(linked.height >= plain.height)
        #expect(LinkIconMetrics.width(fontSize: appearance.fontSize) > LinkIconMetrics.iconSize(fontSize: appearance.fontSize))

        let t = Self.makeMap()
        let model = MindMapModel(map: t.map)
        let before = MapScene.build(map: model.map, measurer: measurer, editing: nil)
        model.setLink(.web(Self.url), for: t.alpha, undoManager: nil)
        let after = MapScene.build(map: model.map, measurer: measurer, editing: nil)
        let info = try #require(after.nodes[t.alpha]?.link)
        #expect(info.kind == .web && info.tooltip == Self.url.absoluteString && info.systemImage == "link")
        let widthBefore = try #require(before.layout.frames[t.alpha]?.width)
        let widthAfter = try #require(after.layout.frames[t.alpha]?.width)
        let fontSize = try #require(after.nodes[t.alpha]?.appearance.fontSize)
        #expect(approx(widthAfter - widthBefore, LinkIconMetrics.width(fontSize: fontSize)))
        #expect(after.nodes[t.root]?.link == nil)
    }

    @Test func topicLinkTooltipIsTargetPath() throws {
        let t = Self.makeMap()
        let model = MindMapModel(map: t.map)
        model.setLink(.topic(t.delta), for: t.free, undoManager: nil)
        let scene = MapScene.build(map: model.map, measurer: NodeMeasurer(), editing: nil)
        let link = try #require(scene.nodes[t.free]?.link)
        #expect(link.kind == .topic && !link.isBroken && link.systemImage == "arrow.turn.down.right")
        #expect(link.tooltip == "Central › Beta › Gamma › Delta")
    }

    // MARK: Link editor candidates

    @Test func candidatesListAllTopicsWithPathsAndSearch() {
        let t = Self.makeMap()
        let all = t.map.linkCandidates(excluding: t.alpha)
        #expect(all.map(\.text) == ["Central", "Beta", "Gamma", "Delta", "Free"])
        #expect(all.first { $0.id == t.delta }?.breadcrumb == "Central › Beta › Gamma")
        #expect(all.first { $0.id == t.free }?.breadcrumb == "")
        // Search matches text or path, case/diacritic insensitive.
        #expect(t.map.linkCandidates(matching: "gam").map(\.id) == [t.gamma, t.delta])
        #expect(t.map.linkCandidates(matching: "BÉTA").map(\.id) == [t.beta, t.gamma, t.delta])
        #expect(t.map.linkCandidates(matching: "zzz").isEmpty)
        #expect(LinkCandidate.displayText("  \n") == "Untitled Topic")
        #expect(LinkCandidate.displayText("Two\nlines") == "Two")
    }

    // MARK: Editor actions

    @Test func pickOnCanvasSetsTopicLink() {
        let t = Self.makeMap()
        let editor = EditorController(model: MindMapModel(map: t.map))
        let undo = UndoTests.makeUndoManager()
        editor.undoManager = undo
        editor.beginEditLink(t.alpha)
        #expect(editor.linkEditor?.nodeID == t.alpha)
        editor.beginLinkPick(for: t.alpha)
        #expect(editor.linkEditor == nil)
        #expect(editor.pickMode == .link(from: t.alpha))
        #expect(editor.pickMode?.drawsRubberBand == true)
        #expect(editor.completePick(t.alpha)) // self: consumed, nothing set
        #expect(editor.model.map.link(of: t.alpha) == nil)
        editor.beginLinkPick(for: t.alpha)
        #expect(editor.perform(.cancel))
        #expect(editor.pickMode == nil)
        editor.beginLinkPick(for: t.alpha)
        #expect(editor.completePick(t.free))
        #expect(editor.model.map.link(of: t.alpha) == .topic(t.free))
        #expect(editor.selectedID == t.alpha)
        #expect(undo.undoActionName == "Add Link")
        #expect(editor.commandState.selectionHasLink)
        editor.removeLink()
        #expect(editor.model.map.link(of: t.alpha) == nil)
    }

    @Test func keyboardShortcuts() {
        #expect(KeyCommandMap.command(key: "k", modifiers: .command, characters: "k") == .editLink)
        #expect(KeyCommandMap.command(key: "[", modifiers: .command, characters: "[") == .goBack)
        #expect(KeyCommandMap.command(key: "k", modifiers: [], characters: "k") == .editReplacing("k"))
        let t = Self.makeMap()
        let editor = EditorController(model: MindMapModel(map: t.map))
        #expect(!editor.perform(.editLink)) // no selection
        editor.select(t.alpha)
        #expect(editor.perform(.editLink))
        #expect(editor.linkEditor?.nodeID == t.alpha)
    }
}
