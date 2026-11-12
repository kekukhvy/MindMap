import Foundation

/// One-line sync state of the library (Settings, store badge, library list).
enum LibrarySyncStatus: Equatable {
    case checking
    case synced
    case syncing
    case offline
    /// iCloud cannot be used (reason from `LibraryAvailability`).
    case unavailable(String)

    /// Library status from the account, network and pending uploads.
    static func make(availability: LibraryAvailability, isOnline: Bool, hasPendingChanges: Bool) -> Self {
        switch availability {
        case .checking: return .checking
        case let .unavailable(reason): return .unavailable(reason)
        case .available:
            if !isOnline { return .offline }
            return hasPendingChanges ? .syncing : .synced
        }
    }

    var title: String {
        switch self {
        case .checking: return "Checking iCloud…"
        case .synced: return "Synced"
        case .syncing: return "Syncing…"
        case .offline: return "Offline — changes upload when you are back online"
        case let .unavailable(reason): return "iCloud unavailable — \(reason)"
        }
    }

    /// Short form for badges / list rows.
    var shortTitle: String {
        switch self {
        case .checking: return "Checking…"
        case .synced: return "Synced"
        case .syncing: return "Syncing…"
        case .offline: return "Offline"
        case .unavailable: return "Not syncing"
        }
    }

    var systemImage: String {
        switch self {
        case .checking, .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .synced: return "checkmark.icloud"
        case .offline: return "icloud.slash"
        case .unavailable: return "exclamationmark.icloud"
        }
    }

    /// What the user can do about `.unavailable` / `.offline` (nil = nothing to fix).
    var fixHint: String? {
        switch self {
        case .offline:
            return "Maps stay on this device and upload automatically once the network is back."
        case let .unavailable(reason):
            if reason.contains("not signed for iCloud") {
                return "This copy of MindMap was built without iCloud. Install a build signed with the "
                    + "developer team (Xcode ▸ Settings ▸ Accounts: add the Apple ID, then build once with the "
                    + "iCloud capability). Library maps are kept on this device meanwhile."
            }
            if reason.contains("not signed in") {
                #if os(macOS)
                return "Open System Settings ▸ Apple Account and sign in to iCloud. iCloud Drive is not needed."
                #else
                return "Open Settings ▸ Apple Account and sign in to iCloud. iCloud Drive is not needed."
                #endif
            }
            if reason.contains("restricted") {
                return "iCloud is restricted by Screen Time or a device profile. Allow iCloud for this device, "
                    + "or use “Files” storage."
            }
            return "Check that you are signed in to iCloud and online, then reopen MindMap. Library maps stay "
                + "on this device and upload later."
        default:
            return nil
        }
    }
}
