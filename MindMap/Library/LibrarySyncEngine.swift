import CloudKit
import Foundation

/// A pending upload / deletion of one record.
enum LibraryRecordChange: Hashable {
    case save(CKRecord.ID)
    case delete(CKRecord.ID)

    var recordID: CKRecord.ID {
        switch self {
        case let .save(id), let .delete(id): return id
        }
    }
}

/// Why a record could not be saved (mapped from `CKError` by the engine).
enum LibrarySaveFailure {
    /// Changed on the server since our base: merge with `serverRecord`.
    case conflict(serverRecord: CKRecord)
    /// The record is gone on the server (deleted on another device).
    case unknownItem
    /// The "Maps" zone does not exist (yet / any more).
    case zoneMissing
    /// Anything else (network, quota, …); the engine retries transient ones.
    case other(String)
}

/// What `LibrarySync` needs from the sync engine: `CloudKitSyncEngine`
/// (CKSyncEngine, private database) in the app, a mock in tests. The engine
/// calls back into `LibrarySync` (`record(for:)`, `handleSaved`,
/// `handleSaveFailure`, `handleDeleted`, `handleFetched`, …).
@MainActor
protocol LibrarySyncEngine: AnyObject {
    func add(_ changes: [LibraryRecordChange])
    var pendingChanges: [LibraryRecordChange] { get }
    /// Fetch all zone changes since the last fetch.
    func fetchChanges() async throws
    /// Send pending changes now.
    func sendChanges() async throws
}
