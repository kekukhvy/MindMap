#if os(macOS)
import AppKit
import QuickLookThumbnailing
import QuickLookUI
import Testing
@testable import MindMap

/// Real-event test (see `CanvasEventHarness`): clicking a topic's paperclip
/// in a real document window opens the file window with a QuickLook preview
/// of a temp copy named after the file (QuickLook renders that copy).
@MainActor
@Suite(.serialized)
struct FileWindowEventTests {
    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let found = view as? T { return found }
        for sub in view.subviews {
            if let found = find(type, in: sub) { return found }
        }
        return nil
    }

    /// Fraction of clearly colored (non-gray) pixels.
    private func coverage(_ rep: NSBitmapImageRep) -> Double {
        var colored = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                let spread = max(c.redComponent, c.greenComponent, c.blueComponent)
                    - min(c.redComponent, c.greenComponent, c.blueComponent)
                if spread > 0.2 { colored += 1 }
            }
        }
        return total == 0 ? 0 : Double(colored) / Double(total)
    }

    @Test func clickingPaperclipOpensQuickLookWindow() async throws {
        let topic = Node(text: "Topic with file")
        let map = MindMap(root: Node(text: "Central", layoutStyle: .rightMap, children: [topic]))
        let harness = try await CanvasEventHarness(realDocumentWith: map)
        var closed = false
        defer { if !closed { harness.close() } }
        let model = harness.editor.model
        let pdf = try DebugSampleFiles.writePDF(in: try DebugSampleFiles.folder())
        let file = try #require(try model.importFile(at: pdf, to: topic.id, undoManager: harness.undo))
        try await harness.wait(300)

        let frame = harness.screenFrame(of: topic.id)
        let info = try #require(harness.editor.scene.nodes[topic.id])
        let scale = harness.editor.viewport.scale
        let icon = AttachmentIconRow.iconSize(fontSize: info.appearance.fontSize) * scale
        let point = CGPoint(x: frame.maxX - info.appearance.paddingH * scale - icon / 2, y: frame.midY)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        try await harness.click(point)
        var fileWindow: NSWindow?
        for _ in 0..<30 where fileWindow == nil {
            try await harness.wait(100)
            fileWindow = NSApp.windows.first {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible && find(QLPreviewView.self, in: $0.contentView) != nil
            }
        }
        let window = try #require(fileWindow)
        window.setContentSize(CGSize(width: 700, height: 800))
        #expect(harness.editor.selectedID == topic.id)
        #expect(window.title == "Project Brief.pdf")
        let preview = try #require(find(QLPreviewView.self, in: window.contentView))
        let previewURL = try #require((preview.previewItem as? NSURL) as URL?)
        // A temp copy named after the original file, byte-identical.
        #expect(previewURL.lastPathComponent == "Project Brief.pdf")
        #expect(try Data(contentsOf: previewURL) == model.content(of: file))
        #expect(!previewURL.path.contains(".mindmap"))

        // QuickLook draws out of process (NSRemoteView inside QLPreviewView),
        // which an in-process snapshot cannot capture. Check that the remote
        // view fills the preview, and that QuickLook renders this very copy
        // (thumbnail of the PDF: colored header and bars; PNG for a look).
        let remote = try #require(preview.subviews.first?.subviews.first)
        #expect(String(describing: type(of: remote)).contains("RemoteView"))
        #expect(remote.frame.width >= 600 && remote.frame.height >= 500)
        let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(
            for: QLThumbnailGenerator.Request(fileAt: previewURL, size: CGSize(width: 400, height: 520), scale: 2,
                                              representationTypes: .thumbnail))
        let rep = NSBitmapImageRep(cgImage: thumbnail.cgImage)
        try rep.representation(using: .png, properties: [:])?
            .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("file-window-preview.png"))
        #expect(coverage(rep) > 0.05)

        // Rename from the map side: the window title and the preview copy follow.
        model.renameAttachment(file, to: "Brief v2.pdf", undoManager: harness.undo)
        try await harness.wait(600)
        #expect(window.title == "Brief v2.pdf")
        let renamed = try #require(find(QLPreviewView.self, in: window.contentView))
        #expect(((renamed.previewItem as? NSURL) as URL?)?.lastPathComponent == "Brief v2.pdf")

        harness.undo.removeAllActions()
        harness.close()
        closed = true
        try await harness.wait(800)
        #expect(!window.isVisible)
    }
}
#endif
