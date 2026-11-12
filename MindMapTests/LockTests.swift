import CryptoKit
import Foundation
import PencilKit
import Testing
@testable import MindMap

// WP12: lock a map or a note — encryption, key handling, state machine, undo.

private func makeUndo() -> UndoManager {
    let undo = UndoManager()
    undo.groupsByEvent = false
    return undo
}

/// Authenticator double: fixed outcome, counts prompts.
final class MockAuthenticator: LockAuthenticator {
    var result: LockAuthResult
    var problem: String?
    private(set) var prompts = 0
    let methodName = "Face ID"
    let methodSymbol = "faceid"

    init(_ result: LockAuthResult = .success, problem: String? = nil) {
        self.result = result
        self.problem = problem
    }

    func availabilityProblem() -> String? { problem }

    @MainActor
    func authenticate(reason: String) async -> LockAuthResult {
        prompts += 1
        return result
    }
}

/// Key store double that counts reads.
final class CountingKeyStore: LockKeyStore {
    let inner = InMemoryKeyStore()
    private(set) var reads = 0

    func saveKey(_ key: SymmetricKey, id: UUID) throws -> LockKeyStorage { try inner.saveKey(key, id: id) }

    func key(for id: UUID) throws -> SymmetricKey? {
        reads += 1
        return try inner.key(for: id)
    }
}

private enum Secret {
    static let topic = "Top secret salary plan"
    static let note = "My private diary entry about Zanzibar"
    static let fileMarker = "CONFIDENTIAL-FILE-MARKER-0042"
}

/// A model with topics, a note, a handwritten note and a file.
private struct Fixture {
    let model: MindMapModel
    let undo = makeUndo()
    let keys = CountingKeyStore()
    let auth = MockAuthenticator()
    let topic: UUID
    let note: UUID
    let drawing: UUID
    let file: UUID

    init(model: MindMapModel = MindMapModel()) throws {
        self.model = model
        model.lock.services = LockServices(keyStore: keys, authenticator: auth)
        topic = try #require(model.addChild(to: model.root.id, text: Secret.topic, undoManager: undo))
        note = try #require(model.addNote(to: topic, text: Secret.note, undoManager: undo))
        var drawing = PKDrawing()
        let points = (0..<10).map { PKStrokePoint(location: CGPoint(x: $0 * 10, y: 20), timeOffset: 0,
                                                   size: CGSize(width: 3, height: 3), opacity: 1, force: 1,
                                                   azimuth: 0, altitude: .pi / 2) }
        drawing.strokes.append(PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points,
                                                                                            creationDate: Date())))
        self.drawing = try #require(model.addDrawing(to: topic, content: drawing.dataRepresentation(), undoManager: undo))
        let attachment = Attachment.file(originalName: "secret.txt")
        #expect(model.addAttachment(attachment, to: topic, content: Data(Secret.fileMarker.utf8), undoManager: undo))
        file = attachment.id
    }
}

private func tempURL(_ name: String = "Lock") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        .appendingPathExtension("mindmap")
}

/// Every regular file of a package on disk (relative path -> bytes).
private func files(at url: URL) -> [String: Data] {
    var result: [String: Data] = [:]
    let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
    while let file = enumerator?.nextObject() as? URL {
        guard !file.hasDirectoryPath, let data = try? Data(contentsOf: file) else { continue }
        result[String(file.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count + 1))] = data
    }
    return result
}

/// Whether any file contains `text` (UTF-8, UTF-16 either order, base64 / JSON-escaped forms).
private func leaks(_ text: String, in packageFiles: [String: Data]) -> [String] {
    let needles = [Data(text.utf8), text.data(using: .utf16LittleEndian)!, text.data(using: .utf16BigEndian)!,
                   Data(Data(text.utf8).base64EncodedString().prefix(16).utf8)]
    return packageFiles.filter { _, data in needles.contains { data.range(of: $0) != nil } }.map(\.key).sorted()
}

