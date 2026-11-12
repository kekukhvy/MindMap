import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MindMap

private func makeUndo() -> UndoManager {
    let undo = UndoManager()
    undo.groupsByEvent = false
    return undo
}

/// Temp folder with helpers to make source files.
private final class Sources {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileSources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func file(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Deterministic pseudo-random bytes (not compressible, not all equal).
    static func bytes(_ count: Int, seed: UInt64 = 42) -> Data {
        var state = seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for i in 0..<count {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                buffer[i] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return data
    }
}

private func tempPackageURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("Files-\(UUID().uuidString)").appendingPathExtension("mindmap")
}

/// Saves like the document classes do (snapshot on main, then write).
private func save(_ document: MindMapDocument, to url: URL, previous: URL?) throws {
    let snapshot = try document.snapshot(contentType: .mindMap)
    let existing = try previous.map { try FileWrapper(url: $0) }
    let wrapper = try MindMapDocument.package(for: snapshot, existing: existing)
    try wrapper.write(to: url, options: .atomic, originalContentsURL: previous)
}

/// Opens a package from disk like the macOS document (lazy wrappers).
private func open(_ url: URL) throws -> MindMapDocument {
    let wrapper = try FileWrapper(url: url)
    let map = try MindMapPackage.read(wrapper)
    let document = MindMapDocument(map: map)
    document.model.attachmentStore.reset(package: wrapper, referenced: map.referencedAttachmentFileNames)
    return document
}

private func attachmentFiles(_ url: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("attachments").path)) ?? [])
}

private func fileData(_ package: URL, _ name: String) -> Data? {
    try? Data(contentsOf: package.appendingPathComponent("attachments").appendingPathComponent(name))
}

