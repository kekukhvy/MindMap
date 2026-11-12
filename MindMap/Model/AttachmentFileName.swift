import Foundation

/// Naming rules for imported files (pure).
///
/// - The title keeps the original file name (spaces, Unicode, case) as the
///   user saw it, e.g. "Q3 Report.PDF".
/// - The stored name is "<UUID>.<ext>": `ext` is the original extension,
///   lowercased, only if it is a plain ASCII alphanumeric word of at most
///   16 characters (so the stored name is always a safe single component
///   that QuickLook can type by extension); otherwise "<UUID>" alone.
/// - Dot-files (".bashrc") and names ending in "." have no extension.
/// - Temp copies for sharing / exporting / previewing are named after the
///   title, with the stored extension appended if the title lost it.
enum AttachmentFileName {
    static let maxExtensionLength = 16
    static let fallbackTitle = "File"

    /// Title for an imported file: its last path component, trimmed.
    static func title(fromOriginalName name: String) -> String {
        let last = name.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? name
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\0", with: "")
        return trimmed.isEmpty ? fallbackTitle : trimmed
    }

    /// Extension to keep for the stored file (lowercased), nil if none / unsafe.
    static func storedExtension(fromOriginalName name: String) -> String? {
        let title = title(fromOriginalName: name)
        guard let dot = title.lastIndex(of: "."), dot != title.startIndex else { return nil }
        let ext = title[title.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= maxExtensionLength,
              ext.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }
        return ext.lowercased()
    }

    /// The topic text for a file dropped on empty canvas: title without extension.
    static func topicText(forTitle title: String) -> String {
        guard storedExtension(fromOriginalName: title) != nil, let dot = title.lastIndex(of: ".") else { return title }
        let base = String(title[..<dot]).trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? title : base
    }

    /// File name for a temp copy of `attachment` (share, export, preview):
    /// the title made filesystem-safe, plus the stored extension if missing.
    static func exportName(for attachment: Attachment) -> String {
        var name = title(fromOriginalName: attachment.title.replacingOccurrences(of: "/", with: "-"))
            .replacingOccurrences(of: ":", with: "-")
        if name == "." || name == ".." { name = fallbackTitle }
        let storedExt = (attachment.fileName as NSString).pathExtension.lowercased()
        if !storedExt.isEmpty, storedExtension(fromOriginalName: name) != storedExt {
            name += "." + storedExt
        }
        // Keep well under the 255-byte component limit.
        while name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            guard !base.isEmpty else { break }
            name = String(base.dropLast(10)) + (ext.isEmpty ? "" : "." + ext)
        }
        return name
    }
}

extension Attachment {
    /// New file attachment for a file originally called `originalName`.
    static func file(originalName: String, id: UUID = UUID(), now: Date = Date()) -> Attachment {
        Attachment(id: id, kind: .file, title: AttachmentFileName.title(fromOriginalName: originalName),
                   originalExtension: AttachmentFileName.storedExtension(fromOriginalName: originalName),
                   createdAt: now)
    }
}
