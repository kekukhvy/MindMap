import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images pasted or dropped into a Markdown note (pure rules).
///
/// An image is a file `<note attachment id>-img-<UUID>.<ext>` in the
/// package's `attachments/` folder, linked from the note as
/// `![](attachments/<file>)`. The name ties it to its note: a save keeps
/// every such file of a note that exists (no list in `map.json`), and the
/// files go away with the note.
enum NoteImage {
    /// Between the note's id and the image's own UUID in the file name.
    static let nameMarker = "-img-"
    /// Link prefix inside the note text (relative to the package folder).
    static let linkFolder = MindMapPackage.attachmentsFolderName + "/"
    static let pngExtension = "png"
    private static let jpegExtension = "jpg"
    private static let heicExtension = "heic"

    static func fileName(noteID: UUID, id: UUID = UUID(), fileExtension: String) -> String {
        "\(noteID.uuidString)\(nameMarker)\(id.uuidString).\(fileExtension)"
    }

    static func ownerPrefix(of noteID: UUID) -> String { noteID.uuidString + nameMarker }

    /// Image files of a locked note are stored sealed, under their name plus this suffix.
    static func isSealed(_ fileName: String) -> Bool { fileName.hasSuffix(LockedPackage.sealedSuffix) }

    static func link(for fileName: String) -> String { "![](\(linkFolder)\(fileName))" }

    /// The file name a link target points at, nil if it is not under `attachments/`.
    static func fileName(fromLinkTarget target: String) -> String? {
        guard target.hasPrefix(linkFolder) else { return nil }
        let name = String(target.dropFirst(linkFolder.count))
        return Attachment.isValidFileName(name) ? name : nil
    }

    /// Bytes and extension to store: PNG, JPEG and HEIC as they are, any
    /// other readable image (TIFF, ...) converted to PNG. nil if not an image.
    static func storable(_ data: Data) -> (data: Data, fileExtension: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source) else { return nil }
        switch type as String {
        case UTType.png.identifier: return (data, pngExtension)
        case UTType.jpeg.identifier: return (data, jpegExtension)
        case UTType.heic.identifier: return (data, heicExtension)
        default:
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? (output as Data, pngExtension) : nil
        }
    }

    /// `text` with `link` on its own line at `selection` (which it replaces);
    /// the new selection is a caret after the inserted line.
    static func inserting(_ link: String, into text: String, selection: NSRange) -> (text: String, caret: Int) {
        let source = text as NSString
        let location = min(selection.location, source.length)
        let range = NSRange(location: location, length: min(selection.length, source.length - location))
        let before = source.substring(to: range.location)
        let after = source.substring(from: NSMaxRange(range))
        let lead = before.isEmpty || before.hasSuffix("\n") ? "" : "\n"
        let trail = after.isEmpty || after.hasPrefix("\n") ? "" : "\n"
        let head = before + lead + link + trail
        return (head + after, head.utf16.count)
    }
}
