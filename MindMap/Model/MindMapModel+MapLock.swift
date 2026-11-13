import CryptoKit
import Foundation

/// Locking the whole map (WP12). Lock / Remove Map Lock are undoable steps
/// (they change what the next save writes, so they must dirty the document
/// like every other change); unlocking and relocking are view state.
extension MindMapModel {
    /// Placeholder content of a sealed document (never shown, never saved).
    static var sealedPlaceholderMap: MindMap { MindMap(root: Node(text: "")) }

    /// Configures the model for a package read from disk: plain packages
    /// are loaded; locked ones stay sealed (lock screen) — or, on a revert
    /// while the same key is in memory, are decrypted right away.
    func load(package: FileWrapper) throws {
        if let header = try LockedPackage.header(of: package) {
            if let config = lock.config, config.header.keyID == header.keyID,
               let opened = try? LockedPackage.open(package, key: config.key) {
                install(opened, header: header, key: config.key)
                return
            }
            lock.configureSealed(header: header, package: package)
            replaceMap(Self.sealedPlaceholderMap)
            attachmentStore.reset(package: nil)
            return
        }
        let map = try MindMapPackage.read(package)
        lock.setConfig(nil)
        replaceMap(map)
        attachmentStore.keepsContentInMemory = false
        attachmentStore.reset(package: package, referenced: map.referencedAttachmentFileNames)
    }

    /// The package a save writes for the current state (main thread for
    /// the store work; the result is immutable).
    /// - sealed: the package as read, unchanged;
    /// - locked: everything encrypted (`LockedPackage.seal`);
    /// - plain: `MindMapPackage` (lock entries of an earlier lock dropped).
    func savePlan() -> SavePlan {
        breakCoalescing()
        if let sealed = lock.sealedPackage { return .sealed(sealed) }
        let map = map
        let attachments = attachmentStore.prepareSave(for: map)
        if let config = lock.config {
            return .locked(map: map, attachments: attachments, config: config, cache: lock.sealCache)
        }
        return .plain(map: map, attachments: attachments)
    }

    /// Decrypts the sealed package with the key from the key store. Throws
    /// `LockError.keyUnavailable` when this device has no key (yet) — the
    /// sealed package is left untouched.
    func openSealedPackage() throws {
        guard let package = lock.sealedPackage, let header = try LockedPackage.header(of: package) else { return }
        guard let key = try lock.services.keyStore.key(for: header.keyID) else { throw LockError.keyUnavailable }
        install(try LockedPackage.open(package, key: key), header: header, key: key)
    }

    private func install(_ opened: LockedPackage.Opened, header: LockHeader, key: SymmetricKey) {
        replaceMap(opened.map)
        attachmentStore.keepsContentInMemory = true
        attachmentStore.reset(package: opened.plainPackage, referenced: opened.map.referencedAttachmentFileNames)
        lock.didDecrypt(header: header, key: key, pairs: opened.pairs)
    }

    // MARK: User actions

    /// Lock screen "Unlock": authenticates, then decrypts if still sealed.
    /// Failures land in `lock.message`; the encrypted file is never touched.
    @MainActor
    @discardableResult
    func unlockMap(reason: String) async -> Bool {
        guard lock.isShowingLockScreen, !lock.isAuthenticating else { return false }
        lock.isAuthenticating = true
        lock.message = nil
        defer { lock.isAuthenticating = false }
        switch await lock.services.authenticator.authenticate(reason: reason) {
        case .success: break
        case .cancelled: return false
        case let .failed(message), let .unavailable(message):
            lock.message = message
            return false
        }
        do {
            if lock.isSealed { try openSealedPackage() }
        } catch {
            lock.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
        lock.showUnlocked(at: Date())
        return true
    }

    /// Lock Map: new random key into the key store, then one undoable
    /// "Lock Map" step; the next save writes the map encrypted. The map
    /// stays open (unlocked) until it relocks. No prompt — but the device
    /// must be able to authenticate its owner later.
    @discardableResult
    func lockMap(undoManager: UndoManager?) throws -> LockKeyStorage {
        guard !lock.isMapLocked else { return .iCloudKeychain }
        if let problem = lock.services.authenticator.availabilityProblem() {
            throw LockError.authenticationUnavailable(problem)
        }
        let key = LockCrypto.newKey()
        let header = LockHeader(keyID: UUID())
        let storage = try lock.services.keyStore.saveKey(key, id: header.keyID)
        setMapLock(MapLockConfig(header: header, key: key), actionName: "Lock Map", undoManager: undoManager)
        lock.unlockedAt = Date()
        return storage
    }

    /// Remove Map Lock: requires authentication; one undoable step (undo
    /// locks again with the same key). The next save writes plaintext.
    @MainActor
    @discardableResult
    func removeMapLock(reason: String, undoManager: UndoManager?) async -> LockAuthResult {
        guard lock.config != nil, !lock.isShowingLockScreen else { return .cancelled }
        let result = await lock.services.authenticator.authenticate(reason: reason)
        guard result == .success else { return result }
        setMapLock(nil, actionName: "Remove Map Lock", undoManager: undoManager)
        return .success
    }

    /// Applies a lock config as an undo step (redo/undo swap it back).
    func setMapLock(_ config: MapLockConfig?, actionName: String, undoManager: UndoManager?) {
        let old = lock.config
        lock.setConfig(config)
        if config != nil { attachmentStore.keepsContentInMemory = true }
        breakCoalescing()
        guard let undoManager else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            model.setMapLock(old, actionName: actionName, undoManager: undoManager)
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }
}

/// What one save writes (see `MindMapModel.savePlan`).
enum SavePlan {
    case sealed(FileWrapper)
    case locked(map: MindMap, attachments: [String: FileWrapper], config: MapLockConfig, cache: SealCache)
    case plain(map: MindMap, attachments: [String: FileWrapper])

    /// Builds the package (any thread). `existing` = the package on disk
    /// (its unknown entries are kept in plain saves).
    func fileWrapper(existing: FileWrapper?) throws -> FileWrapper {
        switch self {
        case let .sealed(package):
            return package
        case let .locked(map, attachments, config, cache):
            return try LockedPackage.seal(map: map, attachments: attachments, header: config.header,
                                          key: config.key, cache: cache)
        case let .plain(map, attachments):
            return try MindMapPackage.fileWrapper(for: map, existing: existing, attachments: attachments)
        }
    }

    var isLocked: Bool {
        switch self {
        case .plain: return false
        case .sealed, .locked: return true
        }
    }
}