/// Saves the model like the document classes (plan on main, then write).
@discardableResult
private func save(_ model: MindMapModel, to url: URL, previous: URL? = nil) throws -> FileWrapper {
    let existing = try previous.map { try FileWrapper(url: $0) }
    let wrapper = try model.savePlan().fileWrapper(existing: existing)
    try wrapper.write(to: url, options: .atomic, originalContentsURL: previous)
    return wrapper
}

private func open(_ url: URL, keys: LockKeyStore, auth: LockAuthenticator = MockAuthenticator()) throws -> MindMapModel {
    let model = MindMapModel()
    model.lock.services = LockServices(keyStore: keys, authenticator: auth)
    try model.load(package: try FileWrapper(url: url))
    return model
}

// MARK: - Crypto

struct LockCryptoTests {
    @Test func sealOpenRoundTrip() throws {
        let key = LockCrypto.newKey()
        let plain = Data("hello 🧠".utf8)
        let sealed = try LockCrypto.seal(plain, key: key, context: "a")
        #expect(sealed != plain)
        #expect(sealed.count == plain.count + 12 + 16)
        #expect(try LockCrypto.open(sealed, key: key, context: "a") == plain)
        // Fresh nonce each time.
        #expect(try LockCrypto.seal(plain, key: key, context: "a") != sealed)
    }

    @Test func wrongKeyContextOrTamperingFail() throws {
        let key = LockCrypto.newKey()
        let sealed = try LockCrypto.seal(Data("x".utf8), key: key, context: "a")
        #expect(throws: LockError.decryptionFailed) { try LockCrypto.open(sealed, key: LockCrypto.newKey(), context: "a") }
        #expect(throws: LockError.decryptionFailed) { try LockCrypto.open(sealed, key: key, context: "b") }
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0xFF
        #expect(throws: LockError.decryptionFailed) { try LockCrypto.open(tampered, key: key, context: "a") }
        #expect(throws: LockError.decryptionFailed) { try LockCrypto.open(Data([1, 2]), key: key, context: "a") }
    }

    @Test func headerHasNoContentAndRejectsNewerVersions() throws {
        let header = LockHeader(keyID: UUID())
        let text = String(decoding: try header.encoded(), as: UTF8.self)
        #expect(text.contains(header.keyID.uuidString))
        #expect(try LockHeader.decode(header.encoded()) == header)
        let newer = Data(#"{"version": 9, "keyID": "\#(UUID().uuidString)"}"#.utf8)
        #expect(throws: LockError.unsupportedVersion(9)) { try LockHeader.decode(newer) }
        #expect(throws: LockError.invalidHeader) { try LockHeader.decode(Data("nope".utf8)) }
    }

    @Test func inMemoryKeyStoreRoundTrip() throws {
        let store = InMemoryKeyStore()
        let key = LockCrypto.newKey()
        let id = UUID()
        #expect(try store.key(for: id) == nil)
        #expect(try store.saveKey(key, id: id) == .iCloudKeychain)
        #expect(try store.key(for: id).map(LockCrypto.keyData) == LockCrypto.keyData(key))
    }
}

// MARK: - Whole map

@MainActor
struct MapLockPackageTests {
    @Test func lockedPackageRoundTripsAndHasNoPlaintext() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let originalMap = model.map
        let drawingBytes = model.content(of: fixture.drawing)
        #expect(try model.lockMap(undoManager: fixture.undo) == .iCloudKeychain)
        #expect(model.lock.isMapLocked && !model.lock.isShowingLockScreen)

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try save(model, to: url)
        let written = files(at: url)
        let names = Set(written.keys)
        #expect(names.contains("lock.json"))
        #expect(names.contains("map.json.enc"))
        #expect(!names.contains("map.json"))
        let attachmentNames = names.filter { $0.hasPrefix("attachments/") }
        #expect(attachmentNames.count == 3)
        #expect(attachmentNames.allSatisfy { $0.hasSuffix(".enc") })
        #expect(leaks(Secret.topic, in: written).isEmpty)
        #expect(leaks(Secret.note, in: written).isEmpty)
        #expect(leaks(Secret.fileMarker, in: written).isEmpty)
        #expect(leaks("Central Topic", in: written).isEmpty)
        // The header holds the key ID and nothing about the content.
        let header = String(decoding: try #require(written["lock.json"]), as: UTF8.self)
        #expect(!header.contains("Central") && !header.contains("Secret") && !header.contains("title"))

        // Reopen: sealed until unlocked, then identical.
        let reopened = try open(url, keys: fixture.keys)
        #expect(reopened.lock.isSealed && reopened.lock.isShowingLockScreen)
        #expect(reopened.root.text.isEmpty) // placeholder, not the content
        #expect(await reopened.unlockMap(reason: "test"))
        #expect(!reopened.lock.isSealed && !reopened.lock.isShowingLockScreen)
        #expect(reopened.map == originalMap)
        #expect(MarkdownNote.text(reopened.content(of: fixture.note)) == Secret.note)
        #expect(reopened.content(of: fixture.drawing) == drawingBytes)
        #expect(reopened.content(of: fixture.file) == Data(Secret.fileMarker.utf8))
    }

