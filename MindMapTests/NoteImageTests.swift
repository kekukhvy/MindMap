import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MindMap

/// Images pasted or dropped into a Markdown note.
struct NoteImageTests {
    /// A real 1200x800 PNG drawn with CoreGraphics.
    static func samplePNG(width: Int = 1200, height: Int = 800) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(8)
        context.strokeEllipse(in: CGRect(x: 200, y: 150, width: 800, height: 500))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private func undoManager() -> UndoManager { UndoTests.makeUndoManager() }

    /// A model with one topic holding a note with `text`.
    private func makeModel(text: String = "intro") throws -> (model: MindMapModel, note: UUID, topic: UUID) {
        let model = MindMapModel()
        let topic = try #require(model.addChild(to: model.root.id, text: "Topic", undoManager: nil))
        let note = try #require(model.addNote(to: topic, text: text, undoManager: nil))
        return (model, note, topic)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NoteImage-\(UUID().uuidString)")
            .appendingPathExtension("mindmap")
    }

    @discardableResult
    private func save(_ model: MindMapModel, to url: URL, previous: URL? = nil) throws -> FileWrapper {
        let existing = try previous.map { try FileWrapper(url: $0) }
        let wrapper = try model.savePlan().fileWrapper(existing: existing)
        try wrapper.write(to: url, options: .atomic, originalContentsURL: previous)
        return wrapper
    }

