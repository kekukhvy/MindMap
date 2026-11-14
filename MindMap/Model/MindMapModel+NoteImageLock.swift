import CryptoKit
import Foundation

/// Images of a locked Markdown note (see `NoteImage`) are sealed like its text:
/// same note key and context, stored as "<image name>.enc".
extension MindMapModel {
    /// Plaintext of image `fileName` (the name used in the note's link), nil if
    /// unknown or the note is locked right now (no key in memory).
    func noteImageData(_ fileName: String, noteID: UUID) -> Data? {
        guard let attachment = attachment(noteID), let keyID = attachment.lockKeyID else {
            return attachmentStore.data(for: fileName)
        }
        guard let key = lock.noteKey(keyID), let sealed = attachmentStore.data(for: fileName + LockedPackage.sealedSuffix)
        else { return nil }
        return try? LockCrypto.open(sealed, key: key, context: LockCrypto.noteContext(noteID))
    }

    /// Lock Note: every plain image of the note is stored sealed (the plain file is dropped at the next save).
    func sealNoteImages(of noteID: UUID, key: SymmetricKey) throws {
        for (name, data) in attachmentStore.noteImages(of: noteID) where !NoteImage.isSealed(name) {
            attachmentStore.markSensitive(name)
            let sealed = try LockCrypto.seal(data, key: key, context: LockCrypto.noteContext(noteID))
            attachmentStore.write(sealed, to: name + LockedPackage.sealedSuffix)
        }
    }

    /// Remove Note Lock: every sealed image of the note is stored plain again.
    func openNoteImages(of noteID: UUID, key: SymmetricKey) throws {
        for (name, sealed) in attachmentStore.noteImages(of: noteID) where NoteImage.isSealed(name) {
            let plain = try LockCrypto.open(sealed, key: key, context: LockCrypto.noteContext(noteID))
            attachmentStore.write(plain, to: String(name.dropLast(LockedPackage.sealedSuffix.count)))
        }
    }
}