    @Test func missingKeyKeepsSealedPackageUntouched() async throws {
        let fixture = try Fixture()
        try fixture.model.lockMap(undoManager: fixture.undo)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try save(fixture.model, to: url)
        let before = files(at: url)

        // Another device: iCloud Keychain has not synced the key.
        let otherKeys = InMemoryKeyStore()
        let other = try open(url, keys: otherKeys)
        #expect(await other.unlockMap(reason: "test") == false)
        #expect(other.lock.message == LockError.missingKeyMessage)
        #expect(other.lock.isSealed && other.lock.isShowingLockScreen)
        // Any save in that state writes the encrypted payload back unchanged.
        guard case .sealed = other.savePlan() else {
            Issue.record("sealed document must save its package as-is")
            return
        }
        let copy = tempURL("Copy")
        defer { try? FileManager.default.removeItem(at: copy) }
        try save(other, to: copy, previous: url)
        #expect(files(at: copy) == before)

        // Wrong key under the same ID: decryption error, still sealed.
        _ = try otherKeys.saveKey(LockCrypto.newKey(), id: try #require(other.lock.keyID))
        #expect(await other.unlockMap(reason: "test") == false)
        #expect(other.lock.message == LockError.decryptionFailed.errorDescription)
        #expect(other.lock.isSealed)

        // Key arrives (synced): unlocks.
        let good = try open(url, keys: fixture.keys)
        #expect(await good.unlockMap(reason: "test"))
        #expect(good.map.root.children.first?.text == Secret.topic)
    }

    @Test func authenticationFailureAndCancelDoNotReadTheKey() async throws {
        let fixture = try Fixture()
        try fixture.model.lockMap(undoManager: fixture.undo)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try save(fixture.model, to: url)
        let keys = CountingKeyStore()
        let keyID = try #require(fixture.model.lock.keyID)
        let key = try #require(try fixture.keys.key(for: keyID))
        _ = try keys.saveKey(key, id: keyID)
        let auth = MockAuthenticator(.cancelled)
        let model = try open(url, keys: keys, auth: auth)

        #expect(await model.unlockMap(reason: "test") == false)
        #expect(model.lock.message == nil && model.lock.isSealed && keys.reads == 0)
        auth.result = .failed("Face ID did not match.")
        #expect(await model.unlockMap(reason: "test") == false)
        #expect(model.lock.message == "Face ID did not match." && keys.reads == 0)
        auth.result = .unavailable("No passcode.")
        #expect(await model.unlockMap(reason: "test") == false)
        #expect(model.lock.message == "No passcode.")
        auth.result = .success
        #expect(await model.unlockMap(reason: "test"))
        #expect(keys.reads == 1 && auth.prompts == 4 && model.lock.message == nil)
    }

    @Test func lockNeedsAnAuthenticatableDevice() throws {
        let fixture = try Fixture()
        fixture.auth.problem = "Set a device passcode first."
        #expect(throws: LockError.authenticationUnavailable("Set a device passcode first.")) {
            try fixture.model.lockMap(undoManager: fixture.undo)
        }
        #expect(!fixture.model.lock.isMapLocked && fixture.keys.inner.keys.isEmpty)
        #expect(throws: LockError.authenticationUnavailable("Set a device passcode first.")) {
            try fixture.model.lockNote(fixture.note, undoManager: fixture.undo)
        }
    }

