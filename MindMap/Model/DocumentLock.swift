import CryptoKit
import Foundation
import Observation

/// What saves of a locked map need (header + key + reuse cache).
struct MapLockConfig {
    var header: LockHeader
    var key: SymmetricKey
}

/// User requests from menus anywhere (topic context menu, File menu, iPad
/// documents menu, editor toolbars); the document's `MapLockGate` runs
/// them (it has the undo manager and presents prompts / alerts).
enum LockRequest: Equatable {
    case lockMap
    case removeMapLock
    case lockNow
    case unlockMap
    case lockNote(UUID)
    case removeNoteLock(UUID)
    /// Save now and drop the file's older (plaintext) versions.
    case saveAndPurgeVersions
}

/// Lock state of one open document (owned by its `MindMapModel`).
///
/// Map lock states:
/// - plain: `config == nil`, nothing hidden.
/// - sealed: opened from a locked package and not decrypted yet
///   (`sealedPackage != nil`): the model holds an empty placeholder map,
///   saves write `sealedPackage` back unchanged (never overwrite it),
///   the lock screen is shown.
/// - unlocked: `config != nil`, content + key in memory, saves encrypt.
/// - relocked: as unlocked but `isShowingLockScreen` (UI hidden; the next
///   unlock only needs authentication, the key is still in memory).
///
/// Notes: a locked note's key is in memory only while it is unlocked
/// (`unlockedNoteKeys`, by key ID); relocking forgets it.
@Observable
final class DocumentLock {
    /// Non-nil = the map is locked (saved encrypted).
    private(set) var config: MapLockConfig? {
        didSet { if config?.header.keyID != oldValue?.header.keyID { sealCache.reset() } }
    }
    /// Locked package as read, while it has not been decrypted.
    @ObservationIgnored private(set) var sealedPackage: FileWrapper?
    /// Header of a sealed package (its config is unknown until decrypted).
    private(set) var sealedHeader: LockHeader?
    /// Lock screen instead of the map.
    private(set) var isShowingLockScreen = false
    /// Shown on the lock screen (missing key, failed authentication, …).
    var message: String?
    var isAuthenticating = false
    /// The lock screen should prompt by itself (just opened / back from
    /// background) — cleared once it did.
    var wantsAutoPrompt = false
    /// Pending request for the gate (see `LockRequest`).
    var request: LockRequest?
    /// Last unlock of the map or a note (idle timeout counts from here too).
    @ObservationIgnored var unlockedAt: Date?

    /// Unlocked notes (attachment IDs) and their keys (by key ID).
    private(set) var unlockedNotes: Set<UUID> = []
    @ObservationIgnored private var noteKeys: [UUID: SymmetricKey] = [:]

    @ObservationIgnored let sealCache = SealCache()
    @ObservationIgnored var services: LockServices = .shared

    init() {}

    // MARK: Map

    /// The map is locked (encrypted on disk, sealed or not).
    var isMapLocked: Bool { config != nil || sealedPackage != nil }
    /// Content not decrypted yet (placeholder model).
    var isSealed: Bool { sealedPackage != nil }
    var keyID: UUID? { config?.header.keyID ?? sealedHeader?.keyID }

    /// Opened from a locked package: keep it as-is until decrypted.
    func configureSealed(header: LockHeader, package: FileWrapper) {
        sealedHeader = header
        sealedPackage = package
        config = nil
        isShowingLockScreen = true
        wantsAutoPrompt = true
        message = nil
    }

    /// Decrypted with `key`: saves encrypt from now on.
    func didDecrypt(header: LockHeader, key: SymmetricKey, pairs: [String: (plain: FileWrapper, sealed: FileWrapper)]) {
        config = MapLockConfig(header: header, key: key)
        sealCache.replace(with: pairs, keyID: header.keyID)
        sealedPackage = nil
        sealedHeader = nil
    }

    /// Sets / clears the map lock (Lock Map, Remove Map Lock and their undo).
    func setConfig(_ config: MapLockConfig?) {
        self.config = config
        if config == nil { isShowingLockScreen = false }
    }

    func showUnlocked(at date: Date) {
        isShowingLockScreen = false
        message = nil
        unlockedAt = date
    }

    /// Hides a locked map behind the lock screen and forgets unlocked notes.
    /// Returns true when the map was visible and is now hidden.
    @discardableResult
    func relock(autoPrompt: Bool = false) -> Bool {
        relockNotes()
        guard isMapLocked, !isShowingLockScreen else { return false }
        isShowingLockScreen = true
        wantsAutoPrompt = autoPrompt
        message = nil
        return true
    }

    /// Idle auto-lock: true when an unlocked locked map (or unlocked notes)
    /// had no activity for `timeout` seconds (0 / negative = never).
    func isIdleExpired(now: Date, lastActivity: Date, timeout: TimeInterval) -> Bool {
        guard timeout > 0, (isMapLocked && !isShowingLockScreen) || !unlockedNotes.isEmpty else { return false }
        let since = max(lastActivity, unlockedAt ?? .distantPast)
        return now.timeIntervalSince(since) >= timeout
    }

    // MARK: Notes

    func isNoteUnlocked(_ attachmentID: UUID) -> Bool {
        unlockedNotes.contains(attachmentID)
    }

    func noteKey(_ keyID: UUID) -> SymmetricKey? {
        noteKeys[keyID]
    }

    func unlockNote(_ attachmentID: UUID, keyID: UUID, key: SymmetricKey, at date: Date = Date()) {
        noteKeys[keyID] = key
        unlockedNotes.insert(attachmentID)
        unlockedAt = max(unlockedAt ?? date, date)
    }

    /// Note window / sheet closed: forget its key.
    func relockNote(_ attachmentID: UUID, keyID: UUID?) {
        unlockedNotes.remove(attachmentID)
        if let keyID { noteKeys[keyID] = nil }
    }

    func relockNotes() {
        unlockedNotes = []
        noteKeys = [:]
    }
}