/// Importing files: exact copies, no big blobs in memory, undo, disk round trips.
struct FileImportTests {
    @Test func importCopiesBytesExactlyAndKeepsTheOriginalName() throws {
        let sources = try Sources()
        let model = MindMapModel()
        let undo = makeUndo()
        let original = Data((0..<1000).map { UInt8($0 % 256) })
        let url = try sources.file("Q3 Report.PDF", original)
        let id = try #require(try model.importFile(at: url, to: model.root.id, undoManager: undo))
        let attachment = try #require(model.attachment(id))
        #expect(attachment.kind == .file)
        #expect(attachment.title == "Q3 Report.PDF")
        #expect(attachment.fileName == "\(id.uuidString).pdf")
        #expect(Attachment.isValidFileName(attachment.fileName))
        #expect(model.content(of: id) == original)
        #expect(undo.undoActionName == "Attach File")
        // The source is untouched (copied, not moved).
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func multiMegabyteImportStaysOnDisk() throws {
        let sources = try Sources()
        let model = MindMapModel()
        let undo = makeUndo()
        let big = Sources.bytes(5 << 20)
        let url = try sources.file("Big Data.bin", big)
        let id = try #require(try model.importFile(at: url, to: model.root.id, undoManager: undo))
        let attachment = try #require(model.attachment(id))
        // Copied into the scratch folder, not loaded into the store's memory.
        #expect(model.attachmentStore.inMemoryByteCount == 0)
        #expect(model.attachmentStore.size(of: attachment.fileName) == big.count)
        let copy = try model.exportCopy(of: id)
        #expect(copy.lastPathComponent == "Big Data.bin")
        #expect(try Data(contentsOf: copy) == big)
        // Saved through a lazily reading wrapper: still nothing in memory.
        _ = model.attachmentStore.prepareSave(referencing: model.map.referencedAttachmentFileNames)
        #expect(model.attachmentStore.inMemoryByteCount == 0)
    }

    @Test func undoRedoOfAddAndRemoveRestoresTheFileOnDisk() throws {
        let sources = try Sources()
        let document = MindMapDocument()
        let model = document.model
        let undo = makeUndo()
        let big = Sources.bytes(3 << 20, seed: 7)
        let id = try #require(try model.importFile(at: try sources.file("scan.tiff", big), to: model.root.id,
                                                   undoManager: undo))
        let name = try #require(model.attachment(id)).fileName
        let urls = (0..<5).map { _ in tempPackageURL() }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        try save(document, to: urls[0], previous: nil)
        #expect(fileData(urls[0], name) == big)
        #expect(model.removeAttachment(id, undoManager: undo))
        #expect(undo.undoActionName == "Remove File")
        try save(document, to: urls[1], previous: urls[0])
        #expect(attachmentFiles(urls[1]).isEmpty)
        undo.undo() // remove
        try save(document, to: urls[2], previous: urls[1])
        #expect(fileData(urls[2], name) == big)
        undo.undo() // attach
        try save(document, to: urls[3], previous: urls[2])
        #expect(attachmentFiles(urls[3]).isEmpty)
        undo.redo() // attach again
        try save(document, to: urls[4], previous: urls[3])
        #expect(fileData(urls[4], name) == big)
        #expect(model.attachmentStore.inMemoryByteCount == 0)
    }

    @Test func largeOrphanOfAnOpenedPackageSurvivesThePackageLosingIt() throws {
        let sources = try Sources()
        let big = Sources.bytes(3 << 20, seed: 99)
        let urls = (0..<3).map { _ in tempPackageURL() }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let first = MindMapDocument()
        let id = try #require(try first.model.importFile(at: try sources.file("video.mov", big),
                                                         to: first.model.root.id, undoManager: makeUndo()))
        try save(first, to: urls[0], previous: nil)

        let document = try open(urls[0])
        let model = document.model
        let undo = makeUndo()
        let name = try #require(model.attachment(id)).fileName
        #expect(model.removeAttachment(id, undoManager: undo))
        try save(document, to: urls[1], previous: urls[0])
        // The original package (and its lazily referenced file) is gone.
        try FileManager.default.removeItem(at: urls[0])
        #expect(attachmentFiles(urls[1]).isEmpty)
        // Retained on disk (scratch), not as a multi-MB Data.
        #expect(model.attachmentStore.inMemoryByteCount == 0)
        undo.undo()
        try save(document, to: urls[2], previous: urls[1])
        #expect(fileData(urls[2], name) == big)
    }

    @Test func smallOrphanOfAnOpenedPackageIsRetainedInMemory() throws {
        let sources = try Sources()
        let urls = (0..<2).map { _ in tempPackageURL() }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let first = MindMapDocument()
        let small = Data("tiny".utf8)
        let id = try #require(try first.model.importFile(at: try sources.file("a.txt", small),
                                                         to: first.model.root.id, undoManager: makeUndo()))
        try save(first, to: urls[0], previous: nil)
        let document = try open(urls[0])
        let undo = makeUndo()
        document.model.removeAttachment(id, undoManager: undo)
        try save(document, to: urls[1], previous: urls[0])
        #expect(document.model.attachmentStore.inMemoryByteCount == small.count)
        undo.undo()
        #expect(document.model.content(of: id) == small)
    }

    @Test func packageRoundTripOnDisk() throws {
        let sources = try Sources()
        let document = MindMapDocument()
        let model = document.model
        let undo = makeUndo()
        let topic = try #require(model.addChild(to: model.root.id, text: "Docs", undoManager: undo))
        let pdf = Data("%PDF-1.4 fake".utf8)
        let png = Sources.bytes(2048, seed: 3)
        let a = try #require(try model.importFile(at: try sources.file("Résumé 📄.pdf", pdf), to: topic, undoManager: undo))
        let b = try #require(try model.importFile(at: try sources.file("README", png), to: topic, undoManager: undo))
        let url = tempPackageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try save(document, to: url, previous: nil)
        #expect(attachmentFiles(url) == ["\(a.uuidString).pdf", b.uuidString])

        let reopened = try open(url)
        #expect(reopened.model.map == model.map)
        #expect(reopened.model.attachment(a)?.title == "Résumé 📄.pdf")
        #expect(reopened.model.attachment(b)?.title == "README")
        #expect(reopened.model.content(of: a) == pdf)
        #expect(reopened.model.content(of: b) == png)
        let json = String(decoding: try Data(contentsOf: url.appendingPathComponent("map.json")), as: UTF8.self)
        #expect(json.contains("\"kind\" : \"file\""))
        #expect(json.contains("Résumé"))
    }

    @Test func orphanCleanupWorksForArbitraryExtensions() throws {
        let sources = try Sources()
        // A package with stray files of odd names nothing refers to.
        var strays: [String: FileWrapper] = [:]
        for name in ["x.weird", "noext", "a.b.c.tar.gz", "\(UUID().uuidString).docx"] {
            let wrapper = FileWrapper(regularFileWithContents: Data(name.utf8))
            wrapper.preferredFilename = name
            strays[name] = wrapper
        }
        let package = try MindMapPackage.fileWrapper(for: MindMap(), attachments: strays)
        let map = try MindMapPackage.read(package)
        let model = MindMapModel(map: map, attachmentStore: AttachmentStore(
            package: package, referenced: map.referencedAttachmentFileNames))
        let undo = makeUndo()
        let kept = try #require(try model.importFile(at: try sources.file("keep.key", Data("k".utf8)),
                                                     to: model.root.id, undoManager: undo))
        let dropped = try #require(try model.importFile(at: try sources.file("drop.xyz123", Data("d".utf8)),
                                                        to: model.root.id, undoManager: undo))
        model.removeAttachment(dropped, undoManager: undo)
        let children = model.attachmentStore.prepareSave(referencing: model.map.referencedAttachmentFileNames)
        #expect(Set(children.keys) == ["\(kept.uuidString).key"])
        // The removed one can still come back.
        undo.undo()
        #expect(model.content(of: dropped) == Data("d".utf8))
    }

    @Test func foldersAreAttachedAsZip() throws {
        let sources = try Sources()
        let folder = sources.folder.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: folder.appendingPathComponent("1.txt"))
        let model = MindMapModel()
        let id = try #require(try model.importFile(at: folder, to: model.root.id, undoManager: makeUndo()))
        let attachment = try #require(model.attachment(id))
        #expect(attachment.title == "Assets.zip")
        #expect(attachment.fileName.hasSuffix(".zip"))
        #expect(model.content(of: id)?.prefix(2) == Data("PK".utf8))
    }

    @Test func exportCopyIsNamedAfterTheTitle() throws {
        let sources = try Sources()
        let model = MindMapModel()
        let undo = makeUndo()
        let id = try #require(try model.importFile(at: try sources.file("Plan.pdf", Data("p".utf8)),
                                                   to: model.root.id, undoManager: undo))
        #expect(try model.exportCopy(of: id).lastPathComponent == "Plan.pdf")
        model.renameAttachment(id, to: "Final: v2/3", undoManager: undo)
        let renamed = try model.exportCopy(of: id)
        #expect(renamed.lastPathComponent == "Final- v2-3.pdf")
        #expect(try Data(contentsOf: renamed) == Data("p".utf8))
        undo.undo()
        #expect(model.attachment(id)?.title == "Plan.pdf")
    }

    @Test func invalidTargetsAddNothing() throws {
        let sources = try Sources()
        let model = MindMapModel()
        let undo = makeUndo()
        #expect(try model.importFile(at: try sources.file("a.txt", Data()), to: UUID(), undoManager: undo) == nil)
        #expect(!undo.canUndo)
        #expect(throws: (any Error).self) {
            try model.importFile(at: sources.folder.appendingPathComponent("missing.pdf"), to: model.root.id,
                                 undoManager: undo)
        }
    }
}