    /// Autosaves of an unlocked locked map stay encrypted; unchanged files
    /// reuse their sealed wrapper (not re-encrypted / rewritten).
    @Test func autosaveOfLockedDocumentStaysEncrypted() throws {
        let document = MindMapDocument()
        let fixture = try Fixture(model: document.model)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try MindMapDocument.package(for: try document.snapshot(contentType: .mindMap), existing: nil)
        try first.write(to: url, options: .atomic, originalContentsURL: nil)
        #expect(files(at: url)["map.json"] != nil) // plain before locking

        try document.model.lockMap(undoManager: fixture.undo)
        var previous = url
        var sealedNoteWrapper: FileWrapper?
        for round in 0..<3 {
            document.model.rename(fixture.topic, to: Secret.topic + " v\(round)", undoManager: fixture.undo)
            let next = tempURL("Autosave")
            let wrapper = try MindMapDocument.package(for: try document.snapshot(contentType: .mindMap),
                                                      existing: try FileWrapper(url: previous))
            try wrapper.write(to: next, options: .atomic, originalContentsURL: previous)
            let written = files(at: next)
            #expect(written["map.json"] == nil)
            #expect(leaks(Secret.topic, in: written).isEmpty)
            #expect(leaks(Secret.note, in: written).isEmpty)
            let noteName = try #require(document.model.attachment(fixture.note)?.fileName) + ".enc"
            let sealedNote = wrapper.fileWrappers?["attachments"]?.fileWrappers?[noteName]
            if let sealedNoteWrapper { #expect(sealedNote === sealedNoteWrapper) }
            sealedNoteWrapper = sealedNote
            if previous != url { try? FileManager.default.removeItem(at: previous) }
            previous = next
        }
        try? FileManager.default.removeItem(at: previous)
    }

    @Test func plainSaveAfterRemovingLockDropsLockEntries() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        try model.lockMap(undoManager: fixture.undo)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try save(model, to: url)
        #expect(await model.removeMapLock(reason: "test", undoManager: fixture.undo) == .success)
        let next = tempURL("Plain")
        defer { try? FileManager.default.removeItem(at: next) }
        try save(model, to: next, previous: url)
        let written = files(at: next)
        #expect(written["lock.json"] == nil && written["map.json.enc"] == nil)
        #expect(written["map.json"] != nil)
        #expect(written.keys.filter { $0.hasSuffix(".enc") }.isEmpty)
        #expect(!leaks(Secret.note, in: written).isEmpty) // plain again, by the user's choice
    }

    @Test func removingTheLockRequiresAuthentication() async throws {
        let fixture = try Fixture()
        try fixture.model.lockMap(undoManager: fixture.undo)
        fixture.auth.result = .cancelled
        #expect(await fixture.model.removeMapLock(reason: "test", undoManager: fixture.undo) == .cancelled)
        #expect(fixture.model.lock.isMapLocked)
        fixture.auth.result = .failed("nope")
        #expect(await fixture.model.removeMapLock(reason: "test", undoManager: fixture.undo) == .failed("nope"))
        #expect(fixture.model.lock.isMapLocked)
    }

