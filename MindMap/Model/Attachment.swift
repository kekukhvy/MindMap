import Foundation

/// What an attachment holds; decides its icon, file extension and viewer.
enum AttachmentKind: String, Codable, CaseIterable {
    /// Plain UTF-8 Markdown note (`<UUID>.md`, readable in Obsidian & co).
    case markdown
    /// Handwriting: PencilKit `PKDrawing` data (`<UUID>.drawing`, WP5).
    case drawing
    /// Any imported file, original extension kept (`<UUID>.pdf`, WP6).
    case file

    /// Unknown kinds (from newer versions) are treated as plain files.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AttachmentKind(rawValue: raw) ?? .file
    }
}

/// A document attached to a topic. The content lives in the package's
/// `attachments/` folder under `fileName`; the topic only shows a small
/// icon (never the content). Value type: undo stores whole attachments.
struct Attachment: Identifiable, Equatable, Codable {
    var id: UUID
    var kind: AttachmentKind
    var title: String
    /// Name inside `attachments/` (no folders): "<UUID>.md", "<UUID>.drawing",
    /// or "<UUID>.<original extension>" for files.
    var fileName: String
    var createdAt: Date
    var modifiedAt: Date

    init(id: UUID = UUID(), kind: AttachmentKind = .file, title: String = "", fileName: String? = nil,
         originalExtension: String? = nil, createdAt: Date = Date(), modifiedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.fileName = fileName ?? Attachment.defaultFileName(id: id, kind: kind, originalExtension: originalExtension)
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }

    static func defaultFileName(id: UUID, kind: AttachmentKind, originalExtension: String? = nil) -> String {
        let ext: String?
        switch kind {
        case .markdown: ext = "md"
        case .drawing: ext = "drawing"
        case .file: ext = originalExtension.flatMap { $0.isEmpty ? nil : $0 }
        }
        return ext.map { "\(id.uuidString).\($0)" } ?? id.uuidString
    }

    /// A safe single path component inside `attachments/`.
    static func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains(":") && name != "." && name != ".."
            && !name.hasPrefix(".")
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, fileName, createdAt, modifiedAt
    }

    /// Tolerant decoding: Stage 1 files stored only `{"id": ...}`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = (try? c.decodeIfPresent(AttachmentKind.self, forKey: .kind)) ?? .file
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? id.uuidString
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSinceReferenceDate: 0)
        modifiedAt = (try? c.decodeIfPresent(Date.self, forKey: .modifiedAt)) ?? createdAt
    }
}

/// Text helpers for Markdown notes.
enum MarkdownNote {
    /// Content of a brand-new note: "# <topic text>" then free text.
    static func initialContent(topicText: String) -> String {
        let heading = topicText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? "" : "# \(heading)\n\n"
    }

    static func data(_ text: String) -> Data { Data(text.utf8) }

    static func text(_ data: Data?) -> String {
        guard let data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