/// Naming rules for imported files.
struct FileNamingTests {
    @Test(arguments: [
        ("Q3 Report.PDF", "Q3 Report.PDF", "pdf"),
        ("Résumé 📄.docx", "Résumé 📄.docx", "docx"),
        ("README", "README", nil),
        (".bashrc", ".bashrc", nil),
        ("archive.tar.gz", "archive.tar.gz", "gz"),
        ("weird.ext with space", "weird.ext with space", nil),
        ("name.", "name.", nil),
        ("файл.текст", "файл.текст", nil),
        ("toolong.abcdefghijklmnopq", "toolong.abcdefghijklmnopq", nil),
        ("  padded.txt  ", "padded.txt", "txt"),
        ("/tmp/folder/file.md", "file.md", "md"),
        ("", "File", nil),
    ] as [(String, String, String?)])
    func sanitizing(original: String, title: String, ext: String?) {
        #expect(AttachmentFileName.title(fromOriginalName: original) == title)
        #expect(AttachmentFileName.storedExtension(fromOriginalName: original) == ext)
        let attachment = Attachment.file(originalName: original)
        #expect(attachment.title == title)
        #expect(attachment.fileName == (ext.map { "\(attachment.id.uuidString).\($0)" } ?? attachment.id.uuidString))
        #expect(Attachment.isValidFileName(attachment.fileName))
        let export = AttachmentFileName.exportName(for: attachment)
        #expect(!export.contains("/") && !export.isEmpty)
        if let ext { #expect(export.lowercased().hasSuffix("." + ext)) }
    }

    @Test func validFileNames() {
        #expect(Attachment.isValidFileName("\(UUID().uuidString).pdf"))
        #expect(Attachment.isValidFileName(UUID().uuidString))
        #expect(!Attachment.isValidFileName(".hidden"))
        #expect(!Attachment.isValidFileName("a/b"))
        #expect(!Attachment.isValidFileName("a\0b"))
        #expect(!Attachment.isValidFileName(String(repeating: "x", count: 256)))
    }

    @Test func exportNameAddsTheStoredExtension() {
        var attachment = Attachment.file(originalName: "Scan.jpeg")
        attachment.title = "Receipt"
        #expect(AttachmentFileName.exportName(for: attachment) == "Receipt.jpeg")
        attachment.title = "Receipt.JPEG"
        #expect(AttachmentFileName.exportName(for: attachment) == "Receipt.JPEG")
        attachment.title = ".."
        #expect(AttachmentFileName.exportName(for: attachment) == "File.jpeg")
        #expect(AttachmentFileName.topicText(forTitle: "Project Brief.pdf") == "Project Brief")
        #expect(AttachmentFileName.topicText(forTitle: ".bashrc") == ".bashrc")
        #expect(AttachmentFileName.topicText(forTitle: "README") == "README")
    }

    @Test func itemNamesFromProviders() {
        let temp = URL(fileURLWithPath: "/tmp/abc123.jpeg")
        #expect(AttachmentImporter.originalName(suggested: "Photo", fileURL: temp, typeID: UTType.jpeg.identifier)
                == "Photo.jpeg")
        #expect(AttachmentImporter.originalName(suggested: "Doc.pdf", fileURL: temp, typeID: UTType.pdf.identifier)
                == "Doc.pdf")
        #expect(AttachmentImporter.originalName(suggested: nil, fileURL: temp, typeID: UTType.jpeg.identifier)
                == "abc123.jpeg")
        let noExt = URL(fileURLWithPath: "/tmp/blob")
        #expect(AttachmentImporter.originalName(suggested: "Pasted Item", fileURL: noExt,
                                                typeID: UTType.png.identifier) == "Pasted Item.png")
    }
}