    /// Imported files of a locked map never stay in the scratch folder.
    @Test func lockingMovesScratchFilesIntoMemory() throws {
        let model = MindMapModel()
        model.lock.services = LockServices(keyStore: InMemoryKeyStore(), authenticator: MockAuthenticator())
        let undo = makeUndo()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LockSrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("big.bin")
        let bytes = Data((0..<(2 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: source)
        let first = try #require(try model.importFile(at: source, to: model.root.id, undoManager: undo))
        _ = model.savePlan() // saved once: the package wrapper reads the scratch file lazily
        let second = try #require(try model.importFile(at: source, to: model.root.id, undoManager: undo))
        #expect(model.attachmentStore.scratchFileCount == 2)
        let scratch = model.attachmentStore.scratchDirectory

        try model.lockMap(undoManager: undo)
        #expect(model.attachmentStore.scratchFileCount == 0)
        let leftovers = (FileManager.default.enumerator(at: scratch, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }
        #expect(leftovers.isEmpty)
        #expect(model.content(of: first) == bytes && model.content(of: second) == bytes)
        // New imports while locked go to memory too.
        let third = try #require(try model.importFile(at: source, to: model.root.id, undoManager: undo))
        #expect(model.attachmentStore.scratchFileCount == 0 && model.content(of: third) == bytes)
    }
}

// MARK: - Single note

@MainActor
struct NoteLockTests {
    @Test func lockedNoteIsEncryptedAndReadableOnlyWhileUnlocked() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let plainName = try #require(model.attachment(fixture.note)?.fileName)
        try model.lockNote(fixture.note, undoManager: fixture.undo)
        let locked = try #require(model.attachment(fixture.note))
        #expect(locked.isLocked && locked.fileName == plainName + ".enc")
        #expect(model.content(of: fixture.note) == nil)
        let stored = try #require(model.attachmentStore.data(for: locked.fileName))
        #expect(stored.range(of: Data(Secret.note.utf8)) == nil)
        // Never empty while locked: closing a window does not delete it.
        #expect(!model.isContentEmpty(locked))
        #expect(!model.discardIfEmpty(fixture.note, undoManager: fixture.undo))

        fixture.auth.result = .cancelled
        #expect(await model.unlockNote(fixture.note, reason: "t") == .cancelled)
        #expect(model.content(of: fixture.note) == nil)
        fixture.auth.result = .success
        #expect(await model.unlockNote(fixture.note, reason: "t") == .success)
        #expect(MarkdownNote.text(model.content(of: fixture.note)) == Secret.note)

        // Edits while unlocked are stored encrypted.
        #expect(model.setAttachmentContent(MarkdownNote.data("new secret text"), for: fixture.note,
                                           undoManager: fixture.undo))
        let edited = try #require(model.attachmentStore.data(for: locked.fileName))
        #expect(edited.range(of: Data("new secret text".utf8)) == nil)
        #expect(MarkdownNote.text(model.content(of: fixture.note)) == "new secret text")

        // Window closed: relocked, nothing written while locked.
        model.lock.relockNote(fixture.note, keyID: locked.lockKeyID)
        #expect(model.content(of: fixture.note) == nil)
        #expect(!model.setAttachmentContent(MarkdownNote.data("x"), for: fixture.note, undoManager: fixture.undo))
    }

