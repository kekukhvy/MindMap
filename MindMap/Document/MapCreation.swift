import Foundation
#if os(macOS)
import AppKit
#endif

/// Where New Map (⌘N) creates a map: the storage setting (WP14b).
enum NewMapTarget: Equatable {
    /// A new library map, already in the cache: open this package.
    case library(URL)
    /// A new `.mindmap` document the platform's usual way (macOS untitled
    /// document; iPad "Untitled.mindmap" in the documents folder).
    case file
}

@MainActor
enum MapCreation {
    /// Creates the library map in library mode; `.file` in files mode.
    static func prepareNewMap(service: LibraryService? = nil) throws -> NewMapTarget {
        let service = service ?? .shared
        switch service.settings.storageMode {
        case .library:
            let summary = try service.store.createUntitledMap()
            guard let url = service.store.packageURL(for: summary.location) else { throw CocoaError(.fileNoSuchFile) }
            return .library(url)
        case .files:
            return .file
        }
    }
}

#if os(macOS)
/// macOS map windows: New Map per storage mode, opening / closing / saving
/// the document of a package.
@MainActor
enum MapHost {
    /// File ▸ New Map (⌘N).
    static func newMap(service: LibraryService? = nil) {
        do {
            switch try MapCreation.prepareNewMap(service: service) {
            case let .library(url): open(url)
            case .file: NSDocumentController.shared.newDocument(nil)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Opens (or brings to the front) the document of `url`; as a tab of
    /// `window` when given.
    static func open(_ url: URL, from window: NSWindow? = nil, completion: @escaping (String?) -> Void = { _ in }) {
        if let window {
            MapTabOpener.open(url, revealing: nil, from: window) { outcome in
                if case let .failed(message) = outcome { completion(message) } else { completion(nil) }
            }
            return
        }
        if let existing = MapTabOpener.document(for: url) {
            existing.showWindows()
            completion(nil)
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
            completion(document == nil ? (error?.localizedDescription ?? "The map could not be opened.") : nil)
        }
    }

    /// Closes the open document of `url` (if any) without asking.
    static func close(_ url: URL) {
        MapTabOpener.document(for: url)?.close()
    }
}
#endif