    private func attachmentNames(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("attachments").path)) ?? []).sorted()
    }

    /// Pastes the sample image and writes the link into the note, as the editor does.
    private func paste(_ png: Data, into note: UUID, of model: MindMapModel) throws -> (link: String, name: String) {
        let link = try #require(model.addNoteImage(png, to: note))
        let text = MarkdownNote.text(model.content(of: note))
        let inserted = NoteImage.inserting(link, into: text, selection: NSRange(location: text.utf16.count, length: 0))
        model.setAttachmentContent(MarkdownNote.data(inserted.text), for: note, undoManager: nil)
        let name = try #require(NoteImage.fileName(fromLinkTarget: String(link.dropFirst(4).dropLast())))
        return (link, name)
    }

    // AC-img-1
    @Test func pastingAPNGStoresItUnderTheNoteAndInsertsTheLinkAtTheCursor() throws {
        let (model, note, _) = try makeModel(text: "before after")
        let png = Self.samplePNG()
        let link = try #require(model.addNoteImage(png, to: note))
        let images = model.attachmentStore.noteImages(of: note)
        let name = try #require(images.keys.first)
        #expect(images.count == 1 && images[name] == png)
        #expect(name.hasPrefix("\(note.uuidString)-img-") && name.hasSuffix(".png"))
        #expect(link == "![](attachments/\(name))")
        // At the cursor, on its own line.
        let middle = NoteImage.inserting(link, into: "before after", selection: NSRange(location: 7, length: 0))
        #expect(middle.text == "before \n\(link)\nafter")
        #expect(middle.caret == "before \n\(link)\n".utf16.count)
        let start = NoteImage.inserting(link, into: "a\nb", selection: NSRange(location: 2, length: 0))
        #expect(start.text == "a\n\(link)\nb")
        let end = NoteImage.inserting(link, into: "a\n", selection: NSRange(location: 2, length: 0))
        #expect(end.text == "a\n\(link)")
        // A TIFF is stored as PNG.
        let tiff = NSMutableData()
        let source = CGImageSourceCreateWithData(png as CFData, nil)!
        let destination = CGImageDestinationCreateWithData(tiff, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, CGImageSourceCreateImageAtIndex(source, 0, nil)!, nil)
        CGImageDestinationFinalize(destination)
        #expect(NoteImage.storable(tiff as Data)?.fileExtension == "png")
        #expect(NoteImage.storable(Data("not an image".utf8)) == nil)
    }

    // AC-img-2
    @Test func theImageSurvivesSaveAndReopenWithoutAnAttachmentRecord() throws {
        let (model, note, _) = try makeModel()
        let png = Self.samplePNG()
        let (_, name) = try paste(png, into: note, of: model)
        #expect(!model.map.allAttachments.contains { $0.fileName == name })
        let first = tempURL(), second = tempURL()
        defer { [first, second].forEach { try? FileManager.default.removeItem(at: $0) } }
        try save(model, to: first)
        #expect(attachmentNames(first).contains(name))

        let reopened = MindMapModel()
        try reopened.load(package: try FileWrapper(url: first))
        #expect(reopened.attachmentStore.data(for: name) == png)
        #expect(MarkdownNote.text(reopened.content(of: note)).contains("attachments/\(name)"))
        // A second save of the reopened map keeps it, too.
        try save(reopened, to: second, previous: first)
        #expect(try Data(contentsOf: second.appendingPathComponent("attachments/\(name)")) == png)
    }

    // AC-img-3
    @Test func deletingTheNoteDropsItsImages() throws {
        let (model, note, _) = try makeModel()
        let (_, name) = try paste(Self.samplePNG(), into: note, of: model)
        let undo = undoManager()
        let first = tempURL(), second = tempURL(), third = tempURL()
        defer { [first, second, third].forEach { try? FileManager.default.removeItem(at: $0) } }
        try save(model, to: first)
        #expect(model.removeAttachment(note, undoManager: undo))
        try save(model, to: second, previous: first)
        #expect(attachmentNames(second).isEmpty)
        // Undo brings the note and its image back.
        undo.undo()
        try save(model, to: third, previous: second)
        #expect(attachmentNames(third).contains(name))
    }

    // AC-img-4, AC-img-8
    @Test func aLockedNoteKeepsItsImagesAndTakesNoNewOnes() throws {
        let (model, note, _) = try makeModel()
        model.lock.services = LockServices(keyStore: InMemoryKeyStore(), authenticator: MockAuthenticator())
        let (_, name) = try paste(Self.samplePNG(), into: note, of: model)
        try model.lockNote(note, undoManager: nil)
        let before = model.attachmentStore.noteImages(of: note)
        #expect(model.addNoteImage(Self.samplePNG(width: 300, height: 200), to: note) == nil)
        #expect(model.attachmentStore.noteImages(of: note) == before)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try save(model, to: url)
        #expect(attachmentNames(url).contains(name))
        #expect(attachmentNames(url).count == 2)
    }

    // AC-img-5
    @Test func previewResolvesAnAttachmentsLinkAndFallsBackToTheAltText() throws {
        let (model, note, _) = try makeModel()
        let png = Self.samplePNG()
        let (_, name) = try paste(png, into: note, of: model)
        let markdown = "Title\n![shot](attachments/\(name))\n![gone](attachments/missing.png)\n![web](https://a.b/x.png)"
        let blocks = MarkdownBlock.parse(markdown)
        #expect(blocks == [.paragraph("Title"), .image(alt: "shot", fileName: name),
                           .image(alt: "gone", fileName: "missing.png"), .paragraph("![web](https://a.b/x.png)")])
        // The image resolves to the stored bytes and decodes to its real size.
        let data = try #require(model.attachmentStore.data(for: name))
        #expect(MarkdownPreview.image(from: data)?.1 == CGSize(width: 1200, height: 800))
        // A missing file has no data: the alt text is shown, and nothing crashes.
        #expect(model.attachmentStore.data(for: "missing.png") == nil)
        #expect(MarkdownBlock.inlineSource("![gone](attachments/missing.png)") == "🖼 gone")
        #expect(MarkdownPreview.image(from: Data("junk".utf8)) == nil)
    }

    // AC-img-6
    @Test func copyingATopicWithAnImageNoteCarriesTheImageToAnotherMap() throws {
        let (source, note, topic) = try makeModel()
        let png = Self.samplePNG()
        let (_, name) = try paste(png, into: note, of: source)
        let clip = try #require(source.clipboard(for: [topic]))
        let decoded = try #require(TopicClipboard.decode(try clip.encoded()))

        let target = MindMapModel()
        let ids = target.paste(decoded, into: target.root.id, undoManager: nil)
        let pastedTopic = try #require(ids.first)
        let pasted = try #require(target.map.node(withID: pastedTopic)?.attachments.first)
        #expect(pasted.id != note)
        let images = target.attachmentStore.noteImages(of: pasted.id)
        let newName = try #require(images.keys.first)
        #expect(images[newName] == png)
        #expect(newName.hasPrefix("\(pasted.id.uuidString)-img-") && newName != name)
        let text = MarkdownNote.text(target.content(of: pasted.id))
        #expect(text.contains("![](attachments/\(newName))") && !text.contains(name))
        #expect(target.attachmentStore.noteImages(of: note).isEmpty)
        // The original is untouched.
        #expect(MarkdownNote.text(source.content(of: note)).contains(name))
    }
}
