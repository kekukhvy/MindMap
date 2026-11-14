import UniformTypeIdentifiers
#if os(macOS)
import AppKit

/// Images on a pasteboard (paste, drag): image files (Finder copy, the
/// screenshot thumbnail) or raw PNG / TIFF data (⌃⌘⇧4 screenshot).
enum NoteImagePasteboard {
    private static let rawTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    private static func imageFiles(_ pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }

    /// Cheap check (no file is read): there is an image to take.
    static func containsImage(_ pasteboard: NSPasteboard) -> Bool {
        if !imageFiles(pasteboard).isEmpty { return true }
        // Copied text with a preview image (web pages) stays a text paste.
        return pasteboard.string(forType: .string) == nil && rawTypes.contains { pasteboard.data(forType: $0) != nil }
    }

    static func imageData(_ pasteboard: NSPasteboard) -> Data? {
        if let url = imageFiles(pasteboard).first { return try? Data(contentsOf: url) }
        guard pasteboard.string(forType: .string) == nil else { return nil }
        return rawTypes.lazy.compactMap { pasteboard.data(forType: $0) }.first
    }
}
#else
import UIKit

enum NoteImagePasteboard {
    /// Copied text with an image (web pages) stays a text paste.
    static var containsImage: Bool { UIPasteboard.general.hasImages && !UIPasteboard.general.hasStrings }

    static var imageData: Data? {
        guard containsImage else { return nil }
        let pasteboard = UIPasteboard.general
        for type in [UTType.png, .jpeg, .heic] {
            if let data = pasteboard.data(forPasteboardType: type.identifier) { return data }
        }
        return pasteboard.image?.pngData()
    }

    /// The provider's image bytes, loaded under its first registered image type
    /// (the abstract `public.image` fails for providers that register only PNG, JPEG, ...).
    static func loadImageData(from provider: NSItemProvider, completion: @escaping (Data?) -> Void) {
        guard let type = provider.registeredContentTypes(conformingTo: .image).first else { return completion(nil) }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in completion(data) }
    }
}
#endif
