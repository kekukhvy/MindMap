import CloudKit
import Foundation

/// Sync logic of the map library (WP14), independent of CloudKit's engine
/// (`LibrarySyncEngine`: CKSyncEngine in the app, a mock in tests).
///
/// Offline-first: the editor only ever reads/writes the cached packages
/// (`LibraryCache`). This class
/// - notices local saves (`localMapDidChange`, debounced; `scanForLocalChanges`
///   at launch / foreground) by comparing content hashes with what the
///   server has (`MapSyncMeta`) and queues record saves / deletions;
/// - builds the records to upload from the package (`record(for:)`); a
///   locked map uploads its encrypted files only;
/// - integrates fetched records: unchanged local copy → replaced; changed on
///   both sides → three-way merge with the base snapshot (`MapMerge`), or a
///   "conflict copy" map when either side is locked (nothing to merge
///   without the key); remote deletion → removed unless edited here (then
///   uploaded again).
@MainActor
final class LibrarySync {
    let cache: LibraryCache
    private(set) var engine: LibrarySyncEngine?
    private(set) var state: LibrarySyncState
    /// Delay between a save and its upload (several saves → one upload).
    var debounceInterval: Duration = .seconds(2)
    /// Maps added / removed / replaced by sync (UI refresh hook).
    var onLibraryChanged: (() -> Void)?
    /// Any bookkeeping change (pending uploads, sent, fetched): status UI.
    var onStateChanged: (() -> Void)?
    private(set) var lastError: String?
    /// Merge results by map (for a "merged changes" notice, WP14b).
    private(set) var lastConflicts: [UUID: [MapMerge.Conflict]] = [:]

    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    /// Plain payloads being uploaded, by payload hash (become the merge base).
    private var sentPayloads: [String: Data] = [:]
    private var stagedFiles: [CKRecord.ID: [URL]] = [:]

    init(cache: LibraryCache) {
        self.cache = cache
        state = cache.loadState()
    }

    /// Connects the engine (account available) and queues everything that
    /// changed while there was none.
    func attach(_ engine: LibrarySyncEngine?) {
        self.engine = engine
        guard let engine else { return }
        engine.add(state.deletedMaps.map { .delete(LibraryRecordID.map($0)) })
        scanForLocalChanges()
    }

    // MARK: - Local changes

