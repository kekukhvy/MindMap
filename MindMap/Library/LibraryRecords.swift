import CloudKit
import CryptoKit
import Foundation

/// CloudKit schema of the map library (WP14, private database, custom zone
/// "Maps"):
///
///     Map         recordName = map UUID
///       title            String   central topic text; nil for a locked map
///       modified         Date     package modification date (merge "newer")
///       encrypted        Int64    1 = locked map (WP12): only ciphertext
///       revision         Int64    +1 per upload (informational / mocks)
///       payload          Asset    map.json, or map.json.enc when encrypted
///       payloadHash      String   SHA-256 of payload (+ lock header)
///       lockHeader       Bytes    lock.json (encrypted only; no content)
///       attachmentHashes String   JSON {file name in attachments/: SHA-256}
///       schema           Int64    1
///     Attachment  recordName = "<map UUID>/<file name>"
///       map              Reference -> Map (deleteSelf)
///       fileName         String   name inside attachments/ ("<UUID>.md",
///                                 "<UUID>.md.enc" in a locked map)
///       file             Asset
///       sha256           String
///
/// A locked map's records hold exactly what its package holds on disk:
/// `lock.json` (key ID only), `map.json.enc`, `attachments/*.enc`.
enum LibraryZone {
    static let name = "Maps"
    static let id = CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName)
    static var zone: CKRecordZone { CKRecordZone(zoneID: id) }
}

enum LibraryRecordType {
    static let map = "Map"
    static let attachment = "Attachment"
}

enum MapRecordField {
    static let title = "title"
    static let modified = "modified"
    static let encrypted = "encrypted"
    static let revision = "revision"
    static let payload = "payload"
    static let payloadHash = "payloadHash"
    static let lockHeader = "lockHeader"
    static let attachmentHashes = "attachmentHashes"
    static let schema = "schema"
}

enum AttachmentRecordField {
    static let map = "map"
    static let fileName = "fileName"
    static let file = "file"
    static let sha256 = "sha256"
}

/// Record IDs of library maps and their attachments.
enum LibraryRecordID {
    static func map(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: LibraryZone.id)
    }

    static func attachment(map id: UUID, fileName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString + "/" + fileName, zoneID: LibraryZone.id)
    }

    enum Parsed: Equatable {
        case map(UUID)
        case attachment(map: UUID, fileName: String)
    }

    static func parse(_ recordID: CKRecord.ID) -> Parsed? {
        let name = recordID.recordName
        guard let slash = name.firstIndex(of: "/") else { return UUID(uuidString: name).map(Parsed.map) }
        guard let id = UUID(uuidString: String(name[..<slash])) else { return nil }
        let fileName = String(name[name.index(after: slash)...])
        return Attachment.isValidFileName(fileName) ? .attachment(map: id, fileName: fileName) : nil
    }
}

enum LibraryHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streamed (attachments can be large).
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// What a library map package holds, as synced (read from its folder).
struct LibraryPackageSnapshot {
    var mapID: UUID
    var isEncrypted: Bool
    /// `map.json`, or `map.json.enc` of a locked map.
    var payload: Data
    /// `lock.json` of a locked map.
    var lockHeader: Data?
    /// Central topic text (nil when locked: no plaintext leaves the device).
    var title: String?
    var modified: Date
    var payloadHash: String
    /// Files in `attachments/` by name (as stored: ".enc" when locked).
    var attachmentFiles: [String: URL]
    var attachmentHashes: [String: String]

    /// Plain map (nil when locked or unreadable).
    var map: MindMap? { isEncrypted ? nil : try? MindMapPackage.decode(payload) }

    static func payloadHash(payload: Data, lockHeader: Data?) -> String {
        LibraryHash.sha256((lockHeader ?? Data()) + payload)
    }

    /// Reads the package folder at `url`; nil if it is not a map package.
    static func read(at url: URL, mapID: UUID) throws -> LibraryPackageSnapshot? {
        let fm = FileManager.default
        let lockURL = url.appendingPathComponent(LockHeader.fileName)
        let plainURL = url.appendingPathComponent(MindMapPackage.mapFileName)
        let sealedURL = url.appendingPathComponent(LockedPackage.sealedMapName)
        let isEncrypted = fm.fileExists(atPath: lockURL.path)
        let payloadURL = isEncrypted ? sealedURL : plainURL
        guard fm.fileExists(atPath: payloadURL.path) else { return nil }
        let payload = try Data(contentsOf: payloadURL)
        let lockHeader = isEncrypted ? try Data(contentsOf: lockURL) : nil
        let modified = (try? payloadURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        var files: [String: URL] = [:]
        var hashes: [String: String] = [:]
        let folder = url.appendingPathComponent(MindMapPackage.attachmentsFolderName)
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where Attachment.isValidFileName(name) {
            let file = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            // (A plain map can hold locked notes: "<UUID>.md.enc".)
            files[name] = file
            hashes[name] = try LibraryHash.sha256(of: file)
        }
        var title: String?
        if !isEncrypted {
            title = LibraryTitle.title(of: try MindMapPackage.decode(payload))
        }
        return LibraryPackageSnapshot(mapID: mapID, isEncrypted: isEncrypted, payload: payload, lockHeader: lockHeader,
                                      title: title, modified: modified,
                                      payloadHash: payloadHash(payload: payload, lockHeader: lockHeader),
                                      attachmentFiles: files, attachmentHashes: hashes)
    }
}

enum LibraryTitle {
    static let lockedMap = "Locked Map"

