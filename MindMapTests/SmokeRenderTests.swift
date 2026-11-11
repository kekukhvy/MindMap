import SwiftUI
import Testing
@testable import MindMap

/// Smoke test: a new document's canvas renders (off-screen ImageRenderer,
/// no interaction). On macOS the PNG goes to the temp directory.
@MainActor
struct SmokeRenderTests {
    @Test func newDocumentCanvasRenders() throws {
        let document = MindMapDocument()
        let editor = EditorController(model: document.model)
        editor.updateViewSize(CGSize(width: 800, height: 500))
        let undo = UndoManager()
        editor.undoManager = undo
        editor.select(document.model.root.id)
        editor.addChild()
        editor.draftText = "A fairly long topic text that has to wrap onto several lines inside the node"
        editor.commitEditing()
        editor.addSibling()
        editor.commitEditing()
        #expect(editor.scene.order.count == 3)

        let view = CanvasView(editor: editor).frame(width: 800, height: 500)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 1600 && image.height == 1000)
        #if os(macOS)
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mindmap-new-document.png")
        try data.write(to: url)
        print("SNAPSHOT \(url.path)")
        #endif
    }
}
