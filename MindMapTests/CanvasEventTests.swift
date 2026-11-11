#if os(macOS)
import AppKit
import ObjectiveC
import SwiftUI
import Testing
@testable import MindMap

/// Window that acts as key although the hosted test app is inactive.
final class KeyTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}

/// Accepts the first click (the inactive test app would otherwise eat it).
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Drives the REAL SwiftUI canvas with synthesized mouse events: either a
/// bare `CanvasView` in a test window, or a real DocumentGroup document
/// window (`realDocument()`: toolbar, ContentView, menus, event monitors;
/// events go through the app's event queue). Exercises the actual gesture
/// recognizers / hit-testing without UI-test automation permission.
@MainActor
final class CanvasEventHarness {
    let editor: EditorController
    let undo = UndoManager()
    let window: NSWindow
    /// Real window: events are queued (local monitors run) instead of sent.
    private let queued: Bool
    private var time: TimeInterval = ProcessInfo.processInfo.systemUptime

    init(map: MindMap) async throws {
        editor = EditorController(model: MindMapModel(map: map))
        let size = CGSize(width: 900, height: 600)
        window = KeyTestWindow(contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: size),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = FirstMouseHostingView(rootView: CanvasView(editor: editor)
            .frame(width: size.width, height: size.height))
        queued = false
        undo.groupsByEvent = false
        editor.undoManager = undo
        window.makeKeyAndOrderFront(nil)
        try await wait(400)
    }