    @Test func savedPackageHoldsOnlyTheEncryptedNote() throws {
        let fixture = try Fixture()
        let model = fixture.model
        let plainName = try #require(model.attachment(fixture.note)?.fileName)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try save(model, to: url)
        #expect(files(at: url)["attachments/\(plainName)"] != nil)

        try model.lockNote(fixture.note, undoManager: fixture.undo)
        let next = tempURL("Note")
        defer { try? FileManager.default.removeItem(at: next) }
        try save(model, to: next, previous: url)
        let written = files(at: next)
        #expect(written["attachments/\(plainName)"] == nil)
        #expect(written["attachments/\(plainName).enc"] != nil)
        #expect(leaks(Secret.note, in: written).isEmpty)
        #expect(!leaks(Secret.topic, in: written).isEmpty) // the map itself is not locked
        // map.json keeps the flag + key ID.
        let json = String(decoding: try #require(written["map.json"]), as: UTF8.self)
        #expect(json.contains("lockKeyID"))

        // Reopened elsewhere: locked; with the key it unlocks.
        let reopened = try open(next, keys: fixture.keys)
        #expect(reopened.attachment(fixture.note)?.isLocked == true)
        #expect(reopened.content(of: fixture.note) == nil)
    }

    @Test func missingNoteKeyGivesClearMessage() async throws {
        let fixture = try Fixture()
        try fixture.model.lockNote(fixture.note, undoManager: fixture.undo)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try save(fixture.model, to: url)
        let other = try open(url, keys: InMemoryKeyStore())
        #expect(await other.unlockNote(fixture.note, reason: "t") == .failed(LockError.missingKeyMessage))
        #expect(other.content(of: fixture.note) == nil)
    }

    @Test func lockAndRemoveLockAreUndoable() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let undo = fixture.undo
        let plainName = try #require(model.attachment(fixture.note)?.fileName)
        try model.lockNote(fixture.note, undoManager: undo)
        #expect(undo.undoActionName == "Lock Note")
        undo.undo()
        #expect(model.attachment(fixture.note)?.isLocked == false)
        #expect(model.attachment(fixture.note)?.fileName == plainName)
        #expect(MarkdownNote.text(model.content(of: fixture.note)) == Secret.note)
        undo.redo()
        #expect(model.attachment(fixture.note)?.isLocked == true)
        #expect(model.content(of: fixture.note) == nil)

        #expect(await model.removeNoteLock(fixture.note, reason: "t", undoManager: undo) == .success)
        #expect(undo.undoActionName == "Remove Note Lock")
        #expect(model.attachment(fixture.note)?.isLocked == false)
        #expect(model.attachment(fixture.note)?.fileName == plainName)
        #expect(MarkdownNote.text(model.content(of: fixture.note)) == Secret.note)
        undo.undo()
        #expect(model.attachment(fixture.note)?.isLocked == true)
        #expect(model.content(of: fixture.note) == nil)
        // The plaintext kept for undo after locking is never spilled to disk.
        #expect(model.attachmentStore.scratchFileCount == 0)
    }

    @Test func handwrittenNotesLockToo() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let bytes = model.content(of: fixture.drawing)
        try model.lockNote(fixture.drawing, undoManager: fixture.undo)
        #expect(fixture.undo.undoActionName == "Lock Handwritten Note")
        #expect(model.attachment(fixture.drawing)?.fileName.hasSuffix(".drawing.enc") == true)
        #expect(await model.unlockNote(fixture.drawing, reason: "t") == .success)
        #expect(model.content(of: fixture.drawing) == bytes)
    }

    @Test func onlyNotesInTheMapCanBeLocked() throws {
        let fixture = try Fixture()
        let model = fixture.model
        #expect(!model.canLockNote(fixture.file))
        #expect(throws: LockError.notLockable) { try model.lockNote(fixture.file, undoManager: fixture.undo) }
        let draft = try #require(model.startNote(on: fixture.topic))
        #expect(!model.canLockNote(draft))
        #expect(NoteLockMenu.actions(for: try #require(model.attachment(draft)), isDraft: true).isEmpty)
        let note = try #require(model.attachment(fixture.note))
        #expect(NoteLockMenu.actions(for: note, isDraft: false) == [.lock(fixture.note)])
        try model.lockNote(fixture.note, undoManager: fixture.undo)
        #expect(NoteLockMenu.actions(for: try #require(model.attachment(fixture.note)), isDraft: false)
            == [.unlock(fixture.note), .removeLock(fixture.note)])
    }

    @Test func noteLockInsideLockedMap() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        try model.lockNote(fixture.note, undoManager: fixture.undo)
        try model.lockMap(undoManager: fixture.undo)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try save(model, to: url)
        let reopened = try open(url, keys: fixture.keys)
        #expect(await reopened.unlockMap(reason: "t"))
        #expect(reopened.attachment(fixture.note)?.isLocked == true)
        #expect(reopened.content(of: fixture.note) == nil)
        #expect(await reopened.unlockNote(fixture.note, reason: "t") == .success)
        #expect(MarkdownNote.text(reopened.content(of: fixture.note)) == Secret.note)
    }
}