    /// First line of the central topic, trimmed, ≤ 100 characters.
    static func title(of map: MindMap) -> String {
        let line = map.root.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = String(line.trimmingCharacters(in: .whitespaces).prefix(100))
        return trimmed.isEmpty ? UntitledName.base : trimmed
    }
}

/// A Map record as fetched (payload copied out of the asset).
struct RemoteMap: Codable, Equatable {
    var mapID: UUID
    var title: String?
    var modified: Date
    var isEncrypted: Bool
    var revision: Int
    var payloadHash: String
    var lockHeader: Data?
    var attachmentHashes: [String: String]
    /// Archived system fields of the record (change tag) for the next save.
    var systemFields: Data
}

/// Package <-> CKRecord conversion.
enum LibraryRecordCodec {
    enum CodecError: Error {
        case missingField(String)
        case wrongRecordType
    }

    /// Map record for `snapshot` (based on the last known server record so
    /// CloudKit can detect conflicts). `payloadFile` = a staged copy of the
    /// payload that stays put until the upload finished.
    static func mapRecord(_ snapshot: LibraryPackageSnapshot, base: CKRecord?, revision: Int,
                          payloadFile: URL) -> CKRecord {
        let record = base ?? CKRecord(recordType: LibraryRecordType.map, recordID: LibraryRecordID.map(snapshot.mapID))
        record[MapRecordField.title] = snapshot.isEncrypted ? nil : snapshot.title as CKRecordValue?
        record[MapRecordField.modified] = snapshot.modified as CKRecordValue
        record[MapRecordField.encrypted] = (snapshot.isEncrypted ? 1 : 0) as CKRecordValue
        record[MapRecordField.revision] = revision as CKRecordValue
        record[MapRecordField.payload] = CKAsset(fileURL: payloadFile)
        record[MapRecordField.payloadHash] = snapshot.payloadHash as CKRecordValue
        record[MapRecordField.lockHeader] = snapshot.lockHeader as CKRecordValue?
        record[MapRecordField.attachmentHashes] = encodeHashes(snapshot.attachmentHashes) as CKRecordValue
        record[MapRecordField.schema] = 1 as CKRecordValue
        return record
    }

    static func attachmentRecord(map id: UUID, fileName: String, file: URL, sha256: String,
                                 base: CKRecord?) -> CKRecord {
        let record = base ?? CKRecord(recordType: LibraryRecordType.attachment,
                                      recordID: LibraryRecordID.attachment(map: id, fileName: fileName))
        record[AttachmentRecordField.map] = CKRecord.Reference(recordID: LibraryRecordID.map(id), action: .deleteSelf)
        record[AttachmentRecordField.fileName] = fileName as CKRecordValue
        record[AttachmentRecordField.file] = CKAsset(fileURL: file)
        record[AttachmentRecordField.sha256] = sha256 as CKRecordValue
        return record
    }

    /// Fetched Map record -> metadata + the payload's (temporary) file.
    static func remoteMap(from record: CKRecord) throws -> (RemoteMap, payloadFile: URL) {
        guard record.recordType == LibraryRecordType.map, case let .map(id)? = LibraryRecordID.parse(record.recordID) else {
            throw CodecError.wrongRecordType
        }
        guard let asset = record[MapRecordField.payload] as? CKAsset, let file = asset.fileURL else {
            throw CodecError.missingField(MapRecordField.payload)
        }
        let lockHeader = record[MapRecordField.lockHeader] as? Data
        let encrypted = (record[MapRecordField.encrypted] as? Int64 ?? 0) != 0
        let hashes = decodeHashes(record[MapRecordField.attachmentHashes] as? String)
        let payloadHash = record[MapRecordField.payloadHash] as? String
            ?? LibraryPackageSnapshot.payloadHash(payload: (try? Data(contentsOf: file)) ?? Data(), lockHeader: lockHeader)
        let remote = RemoteMap(mapID: id, title: record[MapRecordField.title] as? String,
                               modified: record[MapRecordField.modified] as? Date ?? record.modificationDate ?? Date(),
                               isEncrypted: encrypted || lockHeader != nil,
                               revision: Int(record[MapRecordField.revision] as? Int64 ?? 0),
                               payloadHash: payloadHash, lockHeader: lockHeader, attachmentHashes: hashes,
                               systemFields: archiveSystemFields(of: record))
        return (remote, file)
    }

    struct RemoteAttachment {
        var mapID: UUID
        var fileName: String
        var sha256: String
        var file: URL
        var systemFields: Data
    }

    static func remoteAttachment(from record: CKRecord) throws -> RemoteAttachment {
        guard record.recordType == LibraryRecordType.attachment,
              case let .attachment(id, name)? = LibraryRecordID.parse(record.recordID) else {
            throw CodecError.wrongRecordType
        }
        guard let asset = record[AttachmentRecordField.file] as? CKAsset, let file = asset.fileURL else {
            throw CodecError.missingField(AttachmentRecordField.file)
        }
        let sha = try record[AttachmentRecordField.sha256] as? String ?? LibraryHash.sha256(of: file)
        return RemoteAttachment(mapID: id, fileName: name, sha256: sha, file: file,
                                systemFields: archiveSystemFields(of: record))
    }

    // MARK: System fields

    static func archiveSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data?) -> CKRecord? {
        guard let data, let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    // MARK: Helpers

    static func encodeHashes(_ hashes: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(hashes)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func decodeHashes(_ string: String?) -> [String: String] {
        guard let string, let hashes = try? JSONDecoder().decode([String: String].self, from: Data(string.utf8)) else {
            return [:]
        }
        return hashes.filter { Attachment.isValidFileName($0.key) }
    }
}
