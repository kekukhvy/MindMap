import CloudKit
import Foundation
#if os(macOS)
import Security
#endif

/// Whether the iCloud map library can sync on this device.
enum LibraryAvailability: Equatable {
    case checking
    case available
    case unavailable(String)

    var isAvailable: Bool { self == .available }

    /// One line for Settings / Welcome (WP14b).
    var statusText: String {
        switch self {
        case .checking: return "Checking iCloud…"
        case .available: return "iCloud Sync is on"
        case let .unavailable(reason): return "iCloud Sync unavailable — \(reason)"
        }
    }
}

/// Answers "can the library sync?" (CloudKit account in the app; a mock in
/// tests).
protocol LibraryAccountProviding {
    func availability() async -> LibraryAvailability
    /// The CloudKit container (only when `availability()` was `.available`).
    func makeContainer() -> CKContainer?
}

/// The real account check. Never touches `CKContainer` unless this build
/// carries the iCloud entitlement (a build without it would crash in
/// CloudKit): the container ID comes from Info.plist (`MindMapCloudKitContainer`,
/// empty in local ad-hoc builds, see Tools/xcb/xcb.sh) and macOS also
/// checks the signed entitlements.
struct CloudKitAccountProvider: LibraryAccountProviding {
    static let infoKey = "MindMapCloudKitContainer"
    var containerIdentifier: String? = CloudKitAccountProvider.bundleContainerIdentifier

    static var bundleContainerIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
              value.hasPrefix("iCloud.") else { return nil }
        return value
    }

    func availability() async -> LibraryAvailability {
        guard let identifier = containerIdentifier, Self.hasCloudKitEntitlement(identifier) else {
            return .unavailable("this build is not signed for iCloud")
        }
        do {
            return Self.availability(for: try await CKContainer(identifier: identifier).accountStatus())
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func makeContainer() -> CKContainer? {
        guard let identifier = containerIdentifier, Self.hasCloudKitEntitlement(identifier) else { return nil }
        return CKContainer(identifier: identifier)
    }

    static func availability(for status: CKAccountStatus) -> LibraryAvailability {
        switch status {
        case .available: return .available
        case .noAccount: return .unavailable("not signed in to iCloud")
        case .restricted: return .unavailable("iCloud is restricted on this device")
        case .temporarilyUnavailable: return .unavailable("iCloud is temporarily unavailable")
        case .couldNotDetermine: return .unavailable("the iCloud account could not be checked")
        @unknown default: return .unavailable("unknown iCloud account status")
        }
    }

    /// macOS: the running binary's entitlements list the container and
    /// CloudKit. iOS: a device build cannot run without its profile and the
    /// simulator embeds the entitlements, so the Info.plist key suffices.
    static func hasCloudKitEntitlement(_ identifier: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        guard let containers = containers as? [String], containers.contains(identifier),
              let services = services as? [String], services.contains("CloudKit") || services.contains("*") else {
            return false
        }
        return true
        #else
        return true
        #endif
    }
}

/// Test / preview provider.
struct FixedAccountProvider: LibraryAccountProviding {
    var result: LibraryAvailability

    func availability() async -> LibraryAvailability { result }
    func makeContainer() -> CKContainer? { nil }
}