// MARK: - State machine, undo

@MainActor
struct LockStateTests {
    @Test func relockStateMachine() async throws {
        let fixture = try Fixture()
        let lock = fixture.model.lock
        #expect(!lock.relock()) // plain map: nothing to hide
        try fixture.model.lockMap(undoManager: fixture.undo)
        #expect(!lock.isShowingLockScreen)
        #expect(lock.relock(autoPrompt: true))
        #expect(lock.isShowingLockScreen && lock.wantsAutoPrompt)
        #expect(!lock.relock()) // already locked
        // Unlock after a relock: authentication only, key still in memory.
        fixture.keys.inner.removeKey(try #require(lock.keyID))
        let readsBefore = fixture.keys.reads
        #expect(await fixture.model.unlockMap(reason: "t"))
        #expect(!lock.isShowingLockScreen && fixture.keys.reads == readsBefore)
        // Saves still encrypt.
        guard case .locked = fixture.model.savePlan() else {
            Issue.record("expected an encrypted save")
            return
        }
    }

    @Test func idleTimeout() throws {
        let fixture = try Fixture()
        let lock = fixture.model.lock
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(!lock.isIdleExpired(now: start + 3600, lastActivity: start, timeout: 300)) // plain map
        try fixture.model.lockMap(undoManager: fixture.undo)
        lock.unlockedAt = start
        #expect(!lock.isIdleExpired(now: start + 299, lastActivity: start, timeout: 300))
        #expect(lock.isIdleExpired(now: start + 300, lastActivity: start, timeout: 300))
        #expect(!lock.isIdleExpired(now: start + 400, lastActivity: start + 200, timeout: 300)) // activity
        #expect(!lock.isIdleExpired(now: start + 9999, lastActivity: start, timeout: 0)) // Never
        lock.relock()
        #expect(!lock.isIdleExpired(now: start + 9999, lastActivity: start, timeout: 300)) // already locked
    }

    @Test func idleTimeoutRelocksUnlockedNotes() async throws {
        let fixture = try Fixture()
        let lock = fixture.model.lock
        try fixture.model.lockNote(fixture.note, undoManager: fixture.undo)
        #expect(await fixture.model.unlockNote(fixture.note, reason: "t") == .success)
        let start = try #require(lock.unlockedAt)
        #expect(lock.isIdleExpired(now: start + 301, lastActivity: start - 10, timeout: 300))
        lock.relock()
        #expect(!lock.isNoteUnlocked(fixture.note) && fixture.model.content(of: fixture.note) == nil)
    }

    @Test func relockSavesThenClearsUndoHistory() throws {
        let fixture = try Fixture()
        let undo = fixture.undo
        try fixture.model.lockMap(undoManager: undo)
        fixture.model.rename(fixture.topic, to: "Edited", undoManager: undo)
        #expect(undo.canUndo)
        var pendingSave: (() -> Void)?
        LockRelocker.relock(fixture.model, autoPrompt: false, undoManager: undo) { done in pendingSave = done }
        #expect(fixture.model.lock.isShowingLockScreen)
        #expect(undo.canUndo) // not before the save finished
        pendingSave?()
        #expect(!undo.canUndo && !undo.canRedo)

        // Without a way to save, the history is kept (no lost changes).
        let other = try Fixture()
        try other.model.lockMap(undoManager: other.undo)
        LockRelocker.relock(other.model, autoPrompt: false, undoManager: other.undo, save: nil)
        #expect(other.model.lock.isShowingLockScreen && other.undo.canUndo)
    }

    @Test func lockMapIsOneUndoStep() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        let undo = fixture.undo
        try model.lockMap(undoManager: undo)
        let keyID = try #require(model.lock.keyID)
        #expect(undo.undoActionName == "Lock Map")
        undo.undo()
        #expect(!model.lock.isMapLocked)
        guard case .plain = model.savePlan() else {
            Issue.record("undoing Lock Map saves plain")
            return
        }
        undo.redo()
        #expect(model.lock.keyID == keyID)
        guard case .locked = model.savePlan() else {
            Issue.record("redo saves encrypted")
            return
        }
        // Map edits before the lock are still undoable after it.
        undo.undo()
        undo.undo()
        #expect(model.attachment(fixture.file) == nil)
        undo.redo()
        undo.redo()
        #expect(model.lock.keyID == keyID)

        #expect(await model.removeMapLock(reason: "t", undoManager: undo) == .success)
        #expect(undo.undoActionName == "Remove Map Lock" && !model.lock.isMapLocked)
        undo.undo()
        #expect(model.lock.keyID == keyID) // same key again: other copies still open
    }

