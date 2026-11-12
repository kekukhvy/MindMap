import CryptoKit
import Foundation
import Security

/// Where a lock key went.
enum LockKeyStorage: Equatable {
    /// Synchronizable keychain item: iCloud Keychain copies it to the
    /// user's other devices (same team + bundle ID = same access group).
    case iCloudKeychain
    /// Only this device (macOS build without a team-signed provisioning
    /// profile: the data protection keychain is unavailable, see REPORT.md).
    case thisDevice
}

/// Keys of locked maps / notes by key ID. The real store is the keychain;
/// tests use `InMemoryKeyStore`.
protocol LockKeyStore: AnyObject {
    func saveKey(_ key: SymmetricKey, id: UUID) throws -> LockKeyStorage
    /// nil = no such key on this device (not synced yet / iCloud Keychain off).
    func key(for id: UUID) throws -> SymmetricKey?
}

/// Test / preview key store.
final class InMemoryKeyStore: LockKeyStore {
    private(set) var keys: [UUID: Data] = [:]

    init() {}

    func saveKey(_ key: SymmetricKey, id: UUID) throws -> LockKeyStorage {
        keys[id] = LockCrypto.keyData(key)
        return .iCloudKeychain
    }

    func key(for id: UUID) throws -> SymmetricKey? {
        keys[id].map { SymmetricKey(data: $0) }
    }

    func removeKey(_ id: UUID) {
        keys[id] = nil
    }
}

/// Keys as generic passwords: service `com.kekukh.MindMap.lock-key`,
/// account = key ID, `kSecAttrSynchronizable` = true (iCloud Keychain),
/// accessible after first unlock, in the app's default access group
/// (`<TeamID>.com.kekukh.MindMap` on iPad and Mac alike).
///
/// Synchronizable items cannot carry a `SecAccessControl` with biometry /
/// user presence (such items never leave the device), so the keychain does
/// NOT enforce Face ID / Touch ID itself: the app authenticates with
/// `LAContext` (`.deviceOwnerAuthentication`) before it reads a key.
///
/// macOS: the data protection keychain (needed for synchronizable items)
/// requires a team-signed build. An ad-hoc signed build gets
/// `errSecMissingEntitlement`; keys then go to the login keychain of this
/// Mac only (`LockKeyStorage.thisDevice`). Keys are never deleted: older
/// copies / versions of a file may still need them.
final class KeychainKeyStore: LockKeyStore {
    static let service = "com.kekukh.MindMap.lock-key"

    init() {}

    func saveKey(_ key: SymmetricKey, id: UUID) throws -> LockKeyStorage {
        let data = LockCrypto.keyData(key)
        let status = add(data, id: id, synchronizable: true)
        if status == errSecSuccess { return .iCloudKeychain }
        #if os(macOS)
        if status == errSecMissingEntitlement {
            let legacy = add(data, id: id, synchronizable: false)
            if legacy == errSecSuccess { return .thisDevice }
            throw LockError.keychain(legacy)
        }
        #endif
        throw LockError.keychain(status)
    }

    func key(for id: UUID) throws -> SymmetricKey? {
        var query = baseQuery(id: id)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        #if os(macOS)
        if status == errSecItemNotFound || status == errSecMissingEntitlement {
            // Login keychain (ad-hoc signed builds, see the type comment).
            query[kSecUseDataProtectionKeychain as String] = nil
            query[kSecAttrSynchronizable as String] = nil
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        #endif
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else { throw LockError.keychain(errSecDecode) }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw LockError.keychain(status)
        }
    }

    private func baseQuery(id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    private func add(_ data: Data, id: UUID, synchronizable: Bool) -> OSStatus {
        var attributes = baseQuery(id: id)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "MindMap lock key"
        attributes[kSecAttrDescription as String] = "Encryption key of a locked MindMap map or note"
        if synchronizable {
            attributes[kSecAttrSynchronizable as String] = true
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            #if os(macOS)
            attributes[kSecUseDataProtectionKeychain as String] = true
            #endif
        }
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Same key ID again (should not happen: IDs are random UUIDs).
            var query = baseQuery(id: id)
            if synchronizable {
                query[kSecAttrSynchronizable as String] = true
                #if os(macOS)
                query[kSecUseDataProtectionKeychain as String] = true
                #endif
            }
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        return status
    }
}