/// JSON compatibility of file attachments.
struct FileJSONTests {
    @Test func fileAttachmentRoundTrips() throws {
        let attachment = Attachment.file(originalName: "Slides 2026.key", now: Date(timeIntervalSince1970: 1_800_000_000))
        let map = MindMap(root: Node(text: "r", attachments: [attachment]))
        let data = try MindMapPackage.encode(map)
        #expect(try MindMapPackage.decode(data) == map)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"kind\" : \"file\""))
        #expect(text.contains("\"title\" : \"Slides 2026.key\""))
        #expect(text.contains("\(attachment.id.uuidString).key"))
    }

    @Test func extensionlessStageOneEntriesStayValid() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)"}"#
        let decoded = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        #expect(decoded.kind == .file)
        #expect(decoded.fileName == id.uuidString)
        #expect(Attachment.isValidFileName(decoded.fileName))
    }
}

/// Editor flows: picker / drop / paste destinations (one undo step per file).
@MainActor
struct FileEditorTests {
    private func makeEditor() -> (EditorController, topic: UUID, UndoManager) {
        let topic = Node(text: "Topic")
        let editor = EditorController(model: MindMapModel(map: MindMap(root: Node(text: "R", children: [topic]))))
        let undo = makeUndo()
        editor.undoManager = undo
        editor.updateViewSize(CGSize(width: 800, height: 600))
        return (editor, topic.id, undo)
    }