    @Test func sealedDocumentAlwaysSavesItsPackage() async throws {
        let fixture = try Fixture()
        try fixture.model.lockMap(undoManager: fixture.undo)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try save(fixture.model, to: url)
        let reopened = try open(url, keys: fixture.keys)
        // Even if the placeholder changed, a sealed document saves sealed.
        reopened.replaceMap(MindMap(root: Node(text: "should never be saved")))
        guard case .sealed = reopened.savePlan() else {
            Issue.record("sealed documents always save sealed")
            return
        }
        #expect(await reopened.unlockMap(reason: "t"))
        #expect(reopened.map.root.children.first?.text == Secret.topic)
    }
}

#if os(iOS)
/// iPad document class: the same package rules through UIDocument.
@MainActor
struct LockUIDocumentTests {
    @Test func uiDocumentSavesEncryptedAndReopensSealed() async throws {
        let url = tempURL("UIDoc")
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = InMemoryKeyStore()
        let document = MindMapUIDocument(fileURL: url)
        document.model.lock.services = LockServices(keyStore: keys, authenticator: MockAuthenticator())
        #expect(await document.save(to: url, for: .forCreating))
        let undo = makeUndo()
        document.undoManager = undo
        let model = document.model
        let topic = try #require(model.addChild(to: model.root.id, text: Secret.topic, undoManager: undo))
        _ = model.addNote(to: topic, text: Secret.note, undoManager: undo)
        try model.lockMap(undoManager: undo)
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.hasUnsavedChanges)
        #expect(await document.close())
        let written = files(at: url)
        #expect(written["map.json"] == nil && written["lock.json"] != nil)
        #expect(leaks(Secret.topic, in: written).isEmpty && leaks(Secret.note, in: written).isEmpty)

        let reopened = MindMapUIDocument(fileURL: url)
        reopened.model.lock.services = LockServices(keyStore: keys, authenticator: MockAuthenticator())
        #expect(await reopened.open())
        #expect(reopened.model.lock.isSealed)
        #expect(await reopened.model.unlockMap(reason: "t"))
        #expect(reopened.model.root.children.first?.text == Secret.topic)
        #expect(await reopened.close())
    }
}
#endif

/// The real keychain store in the (ad-hoc signed) test host: macOS falls
/// back to this Mac's login keychain (no team → no data protection
/// keychain), the iOS simulator stores a synchronizable item. The item is
/// deleted afterwards.
struct KeychainKeyStoreTests {
    @Test func saveAndReadKey() throws {
        let store = KeychainKeyStore()
        let id = UUID()
        let key = LockCrypto.newKey()
        defer {
            for sync in [true, false] {
                var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                            kSecAttrService as String: KeychainKeyStore.service,
                                            kSecAttrAccount as String: id.uuidString]
                if sync {
                    query[kSecAttrSynchronizable as String] = true
                    #if os(macOS)
                    query[kSecUseDataProtectionKeychain as String] = true
                    #endif
                }
                SecItemDelete(query as CFDictionary)
            }
        }
        #expect(try store.key(for: id) == nil)
        let storage = try store.saveKey(key, id: id)
        #if os(iOS)
        #expect(storage == .iCloudKeychain)
        #endif
        print("KeychainKeyStore storage on this host: \(storage)")
        #expect(try store.key(for: id).map(LockCrypto.keyData) == LockCrypto.keyData(key))
    }
}
