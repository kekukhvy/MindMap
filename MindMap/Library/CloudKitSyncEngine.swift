import CloudKit
import Foundation
import os

/// `LibrarySyncEngine` on CKSyncEngine (iOS 17 / macOS 14): private
/// database, zone "Maps". CKSyncEngine schedules sends after `add`, fetches
/// on push notifications (database subscription it manages itself) and
/// retries transient errors; this adapter persists its state and forwards
/// events to `LibrarySync`.
@MainActor
final class CloudKitSyncEngine: LibrarySyncEngine, CKSyncEngineDelegate {
    private static let log = Logger(subsystem: "com.kekukh.MindMap", category: "LibrarySync")

    private weak var sync: LibrarySync?
    private var engine: CKSyncEngine?

    init(database: CKDatabase, sync: LibrarySync) {
        self.sync = sync
        var serialization: CKSyncEngine.State.Serialization?
        if let data = sync.cache.loadEngineState() {
            serialization = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        let configuration = CKSyncEngine.Configuration(database: database, stateSerialization: serialization,
                                                       delegate: self)
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if serialization == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(LibraryZone.zone)])
        }
    }

    // MARK: LibrarySyncEngine

    func add(_ changes: [LibraryRecordChange]) {
        guard let engine, !changes.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: changes.map { change in
            switch change {
            case let .save(id): return .saveRecord(id)
            case let .delete(id): return .deleteRecord(id)
            }
        })
    }

    var pendingChanges: [LibraryRecordChange] {
        (engine?.state.pendingRecordZoneChanges ?? []).compactMap { change in
            switch change {
            case let .saveRecord(id): return .save(id)
            case let .deleteRecord(id): return .delete(id)
            @unknown default: return nil
            }
        }
    }

    func fetchChanges() async throws {
        try await engine?.fetchChanges()
    }

    func sendChanges() async throws {
        try await engine?.sendChanges()
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let sync else { return }
        switch event {
        case let .stateUpdate(update):
            sync.cache.saveEngineState(try? JSONEncoder().encode(update.stateSerialization))
        case let .accountChange(change):
            switch change.changeType {
            case .switchAccounts:
                sync.resetServerState()
            case .signIn:
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(LibraryZone.zone)])
                sync.scanForLocalChanges()
            case .signOut:
                break // keep the local library; it uploads again after sign-in
            @unknown default:
                break
            }
        case let .fetchedDatabaseChanges(changes):
            if changes.deletions.contains(where: { $0.zoneID == LibraryZone.id }) {
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(LibraryZone.zone)])
                sync.handleZoneDeleted()
            }
        case let .fetchedRecordZoneChanges(changes):
            await sync.handleFetched(modifications: changes.modifications.map(\.record),
                                     deletions: changes.deletions.map { ($0.recordID, $0.recordType) })
        case let .sentDatabaseChanges(sent):
            for failure in sent.failedZoneSaves {
                Self.log.error("zone save failed: \(failure.error.localizedDescription, privacy: .public)")
            }
        case let .sentRecordZoneChanges(sent):
            var failed: [(CKRecord, LibrarySaveFailure)] = []
            for failure in sent.failedRecordSaves {
                let mapped = Self.failure(failure.error)
                if case .zoneMissing = mapped {
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(LibraryZone.zone)])
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                }
                failed.append((failure.record, mapped))
            }
            await sync.handleSent(saved: sent.savedRecords, failed: failed, deleted: sent.deletedRecordIDs,
                                  failedDeletes: sent.failedRecordDeletes.map { ($0.key, Self.failure($0.value)) })
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] recordID in
            await self?.sync?.record(for: recordID)
        }
    }

    // MARK: Errors

    static func failure(_ error: CKError) -> LibrarySaveFailure {
        switch error.code {
        case .serverRecordChanged:
            if let server = error.serverRecord { return .conflict(serverRecord: server) }
            return .other(error.localizedDescription)
        case .unknownItem:
            return .unknownItem
        case .zoneNotFound, .userDeletedZone:
            return .zoneMissing
        default:
            return .other(error.localizedDescription)
        }
    }
}
