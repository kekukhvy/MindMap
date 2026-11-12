import CryptoKit
import Foundation

/// A locked map package (WP12):
///
///     lock.json                  plaintext header: version + key ID only
///     map.json.enc               AES-256-GCM of map.json
///     attachments/<name>.enc     AES-256-GCM of each attachment file
///
/// No plaintext `map.json`, no plaintext attachment, no title. Opening it
/// needs the key (`LockKeyStore`, by `LockHeader.keyID`).
enum LockedPackage {
    static let sealedMapName = "map.json.enc"
    static let sealedSuffix = ".enc"
    /// Entries a plaintext save must drop (after "Remove Map Lock").
    static let lockEntryNames: Set<String> = [LockHeader.fileName, sealedMapName]

    /// The header if `wrapper` is a locked package, nil for a plain one.
    static func header(of wrapper: FileWrapper) throws -> LockHeader? {
        guard wrapper.isDirectory, let entry = wrapper.fileWrappers?[LockHeader.fileName] else { return nil }
        guard let data = entry.regularFileContents else { throw LockError.invalidHeader }
        return try LockHeader.decode(data)
    }

    /// Decrypted package contents (in memory only).
    struct Opened {
        var map: MindMap
        /// Plain in-memory package (`map.json` + `attachments/`) for
        /// `AttachmentStore.reset(package:)`.
        var plainPackage: FileWrapper
        /// Logical attachment name -> (decrypted wrapper, sealed wrapper read
        /// from disk) so an unchanged file is not re-encrypted on save.
        var pairs: [String: (plain: FileWrapper, sealed: FileWrapper)]
    }

    static func open(_ wrapper: FileWrapper, key: SymmetricKey) throws -> Opened {
        guard let sealedMap = wrapper.fileWrappers?[sealedMapName]?.regularFileContents else {
            throw MindMapPackage.PackageError.missingMap
        }
        let map = try MindMapPackage.decode(LockCrypto.open(sealedMap, key: key, context: LockCrypto.mapContext))
        var plainFiles: [String: FileWrapper] = [:]
        var pairs: [String: (plain: FileWrapper, sealed: FileWrapper)] = [:]
        let folder = wrapper.fileWrappers?[MindMapPackage.attachmentsFolderName]
        for (sealedName, sealed) in folder?.fileWrappers ?? [:] where sealed.isRegularFile {
            guard sealedName.hasSuffix(sealedSuffix) else { continue }
            let name = String(sealedName.dropLast(sealedSuffix.count))
            guard Attachment.isValidFileName(name), let data = sealed.regularFileContents else { continue }
            let plain = FileWrapper(regularFileWithContents:
                try LockCrypto.open(data, key: key, context: LockCrypto.attachmentContext(name)))
            plain.preferredFilename = name
            plainFiles[name] = plain
            pairs[name] = (plain, sealed)
        }
        let mapWrapper = FileWrapper(regularFileWithContents: try MindMapPackage.encode(map))
        mapWrapper.preferredFilename = MindMapPackage.mapFileName
        let attachments = FileWrapper(directoryWithFileWrappers: plainFiles)
        attachments.preferredFilename = MindMapPackage.attachmentsFolderName
        let plainPackage = FileWrapper(directoryWithFileWrappers: [
            MindMapPackage.mapFileName: mapWrapper,
            MindMapPackage.attachmentsFolderName: attachments,
        ])
        return Opened(map: map, plainPackage: plainPackage, pairs: pairs)
    }

    /// The encrypted package for a save. `attachments` are the children of
    /// `attachments/` from `AttachmentStore.prepareSave` (plaintext,
    /// in memory); unchanged ones reuse their sealed wrapper from `cache`.
    /// Any other entry of an earlier package (e.g. a plaintext `map.json`
    /// from before the lock) is dropped.
    static func seal(map: MindMap, attachments: [String: FileWrapper], header: LockHeader,
                     key: SymmetricKey, cache: SealCache?) throws -> FileWrapper {
        let mapData = try LockCrypto.seal(MindMapPackage.encode(map), key: key, context: LockCrypto.mapContext)
        let mapWrapper = FileWrapper(regularFileWithContents: mapData)
        mapWrapper.preferredFilename = sealedMapName
        let headerWrapper = FileWrapper(regularFileWithContents: try header.encoded())
        headerWrapper.preferredFilename = LockHeader.fileName

        var sealedFiles: [String: FileWrapper] = [:]
        var used: [String: (plain: FileWrapper, sealed: FileWrapper)] = [:]
        for (name, plain) in attachments where Attachment.isValidFileName(name) {
            let sealedName = name + sealedSuffix
            if let reused = cache?.sealed(for: name, plain: plain, keyID: header.keyID) {
                sealedFiles[sealedName] = reused
                used[name] = (plain, reused)
                continue
            }
            guard let data = plain.regularFileContents else { continue }
            let sealed = FileWrapper(regularFileWithContents:
                try LockCrypto.seal(data, key: key, context: LockCrypto.attachmentContext(name)))
            sealed.preferredFilename = sealedName
            sealedFiles[sealedName] = sealed
            used[name] = (plain, sealed)
        }
        cache?.replace(with: used, keyID: header.keyID)
        let folder = FileWrapper(directoryWithFileWrappers: sealedFiles)
        folder.preferredFilename = MindMapPackage.attachmentsFolderName
        return FileWrapper(directoryWithFileWrappers: [
            LockHeader.fileName: headerWrapper,
            sealedMapName: mapWrapper,
            MindMapPackage.attachmentsFolderName: folder,
        ])
    }
}

/// Sealed wrapper of each attachment as last saved, keyed by the plaintext
/// wrapper it was made from: `AttachmentStore` reuses wrapper objects for
/// unchanged files, so identity means "same content" and the encrypted file
/// is reused instead of re-encrypted (unchanged files are not rewritten in
/// iCloud Drive). Saves may run off the main thread: guarded by a lock.
final class SealCache: @unchecked Sendable {
    private let lock = NSLock()
    private var keyID: UUID?
    private var entries: [String: (plain: FileWrapper, sealed: FileWrapper)] = [:]

    init() {}

    func sealed(for name: String, plain: FileWrapper, keyID: UUID) -> FileWrapper? {
        lock.lock()
        defer { lock.unlock() }
        guard self.keyID == keyID, let entry = entries[name], entry.plain === plain else { return nil }
        return entry.sealed
    }

    func replace(with entries: [String: (plain: FileWrapper, sealed: FileWrapper)], keyID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        self.keyID = keyID
        self.entries = entries
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        keyID = nil
        entries = [:]
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