    /// A library package was saved (file presenter): after the debounce
    /// interval, queue what changed and send it at once instead of waiting
    /// for the engine's own scheduling.
    func localMapDidChange(_ id: UUID) {
        debounceTasks[id]?.cancel()
        let delay = debounceInterval
        debounceTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            debounceTasks[id] = nil
            if checkForLocalChanges(id) { try? await engine?.sendChanges() }
        }
        onStateChanged?()
    }

    /// Local changes of map `id` not uploaded yet (waiting for the
    /// debounce, queued in the engine, or never synced).
    func isPending(_ id: UUID) -> Bool {
        if debounceTasks[id] != nil { return true }
        if let engine, engine.pendingChanges.contains(where: { LibraryRecordID.parse($0.recordID)?.mapID == id }) {
            return true
        }
        return state.maps[id]?.isOnServer != true
    }

    /// Anything waiting to be uploaded / deleted.
    var hasPendingChanges: Bool {
        !debounceTasks.isEmpty || !(engine?.pendingChanges.isEmpty ?? true)
    }

    func scanForLocalChanges() {
        for id in Set(cache.mapIDs()).union(state.maps.keys) { checkForLocalChanges(id) }
    }

    /// Queues the record changes of map `id` that the server does not have;
    /// true when it queued any.
    @discardableResult
    func checkForLocalChanges(_ id: UUID) -> Bool {
        guard let url = cache.packageURL(for: id) else {
            // Package removed outside `deleteMap` (e.g. Finder).
            if state.maps[id] != nil { deleteMap(id) }
            return false
        }
        guard let snapshot = try? LibraryPackageSnapshot.read(at: url, mapID: id) else { return false }
        var meta = state.maps[id] ?? MapSyncMeta()
        meta.title = snapshot.title
        meta.isEncrypted = snapshot.isEncrypted
        meta.modified = snapshot.modified
        // A file the server has as it is here (e.g. uploaded from here since)
        // is not waiting for a download any more.
        meta.missingAttachments = meta.missingAttachments.filter {
            meta.syncedAttachments[$0] == nil || meta.syncedAttachments[$0] != snapshot.attachmentHashes[$0]
        }
        state.maps[id] = meta
        persist()
        // Files of the server version still downloading: uploading now
        // would drop them from the map's attachment list everywhere.
        guard meta.missingAttachments.isEmpty else { return false }
        let changes = Self.pendingChanges(for: snapshot, meta: meta)
        engine?.add(changes)
        return !changes.isEmpty
    }

    /// Map record first (attachments reference it).
    static func pendingChanges(for snapshot: LibraryPackageSnapshot, meta: MapSyncMeta) -> [LibraryRecordChange] {
        var attachmentChanges: [LibraryRecordChange] = []
        for (name, sha) in snapshot.attachmentHashes.sorted(by: { $0.key < $1.key })
        where meta.syncedAttachments[name] != sha {
            attachmentChanges.append(.save(LibraryRecordID.attachment(map: snapshot.mapID, fileName: name)))
        }
        for name in meta.syncedAttachments.keys.sorted() where snapshot.attachmentHashes[name] == nil {
            attachmentChanges.append(.delete(LibraryRecordID.attachment(map: snapshot.mapID, fileName: name)))
        }
        guard snapshot.payloadHash != meta.syncedPayloadHash || !attachmentChanges.isEmpty else { return [] }
        return [.save(LibraryRecordID.map(snapshot.mapID))] + attachmentChanges
    }

    static func isChanged(_ snapshot: LibraryPackageSnapshot, meta: MapSyncMeta) -> Bool {
        !pendingChanges(for: snapshot, meta: meta).isEmpty
    }

    /// Deletes a library map here and (attachments cascade) in iCloud.
    func deleteMap(_ id: UUID) {
        debounceTasks[id]?.cancel()
        cache.removeMap(id)
        if state.maps.removeValue(forKey: id)?.isOnServer == true {
            state.deletedMaps.insert(id)
            engine?.add([.delete(LibraryRecordID.map(id))])
        }
        persist()
        onLibraryChanged?()
    }

    // MARK: - Records to send

    func record(for recordID: CKRecord.ID) -> CKRecord? {
        switch LibraryRecordID.parse(recordID) {
        case let .map(id)?:
            // Queued before files of the server version started downloading:
            // not now (see `checkForLocalChanges`); queued again once they are here.
            guard state.maps[id]?.missingAttachments.isEmpty != false else { return nil }
            guard let url = cache.packageURL(for: id),
                  let snapshot = try? LibraryPackageSnapshot.read(at: url, mapID: id),
                  let staged = try? cache.stageUpload(snapshot.payload, name: id.uuidString + ".payload") else { return nil }
            stagedFiles[recordID, default: []].append(staged)
            if !snapshot.isEncrypted { sentPayloads[snapshot.payloadHash] = snapshot.payload }
            let meta = state.maps[id] ?? MapSyncMeta()
            return LibraryRecordCodec.mapRecord(snapshot, base: LibraryRecordCodec.record(fromSystemFields: meta.systemFields),
                                                revision: meta.revision + 1, payloadFile: staged)
        case let .attachment(id, name)?:
            guard let url = cache.packageURL(for: id) else { return nil }
            let file = url.appendingPathComponent(MindMapPackage.attachmentsFolderName).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path), let staged = try? cache.stageUpload(file),
                  let sha = try? LibraryHash.sha256(of: staged) else { return nil }
            stagedFiles[recordID, default: []].append(staged)
            let base = LibraryRecordCodec.record(fromSystemFields: state.maps[id]?.attachmentSystemFields[name])
            return LibraryRecordCodec.attachmentRecord(map: id, fileName: name, file: staged, sha256: sha, base: base)
        case nil:
            return nil
        }
    }

    // MARK: - Send results

    func handleSent(saved: [CKRecord], failed: [(CKRecord, LibrarySaveFailure)],
                    deleted: [CKRecord.ID], failedDeletes: [(CKRecord.ID, LibrarySaveFailure)]) async {
        var recheck = Set<UUID>()
        for record in saved {
            defer { cleanUpStaged(record.recordID) }
            switch LibraryRecordID.parse(record.recordID) {
            case let .map(id)?:
                guard var meta = state.maps[id] else { continue }
                let hash = record[MapRecordField.payloadHash] as? String
                meta.systemFields = LibraryRecordCodec.archiveSystemFields(of: record)
                meta.revision = Int(record[MapRecordField.revision] as? Int64 ?? Int64(meta.revision + 1))
                meta.syncedPayloadHash = hash
                let encrypted = (record[MapRecordField.encrypted] as? Int64 ?? 0) != 0
                cache.setBase(encrypted ? nil : hash.flatMap { sentPayloads[$0] }, for: id)
                if let hash { sentPayloads[hash] = nil }
                state.maps[id] = meta
                recheck.insert(id)
            case let .attachment(id, name)?:
                guard var meta = state.maps[id] else { continue }
                meta.syncedAttachments[name] = record[AttachmentRecordField.sha256] as? String
                meta.attachmentSystemFields[name] = LibraryRecordCodec.archiveSystemFields(of: record)
                state.maps[id] = meta
                recheck.insert(id)
            case nil:
                continue
            }
        }
        for (record, failure) in failed {
            cleanUpStaged(record.recordID)
            if let id = await handleSaveFailure(record, failure) { recheck.insert(id) }
        }
        for recordID in deleted {
            switch LibraryRecordID.parse(recordID) {
            case let .map(id)?:
                state.deletedMaps.remove(id)
            case let .attachment(id, name)?:
                state.maps[id]?.syncedAttachments[name] = nil
                state.maps[id]?.attachmentSystemFields[name] = nil
            case nil:
                break
            }
        }
        for (recordID, failure) in failedDeletes {
            if case .unknownItem = failure, case let .map(id)? = LibraryRecordID.parse(recordID) {
                state.deletedMaps.remove(id) // already gone
            } else if case let .other(message) = failure {
                lastError = message
            }
        }
        persist()
        for id in recheck { checkForLocalChanges(id) }
    }

    /// Returns the map to check again for changes to upload.
    private func handleSaveFailure(_ record: CKRecord, _ failure: LibrarySaveFailure) async -> UUID? {
        guard let parsed = LibraryRecordID.parse(record.recordID) else { return nil }
        switch (parsed, failure) {
        case let (.map(id), .conflict(serverRecord)):
            if let hash = record[MapRecordField.payloadHash] as? String { sentPayloads[hash] = nil }
            guard (serverRecord[MapRecordField.payload] as? CKAsset)?.fileURL != nil else {
                // Server version without its payload: fetch it, the merge
                // and the next upload follow from the fetched record.
                fetchChangesAfterCallback()
                return nil
            }
            await handleFetched(modifications: [serverRecord], deletions: [])
            if state.maps[id]?.missingAttachments.isEmpty == false {
                // The conflict carried only the Map record: fetch its files.
                fetchChangesAfterCallback()
            }
            return id
        case let (.attachment(id, name), .conflict(serverRecord)):
            state.maps[id]?.attachmentSystemFields[name] = LibraryRecordCodec.archiveSystemFields(of: serverRecord)
            state.maps[id]?.syncedAttachments[name] = serverRecord[AttachmentRecordField.sha256] as? String
            return id
        case let (.map(id), .unknownItem):
            // Deleted on another device while edited here: upload again.
            state.maps[id]?.forgetServerCopy()
            cache.setBase(nil, for: id)
            return id
        case let (.attachment(id, name), .unknownItem):
            state.maps[id]?.attachmentSystemFields[name] = nil
            state.maps[id]?.syncedAttachments[name] = nil
            return id
        case (_, .zoneMissing):
            resetServerState()
            return nil
        case let (_, .other(message)):
            lastError = message
            return nil
        }
    }

    /// Asks the engine to fetch, from outside the engine callback this runs
    /// in. CKSyncEngine traps ("Cannot await a call into CKSyncEngine from
    /// within a delegate callback ... Try performing this in a detached
    /// Task") when a callback's task awaits `fetchChanges()`; a plain `Task`
    /// inherits that context, a detached one does not.
    private func fetchChangesAfterCallback() {
        Task.detached { @MainActor [weak self] in try? await self?.engine?.fetchChanges() }
    }

    // MARK: - Fetched changes

    func handleFetched(modifications: [CKRecord], deletions: [(CKRecord.ID, CKRecord.RecordType)]) async {
        var touched: [UUID] = []
        for record in modifications {
            do {
                switch record.recordType {
                case LibraryRecordType.map:
                    let (remote, file) = try LibraryRecordCodec.remoteMap(from: record)
                    try stageIncoming(remote, payload: file)
                    touched.append(remote.mapID)
                case LibraryRecordType.attachment:
                    let attachment = try LibraryRecordCodec.remoteAttachment(from: record)
                    try stageIncoming(attachment)
                    if state.maps[attachment.mapID] != nil {
                        state.maps[attachment.mapID]?.attachmentSystemFields[attachment.fileName] = attachment.systemFields
                    }
                    touched.append(attachment.mapID)
                default:
                    continue
                }
            } catch {
                lastError = "A library record could not be read: \(error.localizedDescription)"
            }
        }
        for (recordID, _) in deletions {
            switch LibraryRecordID.parse(recordID) {
            case let .map(id)?:
                await handleRemoteDeletion(id)
            case let .attachment(id, name)?:
                // The server copy is gone; the map record decides whether
                // the file stays (integration), a later upload re-creates it.
                state.maps[id]?.attachmentSystemFields[name] = nil
            case nil:
                break
            }
        }
        var seen = Set<UUID>()
        for id in touched where seen.insert(id).inserted { await integrate(id) }
        persist()
    }

    /// Fetched versions not integrated yet (the app was quit or killed
    /// meanwhile; the engine does not fetch them again).
    func integrateStagedChanges() async {
        for id in cache.incomingMapIDs() { await integrate(id) }
        persist()
    }

    /// The "Maps" zone was deleted (user removed the app's iCloud data):
    /// everything here is uploaded again.
    func handleZoneDeleted() {
        resetServerState()
    }

    /// Account switched: this device's knowledge of the server is void.
    func resetServerState() {
        for id in state.maps.keys {
            state.maps[id]?.forgetServerCopy()
            cache.setBase(nil, for: id)
        }
        state.deletedMaps = []
        persist()
        scanForLocalChanges()
    }

    private func handleRemoteDeletion(_ id: UUID) async {
        try? FileManager.default.removeItem(at: cache.incomingFolder(for: id))
        guard let meta = state.maps[id] else { return }
        if let url = cache.packageURL(for: id), let local = try? LibraryPackageSnapshot.read(at: url, mapID: id),
           Self.isChanged(local, meta: meta) {
            // Delete vs edit: the edited map survives and is uploaded again.
            state.maps[id]?.forgetServerCopy()
            cache.setBase(nil, for: id)
            engine?.add(Self.pendingChanges(for: local, meta: state.maps[id] ?? MapSyncMeta()))
            return
        }
        let files = cache
        await Task.detached { files.removeMap(id) }.value // off the main thread, see `writePackage`
        state.maps[id] = nil
        onLibraryChanged?()
    }

    // MARK: Incoming staging

    private struct Incoming: Codable {
        var remote: RemoteMap?
        /// Downloaded attachment files: name -> SHA-256.
        var files: [String: String] = [:]
        /// Their records' system fields (change tags for later uploads).
        var systemFields: [String: Data] = [:]
    }

    private func incomingInfoURL(_ id: UUID) -> URL { cache.incomingFolder(for: id).appendingPathComponent("incoming.json") }
    private func incomingPayloadURL(_ id: UUID) -> URL { cache.incomingFolder(for: id).appendingPathComponent("payload") }
    private func incomingFileURL(_ id: UUID, _ name: String) -> URL {
        cache.incomingFolder(for: id).appendingPathComponent("files", isDirectory: true).appendingPathComponent(name)
    }

    private func loadIncoming(_ id: UUID) -> Incoming {
        (try? Data(contentsOf: incomingInfoURL(id))).flatMap { try? JSONDecoder().decode(Incoming.self, from: $0) }
            ?? Incoming()
    }

    private func saveIncoming(_ incoming: Incoming, _ id: UUID) throws {
        try FileManager.default.createDirectory(at: cache.incomingFolder(for: id), withIntermediateDirectories: true)
        try JSONEncoder().encode(incoming).write(to: incomingInfoURL(id), options: .atomic)
    }

    private func stageIncoming(_ remote: RemoteMap, payload: URL) throws {
        var incoming = loadIncoming(remote.mapID)
        try FileManager.default.createDirectory(at: cache.incomingFolder(for: remote.mapID), withIntermediateDirectories: true)
        try Self.replaceCopy(of: payload, at: incomingPayloadURL(remote.mapID))
        incoming.remote = remote
        try saveIncoming(incoming, remote.mapID)
    }

    private func stageIncoming(_ attachment: LibraryRecordCodec.RemoteAttachment) throws {
        var incoming = loadIncoming(attachment.mapID)
        let target = incomingFileURL(attachment.mapID, attachment.fileName)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.replaceCopy(of: attachment.file, at: target)
        incoming.files[attachment.fileName] = attachment.sha256
        incoming.systemFields[attachment.fileName] = attachment.systemFields
        try saveIncoming(incoming, attachment.mapID)
    }

    private static func replaceCopy(of source: URL, at target: URL) throws {
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
    }

    // MARK: Integration

    /// Brings the fetched version of map `id` into the cache.
    private func integrate(_ id: UUID) async {
        let incoming = loadIncoming(id)
        guard let fetched = incoming.remote, let remotePayload = try? Data(contentsOf: incomingPayloadURL(id)) else {
            return // only attachments so far: wait for the map record
        }
        let meta = state.maps[id] ?? MapSyncMeta()
        if Self.isSuperseded(fetched, by: meta) {
            finishIncoming(id, missing: [])
            return
        }
        let local = cache.packageURL(for: id).flatMap { try? LibraryPackageSnapshot.read(at: $0, mapID: id) }

        // Remote attachment files: downloaded now, or already here. An
        // Attachment record can be newer than its Map record's hash (same
        // note saved concurrently: last writer wins on that record); then
        // the server's file is used as it is (`remote.attachmentHashes` is
        // corrected below), otherwise it would stay "missing" forever.
        var remote = fetched
        var remoteFiles: [String: URL] = [:]
        var missing = Set<String>()
        for (name, sha) in remote.attachmentHashes {
            if incoming.files[name] == sha {
                remoteFiles[name] = incomingFileURL(id, name)
            } else if local?.attachmentHashes[name] == sha, let url = local?.attachmentFiles[name] {
                remoteFiles[name] = url
            } else if let actual = incoming.files[name] {
                remoteFiles[name] = incomingFileURL(id, name)
                remote.attachmentHashes[name] = actual
            } else {
                missing.insert(name)
            }
        }

        // Already known (e.g. our own upload coming back).
        if meta.syncedPayloadHash == remote.payloadHash, meta.revision >= remote.revision,
           meta.missingAttachments.isEmpty, missing.isEmpty,
           meta.syncedAttachments == remote.attachmentHashes {
            state.maps[id]?.systemFields = remote.systemFields
            finishIncoming(id, missing: missing)
            return
        }

        do {
            if let local, Self.isChanged(local, meta: meta),
               local.payloadHash != remote.payloadHash || local.attachmentHashes != remote.attachmentHashes {
                if !local.isEncrypted, !remote.isEncrypted, let base = cache.base(for: id), let localMap = local.map,
                   let remoteMap = try? MindMapPackage.decode(remotePayload) {
                    try await merge(id, base: base, local: local, localMap: localMap, remote: remote, remoteMap: remoteMap,
                              remotePayload: remotePayload, remoteFiles: remoteFiles, meta: meta)
                } else {
                    try await keepBothVersions(id, local: local, remote: remote, remotePayload: remotePayload,
                                         remoteFiles: remoteFiles)
                }
            } else {
                try await writeRemotePackage(remote, payload: remotePayload, files: remoteFiles, as: id)
            }
            adopt(remote, payload: remotePayload, missing: missing, attachmentSystemFields: incoming.systemFields, for: id)
            // Renamed elsewhere: the package (window title) follows.
            if let title = cache.plainTitle(of: id) { try? await renamePackage(of: id, toTitle: title) }
            finishIncoming(id, missing: missing)
        } catch {
            lastError = "“\(remote.title ?? LibraryTitle.lockedMap)” could not be updated: \(error.localizedDescription)"
        }
        onLibraryChanged?()
    }

    /// A staged version older than the one adopted since (left behind while
    /// its files were downloading, then this device uploaded a newer one):
    /// integrating it would roll the map back.
    static func isSuperseded(_ remote: RemoteMap, by meta: MapSyncMeta) -> Bool {
        guard remote.revision < meta.revision else { return false }
        // A record deleted and saved again starts its revisions anew.
        let created = { LibraryRecordCodec.record(fromSystemFields: $0)?.creationDate }
        return created(remote.systemFields) == created(meta.systemFields)
    }

    /// Package writes and renames run off the main thread: an open iPad
    /// editor (`UIDocument`) gives up the file on the main thread, so a
    /// coordinated write waiting there never finishes (the app hangs until
    /// the watchdog kills it, the fetched version stays unintegrated).
    private func writePackage(_ wrapper: FileWrapper, for id: UUID, title: String) async throws {
        let files = cache
        _ = try await Task.detached { try files.writePackage(wrapper, for: id, title: title) }.value
    }

    private func renamePackage(of id: UUID, toTitle title: String) async throws {
        let files = cache
        _ = try await Task.detached { try files.renamePackage(of: id, toTitle: title) }.value
    }

    /// The server state becomes this device's base.
    private func adopt(_ remote: RemoteMap, payload: Data, missing: Set<String>, attachmentSystemFields: [String: Data],
                       for id: UUID) {
        var meta = state.maps[id] ?? MapSyncMeta()
        meta.attachmentSystemFields.merge(attachmentSystemFields) { _, new in new }
        meta.systemFields = remote.systemFields
        meta.revision = remote.revision
        meta.syncedPayloadHash = remote.payloadHash
        meta.syncedAttachments = remote.attachmentHashes.filter { !missing.contains($0.key) }
        meta.missingAttachments = missing
        meta.isEncrypted = remote.isEncrypted
        meta.title = remote.title
        meta.modified = remote.modified
        state.maps[id] = meta
        cache.setBase(remote.isEncrypted ? nil : payload, for: id)
    }

    private func finishIncoming(_ id: UUID, missing: Set<String>) {
        if missing.isEmpty { try? FileManager.default.removeItem(at: cache.incomingFolder(for: id)) }
        persist()
        checkForLocalChanges(id)
    }

    private func writeRemotePackage(_ remote: RemoteMap, payload: Data, files: [String: URL], as id: UUID,
                                    title: String? = nil) async throws {
        let wrapper = try Self.package(payload: payload, lockHeader: remote.isEncrypted ? remote.lockHeader : nil,
                                       files: files)
        try await writePackage(wrapper, for: id, title: title ?? remote.title ?? LibraryTitle.lockedMap)
    }

    /// Package folder wrapper: plain (`map.json`) or locked (`lock.json` +
    /// `map.json.enc`), plus `attachments/`.
    static func package(payload: Data, lockHeader: Data?, files: [String: URL]) throws -> FileWrapper {
        var children: [String: FileWrapper] = [:]
        if let lockHeader {
            children[LockHeader.fileName] = FileWrapper(regularFileWithContents: lockHeader)
            children[LockedPackage.sealedMapName] = FileWrapper(regularFileWithContents: payload)
        } else {
            children[MindMapPackage.mapFileName] = FileWrapper(regularFileWithContents: payload)
        }
        var attachments: [String: FileWrapper] = [:]
        for (name, url) in files where Attachment.isValidFileName(name) {
            attachments[name] = FileWrapper(regularFileWithContents: try Data(contentsOf: url))
        }
        children[MindMapPackage.attachmentsFolderName] = FileWrapper(directoryWithFileWrappers: attachments)
        for (name, child) in children { child.preferredFilename = name }
        for (name, child) in attachments { child.preferredFilename = name }
        return FileWrapper(directoryWithFileWrappers: children)
    }

    /// Both sides changed a plain map: per-topic three-way merge.
    private func merge(_ id: UUID, base: MindMap, local: LibraryPackageSnapshot, localMap: MindMap, remote: RemoteMap,
                       remoteMap: MindMap, remotePayload: Data, remoteFiles: [String: URL], meta: MapSyncMeta) async throws {
        let result = MapMerge.merge(base: base, local: .init(map: localMap, modified: local.modified),
                                    remote: .init(map: remoteMap, modified: remote.modified))
        let localIsNewer = local.modified >= remote.modified
        var files: [String: URL] = [:]
        for name in result.map.referencedAttachmentFileNames {
            let l = local.attachmentHashes[name], r = remote.attachmentHashes[name], synced = meta.syncedAttachments[name]
            let useRemote: Bool
            switch (l, r) {
            case (nil, nil): continue
            case (_?, nil): useRemote = false
            case (nil, _?): useRemote = true
            case let (l?, r?): useRemote = l == r ? false : (l == synced ? true : (r == synced ? false : !localIsNewer))
            }
            // (A remote file still downloading: keep ours meanwhile.)
            if let url = (useRemote ? remoteFiles[name] : nil) ?? local.attachmentFiles[name] ?? remoteFiles[name] {
                files[name] = url
            }
        }
        let wrapper = try Self.package(payload: try MindMapPackage.encode(result.map), lockHeader: nil, files: files)
        try await writePackage(wrapper, for: id, title: LibraryTitle.title(of: result.map))
        lastConflicts[id] = result.conflicts
    }

    /// A locked map (or one without a merge base) changed on both sides:
    /// the newer version keeps the map's identity, the other one becomes a
    /// new library map "… (conflict copy)".
    private func keepBothVersions(_ id: UUID, local: LibraryPackageSnapshot, remote: RemoteMap, remotePayload: Data,
                                  remoteFiles: [String: URL]) async throws {
        let copyID = UUID()
        if local.modified >= remote.modified {
            let payload = remote.isEncrypted ? remotePayload : Self.markedAsConflictCopy(remotePayload)
            try await writeRemotePackage(remote, payload: payload, files: remoteFiles, as: copyID,
                                         title: Self.conflictCopyTitle(remote.title))
        } else {
            let payload = local.isEncrypted ? local.payload : Self.markedAsConflictCopy(local.payload)
            let wrapper = try Self.package(payload: payload, lockHeader: local.lockHeader, files: local.attachmentFiles)
            try await writePackage(wrapper, for: copyID, title: Self.conflictCopyTitle(local.title))
            try await writeRemotePackage(remote, payload: remotePayload, files: remoteFiles, as: id)
        }
        lastConflicts[copyID] = []
        checkForLocalChanges(copyID)
    }

    static let conflictCopySuffix = " (conflict copy)"

    static func conflictCopyTitle(_ title: String?) -> String {
        (title ?? LibraryTitle.lockedMap) + conflictCopySuffix
    }

    private static func markedAsConflictCopy(_ payload: Data) -> Data {
        guard var map = try? MindMapPackage.decode(payload) else { return payload }
        map.root.text += conflictCopySuffix
        return (try? MindMapPackage.encode(map)) ?? payload
    }

    // MARK: - Housekeeping

    private func cleanUpStaged(_ recordID: CKRecord.ID) {
        for url in stagedFiles.removeValue(forKey: recordID) ?? [] { cache.removeStaged(url) }
    }

    private func persist() {
        cache.saveState(state)
        onStateChanged?()
    }
}

extension MapSyncMeta {
    /// The server copy is gone (deleted elsewhere, zone reset, other
    /// account): the next upload creates fresh records.
    mutating func forgetServerCopy() {
        systemFields = nil
        revision = 0
        syncedPayloadHash = nil
        syncedAttachments = [:]
        attachmentSystemFields = [:]
        missingAttachments = []
    }
}
