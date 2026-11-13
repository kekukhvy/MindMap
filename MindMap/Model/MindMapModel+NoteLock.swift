import CryptoKit
import Foundation

/// Locking single notes (WP12): a Markdown or handwritten note's file is
/// encrypted (AES-GCM, own random key per note in the keychain) and renamed
/// "<UUID>.md.enc" / "<UUID>.drawing.enc" (not Obsidian-readable by design);
/// the attachment keeps `lockKeyID`. Lock Note / Remove Note Lock are one
/// undoable step each: the file swap goes through the store (old file kept
/// for undo — in memory only when it is plaintext) and one attachment edit.
/// The key is in memory only while the note is unlocked (its editor open).
extension MindMapModel {
    static func lockActionName(for kind: AttachmentKind) -> String {
        kind == .drawing ? "Lock Handwritten Note" : "Lock Note"
    }

    static func removeLockActionName(for kind: AttachmentKind) -> String {
        kind == .drawing ? "Remove Handwritten Note Lock" : "Remove Note Lock"
    }

    /// Notes and handwritten notes that are in the map (not drafts) and not locked.
    func canLockNote(_ attachmentID: UUID) -> Bool {
        guard let attachment = map.attachment(withID: attachmentID)?.attachment else { return false }
        return attachment.kind != .file && !attachment.isLocked
    }

    /// Plaintext of a locked note, nil while it is locked (no key in memory).
    func decryptedContent(of attachment: Attachment) -> Data? {
        guard let keyID = attachment.lockKeyID else { return attachmentStore.data(for: attachment.fileName) }
        guard let key = lock.noteKey(keyID), let sealed = attachmentStore.data(for: attachment.fileName) else {
            return nil
        }
        return try? LockCrypto.open(sealed, key: key, context: LockCrypto.noteContext(attachment.id))
    }

    /// What to store for new plaintext `data` of `attachment` (sealed for a
    /// locked note; nil when it is locked right now — nothing is written).
    func storedBytes(_ data: Data, for attachment: Attachment) -> Data? {
        guard let keyID = attachment.lockKeyID else { return data }
        guard let key = lock.noteKey(keyID) else { return nil }
        return try? LockCrypto.seal(data, key: key, context: LockCrypto.noteContext(attachment.id))
    }

    /// Lock Note: new key into the key store, encrypt the file, one undo
    /// step. `keepUnlocked`: the note's editor is open (it stays readable
    /// until it closes); from a menu the note is locked right away.
    @discardableResult
    func lockNote(_ attachmentID: UUID, keepUnlocked: Bool = false, undoManager: UndoManager?) throws -> LockKeyStorage {
        guard canLockNote(attachmentID), let attachment = attachment(attachmentID),
              admitsContentChange(Self.lockActionName(for: attachment.kind), undoManager: undoManager) else {
            throw LockError.notLockable
        }
        if let problem = lock.services.authenticator.availabilityProblem() {
            throw LockError.authenticationUnavailable(problem)
        }
        let plain = attachmentStore.data(for: attachment.fileName) ?? Data()
        let key = LockCrypto.newKey()
        let keyID = UUID()
        let storage = try lock.services.keyStore.saveKey(key, id: keyID)
        let sealed = try LockCrypto.seal(plain, key: key, context: LockCrypto.noteContext(attachmentID))
        let sealedName = Self.lockedFileName(for: attachment)
        attachmentStore.markSensitive(attachment.fileName)
        guard swapFile(of: attachmentID, toName: sealedName, data: sealed, lockKeyID: keyID,
                       actionName: Self.lockActionName(for: attachment.kind), undoManager: undoManager) else {
            throw LockError.notLockable
        }
        if keepUnlocked { lock.unlockNote(attachmentID, keyID: keyID, key: key) }
        return storage
    }

    /// Opening a locked note: authenticate, fetch its key, check it decrypts.
    @MainActor
    func unlockNote(_ attachmentID: UUID, reason: String) async -> LockAuthResult {
        guard let attachment = attachment(attachmentID), let keyID = attachment.lockKeyID else { return .success }
        if lock.isNoteUnlocked(attachmentID), lock.noteKey(keyID) != nil { return .success }
        let result = await lock.services.authenticator.authenticate(reason: reason)
        guard result == .success else { return result }
        do {
            guard let key = try lock.services.keyStore.key(for: keyID) else { throw LockError.keyUnavailable }
            if let sealed = attachmentStore.data(for: attachment.fileName) {
                _ = try LockCrypto.open(sealed, key: key, context: LockCrypto.noteContext(attachmentID))
            }
            lock.unlockNote(attachmentID, keyID: keyID, key: key)
            return .success
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Remove Note Lock: authenticate (also when it is unlocked), decrypt,
    /// back to "<UUID>.md" — one undo step (undo restores the encrypted file).
    @MainActor
    func removeNoteLock(_ attachmentID: UUID, reason: String, undoManager: UndoManager?) async -> LockAuthResult {
        guard let attachment = attachment(attachmentID), let keyID = attachment.lockKeyID,
              admitsContentChange(Self.removeLockActionName(for: attachment.kind), undoManager: undoManager) else {
            return .cancelled
        }
        let result = await lock.services.authenticator.authenticate(reason: reason)
        guard result == .success else { return result }
        do {
            guard let key = try lock.noteKey(keyID) ?? lock.services.keyStore.key(for: keyID) else {
                throw LockError.keyUnavailable
            }
            let sealed = attachmentStore.data(for: attachment.fileName) ?? Data()
            let plain = sealed.isEmpty ? Data()
                : try LockCrypto.open(sealed, key: key, context: LockCrypto.noteContext(attachmentID))
            guard let current = self.attachment(attachmentID), current.lockKeyID == keyID,
                  swapFile(of: attachmentID, toName: Self.unlockedFileName(for: current), data: plain, lockKeyID: nil,
                           actionName: Self.removeLockActionName(for: current.kind), undoManager: undoManager) else {
                return .failed("The note changed meanwhile. Try again.")
            }
            lock.relockNote(attachmentID, keyID: keyID)
            return .success
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    static func lockedFileName(for attachment: Attachment) -> String {
        attachment.fileName + LockedPackage.sealedSuffix
    }

    static func unlockedFileName(for attachment: Attachment) -> String {
        if attachment.fileName.hasSuffix(LockedPackage.sealedSuffix) {
            return String(attachment.fileName.dropLast(LockedPackage.sealedSuffix.count))
        }
        return Attachment.defaultFileName(id: attachment.id, kind: attachment.kind)
    }

    /// Writes `data` under `name` and points the attachment at it (one
    /// step). The previous file stays in the store (orphan retained), so
    /// undo / redo just switch the attachment back and forth.
    private func swapFile(of attachmentID: UUID, toName name: String, data: Data, lockKeyID: UUID?,
                          actionName: String, undoManager: UndoManager?) -> Bool {
        guard Attachment.isValidFileName(name),
              let edits = try? map.updateAttachmentEdits(attachmentID, {
                  $0.fileName = name
                  $0.lockKeyID = lockKeyID
              }), !edits.isEmpty else { return false }
        attachmentStore.write(data, to: name)
        return perform(edits, actionName: actionName, undoManager: undoManager)
    }
}