    @Test func importToTopicAndCanvas() async throws {
        let sources = try Sources()
        let (editor, topic, undo) = makeEditor()
        let urls = [try sources.file("a.pdf", Data("a".utf8)), try sources.file("b.png", Data("b".utf8))]
        await withCheckedContinuation { done in
            editor.importFiles(urls, to: .topic(topic)) { done.resume() }
        }
        #expect(editor.attachments(of: topic).map(\.title) == ["a.pdf", "b.png"])
        #expect(editor.selectedID == topic)

        // Empty canvas: a floating topic per file, named after it (one step each).
        await withCheckedContinuation { done in
            editor.importFiles([try! sources.file("Project Brief.pdf", Data("p".utf8))], to: .canvas(CGPoint(x: 700, y: 500))) {
                done.resume()
            }
        }
        let floating = try #require(editor.model.map.floatingTopics.last)
        #expect(floating.node.text == "Project Brief")
        #expect(floating.node.attachments.map(\.title) == ["Project Brief.pdf"])
        #expect(editor.selectedID == floating.node.id)
        #expect(undo.undoActionName == "Add File Topic")
        undo.undo()
        #expect(editor.model.map.floatingTopics.isEmpty)
        #expect(editor.model.map.node(withID: floating.node.id) == nil)
    }

    @Test func droppedItemProvidersAreCopiedWithTheirNames() async throws {
        let sources = try Sources()
        let (editor, topic, _) = makeEditor()
        let url = try sources.file("Dropped File.pdf", Data("%PDF".utf8))
        let provider = try #require(NSItemProvider(contentsOf: url))
        #expect(AttachmentImporter.isFileLike(provider))
        #expect(!AttachmentImporter.isFileLike(NSItemProvider(object: "just text" as NSString)))
        await withCheckedContinuation { done in
            editor.importItems([provider], to: .topic(topic)) { done.resume() }
        }
        let attachment = try #require(editor.attachments(of: topic).first)
        #expect(attachment.title == "Dropped File.pdf")
        #expect(attachment.fileName.hasSuffix(".pdf"))
        #expect(editor.model.content(of: attachment.id) == Data("%PDF".utf8))
    }

    @Test func failedImportsAreReported() {
        let (editor, topic, undo) = makeEditor()
        editor.finishImport([.failure(AttachmentImporter.ImportError.noFile("x"))], to: .topic(topic))
        #expect(editor.fileImportError?.contains("“x”") == true)
        #expect(!undo.canUndo)
    }

    @Test func attachFileCommandShowsThePicker() {
        let (editor, topic, _) = makeEditor()
        editor.select(topic)
        #expect(KeyCommandMap.command(key: KeyEquivalent("a"), modifiers: [.command, .shift], characters: "A")
                == .attachFile)
        #expect(editor.perform(.attachFile))
        #expect(editor.isFileImporterPresented)
        #expect(editor.fileImportTarget == topic)
        editor.attachPickedFiles(.success([]))
        #expect(editor.fileImportTarget == nil)
    }

    @Test func fileDropHitTestsTopics() throws {
        let (editor, topic, _) = makeEditor()
        let frame = try #require(editor.scene.layout.frames[topic])
        let center = editor.viewport.toScreen(CGPoint(x: frame.midX, y: frame.midY))
        #expect(editor.topic(atScreen: center) == topic)
        #expect(editor.topic(atScreen: CGPoint(x: 5, y: 5)) == nil)
    }
}

import SwiftUI

#if os(iOS)
import UIKit

@MainActor
struct FileUIDocumentTests {
    @Test func importedFileMarksDirtyAndRoundTrips() async throws {
        let sources = try Sources()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UIDocFile-\(UUID().uuidString).mindmap")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MindMapUIDocument(fileURL: url)
        #expect(await document.save(to: url, for: .forCreating))
        let undo = makeUndo()
        document.undoManager = undo
        let big = Sources.bytes(2 << 20, seed: 5)
        let id = try #require(try document.model.importFile(at: try sources.file("photo.heic", big),
                                                            to: document.model.root.id, undoManager: undo))
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.hasUnsavedChanges)
        #expect(await document.close())
        #expect(fileData(url, "\(id.uuidString).heic") == big)

        let reopened = MindMapUIDocument(fileURL: url)
        #expect(await reopened.open())
        #expect(reopened.model.attachment(id)?.title == "photo.heic")
        #expect(reopened.model.content(of: id) == big)
        #expect(await reopened.close())
    }
}
#endif
