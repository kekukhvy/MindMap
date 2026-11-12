import CryptoKit
import Foundation

/// Errors of the map / note lock (WP12). Messages are shown to the user.
enum LockError: Error, Equatable, LocalizedError {
    /// The key is not in this device's keychain (yet): another device locked
    /// it and iCloud Keychain has not synced it here, or is off.
    case keyUnavailable
    /// Wrong key, damaged or modified file (AES-GCM authentication failed).
    case decryptionFailed
    /// `lock.json` missing or unreadable.
    case invalidHeader
    /// Written by a newer app version.
    case unsupportedVersion(Int)
    /// Keychain error (OSStatus).
    case keychain(Int32)
    /// No passcode / password set up, biometry locked out etc.
    case authenticationUnavailable(String)
    /// Only notes and handwritten notes (not drafts, not files) can be locked.
    case notLockable

    static let missingKeyMessage =
        "Key not available on this device yet — make sure iCloud Keychain is on (Settings › Apple Account › iCloud › Passwords and Keychain) and give it a moment to sync."

    var errorDescription: String? {
        switch self {
        case .keyUnavailable: return Self.missingKeyMessage
        case .decryptionFailed:
            return "It could not be decrypted with the key on this device. The file may be damaged, or iCloud Keychain has not synced the current key yet."
        case .invalidHeader: return "The lock information of this map is damaged."
        case let .unsupportedVersion(version):
            return "This map was locked by a newer version of MindMap (lock format \(version)). Update the app to open it."
        case let .keychain(status): return "The keychain refused the key (error \(status))."
        case let .authenticationUnavailable(message): return message
        case .notLockable: return "Only notes and handwritten notes can be locked."
        }
    }
}

/// AES-256-GCM (CryptoKit) for locked maps and notes. Every sealed blob is
/// CryptoKit's combined representation: random 96-bit nonce ‖ ciphertext ‖
/// 128-bit tag. The associated data binds a blob to its place (map.json,
/// attachment name, note id), so files cannot be swapped unnoticed.
enum LockCrypto {
    static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    static func seal(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        let box = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw LockError.decryptionFailed }
        return combined
    }

    static func open(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
        } catch {
            throw LockError.decryptionFailed
        }
    }

    static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    // MARK: Associated data

    private static let packagePrefix = "com.kekukh.mindmap.lock.v1|"

    static let mapContext = packagePrefix + "map.json"

    /// Context of `attachments/<name>` in a locked package (logical name).
    static func attachmentContext(_ name: String) -> String {
        packagePrefix + "attachments/" + name
    }

    /// Context of a locked note's file (bound to the attachment, not its
    /// file name, so renaming the note title changes nothing).
    static func noteContext(_ attachmentID: UUID) -> String {
        "com.kekukh.mindmap.note-lock.v1|" + attachmentID.uuidString
    }
}

/// `lock.json`: the only plaintext file of a locked map package. It holds no
/// content (no title, no topic text) — just what is needed to find the key.
struct LockHeader: Codable, Equatable {
    static let fileName = "lock.json"
    static let currentVersion = 1

    var format = "com.kekukh.mindmap.lock"
    var version = LockHeader.currentVersion
    /// Keychain account of the key (generic password, see `KeychainKeyStore`).
    var keyID: UUID
    var cipher = "AES-256-GCM"
    /// The key is random (not derived from a password): no KDF, no salt.
    var kdf = "none"
    var nonce = "random 96-bit per file, stored in front of ciphertext+tag (CryptoKit combined)"
    var keyStorage = "keychain generic password, synchronizable (iCloud Keychain)"

    init(keyID: UUID) {
        self.keyID = keyID
    }

    private enum CodingKeys: String, CodingKey {
        case format, version, keyID, cipher, kdf, nonce, keyStorage
    }

    /// Only `keyID` and `version` matter; descriptive fields are optional.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyID = try c.decode(UUID.self, forKey: .keyID)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? format
        cipher = try c.decodeIfPresent(String.self, forKey: .cipher) ?? cipher
        kdf = try c.decodeIfPresent(String.self, forKey: .kdf) ?? kdf
        nonce = try c.decodeIfPresent(String.self, forKey: .nonce) ?? nonce
        keyStorage = try c.decodeIfPresent(String.self, forKey: .keyStorage) ?? keyStorage
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> LockHeader {
        guard let header = try? JSONDecoder().decode(LockHeader.self, from: data) else { throw LockError.invalidHeader }
        guard header.version <= currentVersion else { throw LockError.unsupportedVersion(header.version) }
        return header
    }
}