    /// New untitled document in a real document window, its map replaced by `map`.
    init(realDocumentWith map: MindMap) async throws {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSDocumentController.shared.newDocument(nil)
        try await Task.sleep(for: .milliseconds(800))
        window = try #require(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.isVisible
            && $0.contentView != nil && $0.frame.width > 300 })
        editor = try #require(EditorController.debugInstances.compactMap(\.editor).last)
        queued = true
        window.setContentSize(CGSize(width: 1000, height: 700))
        Self.forceKey(window)
        window.makeKeyAndOrderFront(nil)
        editor.model.debugReplaceMap(map)
        editor.select(nil)
        undo.groupsByEvent = false
        editor.undoManager = undo
        try await wait(500)
        editor.viewport = Viewport(scale: 1, offset: CGPoint(x: editor.viewSize.width / 3,
                                                              y: editor.viewSize.height / 2))
        try await wait(200)
    }

    /// Makes an existing window act as key and all its views accept the
    /// first click although the hosted test app is not frontmost.
    private static func forceKey(_ window: NSWindow) {
        let base: AnyClass = type(of: window)
        let name = "KeyForced_\(NSStringFromClass(base))"
        var cls: AnyClass? = NSClassFromString(name)
        if cls == nil, let made = objc_allocateClassPair(base, name, 0) {
            let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
            let imp = imp_implementationWithBlock(yes)
            class_addMethod(made, #selector(getter: NSWindow.isKeyWindow), imp, "c@:")
            class_addMethod(made, #selector(getter: NSWindow.canBecomeKey), imp, "c@:")
            objc_registerClassPair(made)
            cls = made
        }
        if let cls { object_setClass(window, cls) }
        func patch(_ view: NSView) {
            let yes: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
            class_replaceMethod(type(of: view), #selector(NSView.acceptsFirstMouse(for:)),
                                imp_implementationWithBlock(yes), "c@:@")
            view.subviews.forEach(patch)
        }
        if let frame = window.contentView?.superview { patch(frame) }
    }

    func close() {
        if queued { editor.model.debugReplaceMap(MindMap()) }
        window.close()
    }

    func wait(_ milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// Screen (canvas) center of a topic.
    func center(of id: UUID) -> CGPoint {
        let frame = editor.viewport.toScreen(editor.scene.layout.frames[id]!)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    func screenFrame(of id: UUID) -> CGRect {
        editor.viewport.toScreen(editor.scene.layout.frames[id]!)
    }

    func send(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1,
              modifiers: NSEvent.ModifierFlags = []) async throws {
        time += 0.016
        // The canvas fills the content view below the toolbar (top inset).
        let canvasHeight = editor.viewSize.height
        let location = CGPoint(x: point.x, y: canvasHeight - point.y)
        let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: time,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
        if queued { NSApp.postEvent(event, atStart: false) } else { NSApp.sendEvent(event) }
        try await wait(16)
    }

    func click(_ point: CGPoint, count: Int = 1) async throws {
        for index in 1...count {
            try await send(.leftMouseDown, at: point, clicks: index)
            try await send(.leftMouseUp, at: point, clicks: index)
        }
        try await wait(500)
    }

    /// Press at `from`, move in steps to `to`; `check` runs before release.
    func drag(from: CGPoint, to: CGPoint, steps: Int = 12, modifiers: NSEvent.ModifierFlags = [],
              beforeRelease check: () -> Void = {}) async throws {
        try await send(.leftMouseDown, at: from, modifiers: modifiers)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            try await send(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t,
                                                          y: from.y + (to.y - from.y) * t), modifiers: modifiers)
        }
        try await wait(50)
        check()
        try await send(.leftMouseUp, at: to, modifiers: modifiers)
        try await wait(400)
    }
}

/// Real-event gesture tests on macOS (see `CanvasEventHarness`).
@MainActor
@Suite(.serialized)
struct CanvasEventTests {
    private func harness(_ map: MindMap, _ real: Bool) async throws -> CanvasEventHarness {
        real ? try await CanvasEventHarness(realDocumentWith: map) : try await CanvasEventHarness(map: map)
    }

    private func makeMap() -> (MindMap, root: UUID, a: UUID, b: UUID, c: UUID) {
        let a = Node(text: "Alpha"), b = Node(text: "Beta"), c = Node(text: "Gamma")
        let root = Node(text: "Central", layoutStyle: .rightMap, children: [a, b, c])
        return (MindMap(root: root), root.id, a.id, b.id, c.id)
    }

    @Test(arguments: [false, true]) func dragTopicOntoSiblingCenterReparents(real: Bool) async throws {
        let (map, _, a, b, _) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        var sawDrag = false, sawTarget = false
        try await harness.drag(from: harness.center(of: a), to: harness.center(of: b)) {
            sawDrag = harness.editor.drag?.id == a && harness.editor.drag?.translation != .zero
            sawTarget = harness.editor.drag?.parentTargetID == b
        }
        #expect(sawDrag)
        #expect(sawTarget)
        #expect(harness.editor.drag == nil)
        #expect(harness.editor.model.map.parentID(of: a) == b)
    }

    @Test(arguments: [false, true]) func dragTopicToSiblingEdgeReorders(real: Bool) async throws {
        let (map, root, a, b, c) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        let frame = harness.editor.viewport.toScreen(harness.editor.scene.layout.frames[c]!)
        var placement: DropPlacement?
        try await harness.drag(from: harness.center(of: a), to: CGPoint(x: frame.midX, y: frame.maxY - 2)) {
            placement = harness.editor.drag?.placement
        }
        #expect(placement == .after)
        #expect(harness.editor.model.map.node(withID: root)?.children.map(\.id) == [b, c, a])
    }

    @Test(arguments: [false, true]) func dragTopicToEmptySpaceSnapsBack(real: Bool) async throws {
        let (map, root, a, b, c) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        let start = harness.center(of: a)
        try await harness.drag(from: start, to: CGPoint(x: start.x + 150, y: start.y + 200))
        #expect(harness.editor.model.map.node(withID: root)?.children.map(\.id) == [a, b, c])
        #expect(!harness.undo.canUndo)
    }

    @Test(arguments: [false, true]) func dragFloatingTopicMovesIt(real: Bool) async throws {
        var (map, _, _, _, _) = makeMap()
        let floating = Node(text: "Free")
        map.floatingTopics = [FloatingTopic(node: floating, position: CGPoint(x: 0, y: 200))]
        let harness = try await harness(map, real)
        defer { harness.close() }
        let start = harness.center(of: floating.id)
        try await harness.drag(from: start, to: CGPoint(x: start.x - 100, y: start.y + 40))
        let position = try #require(harness.editor.model.map.floatingTopic(floating.id)?.position)
        #expect(abs(position.x - -100 / harness.editor.viewport.scale) < 3)
        #expect(abs(position.y - (200 + 40 / harness.editor.viewport.scale)) < 3)
    }

    @Test(arguments: [false, true]) func dragBackgroundPans(real: Bool) async throws {
        let (map, root, _, _, _) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        let before = harness.editor.viewport.offset
        try await harness.drag(from: CGPoint(x: 60, y: 60), to: CGPoint(x: 160, y: 110))
        let after = harness.editor.viewport.offset
        #expect(abs(after.x - before.x - 100) < 2 && abs(after.y - before.y - 50) < 2)
        #expect(harness.editor.model.map.node(withID: root)?.children.count == 3)
    }

    @Test(arguments: [false, true]) func clickSelectsAndDoubleClickEditsTopic(real: Bool) async throws {
        let (map, _, a, b, _) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        try await harness.click(harness.center(of: b))
        #expect(harness.editor.selectedID == b)
        #expect(harness.editor.editingID == nil)
        try await harness.click(harness.center(of: a), count: 2)
        #expect(harness.editor.selectedID == a)
        #expect(harness.editor.editingID == a)
    }

    @Test(arguments: [false, true]) func doubleClickEmptyCanvasAddsFloatingTopic(real: Bool) async throws {
        let (map, _, _, _, _) = makeMap()
        let harness = try await harness(map, real)
        defer { harness.close() }
        try await harness.click(CGPoint(x: 80, y: 500), count: 2)
        #expect(harness.editor.model.map.floatingTopics.count == 1)
        #expect(harness.editor.editingID == harness.editor.model.map.floatingTopics.first?.node.id)
    }
}
#endif
