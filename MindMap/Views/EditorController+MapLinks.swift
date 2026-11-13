import Foundation
#if os(macOS)
import AppKit
#endif

/// Opens a map file for a map link: `(url, topic to reveal, completion)`;
/// completion gets nil on success, else the reason it failed.
typealias MapOpener = (URL, UUID?, @escaping (String?) -> Void) -> Void

/// One map link of the map (`EditorController.mapLinkSignature`).
struct MapLinkKey: Equatable {
    var id: UUID
    var reference: MapReference
}

/// A map link that could not be followed (file missing or not openable).
struct MapLinkProblem: Identifiable, Equatable {
    let id = UUID()
    var nodeID: UUID
    var message: String
}

/// Map links (WP10): follow (new tab / window), locate a moved file, link a
/// picked or newly created map (one undo step each).
extension EditorController {
    /// The map file a map link resolves to now (nil = missing).
    func resolvedMapURL(of id: UUID) -> URL? {
        guard let reference = link(of: id)?.mapReference,
              case let .found(url, _) = mapResolver.resolve(reference, documentURL: documentURL) else { return nil }
        return url
    }

    /// Re-checks every map link's file (document opened / moved, links
    /// changed, app back in front): missing ones get a dimmed icon.
    func refreshMissingMapLinks() {
        var missing = Set<UUID>()
        for (id, reference) in model.map.mapLinks {
            if case .missing = mapResolver.resolve(reference, documentURL: documentURL) { missing.insert(id) }
        }
        if missing != missingMapLinks { missingMapLinks = missing }
    }

    /// Map links as a comparable value (re-check when it changes).
    var mapLinkSignature: [MapLinkKey] {
        model.map.mapLinks.map { MapLinkKey(id: $0.id, reference: $0.reference) }
    }

    /// Go to on a map link: opens the map (new tab on macOS, new window on
    /// iPad) and reveals its target topic; missing → "Locate…" alert.
    func openMapLink(of id: UUID) {
        guard let reference = link(of: id)?.mapReference else { return }
        select(id)
        switch mapResolver.resolve(reference, documentURL: documentURL) {
        case .missing:
            missingMapLinks.insert(id)
            mapLinkProblem = MapLinkProblem(nodeID: id, message: Self.missingMessage(reference))
        case let .found(url, refreshed):
            if missingMapLinks.contains(id) { missingMapLinks.remove(id) }
            if let refreshed { model.refreshMapLinks([id: refreshed]) }
            if let documentURL, LaunchEnvironment.key(url) == LaunchEnvironment.key(documentURL) {
                if let target = reference.targetTopicID, model.map.contains(target) {
                    navigationHistory.push(id)
                    show(target)
                }
                return
            }
            guard let mapOpener else {
                mapLinkProblem = MapLinkProblem(nodeID: id, message: "Maps cannot be opened here.")
                return
            }
            mapOpener(url, reference.targetTopicID) { [weak self] failure in
                guard let failure else { return }
                self?.mapLinkProblem = MapLinkProblem(
                    nodeID: id, message: "“\(reference.displayName)” could not be opened. \(failure)")
            }
        }
    }

    static func missingMessage(_ reference: MapReference) -> String {
        "“\(reference.displayName)” could not be found at \(reference.pathDescription). "
            + "It may have been moved, renamed or deleted — use Locate… to choose it again."
    }

    /// "Locate…": shows the file picker; the chosen map replaces the link's file.
    func beginLocateMap(_ id: UUID? = nil) {
        guard let target = id ?? selectedID, link(of: target)?.mapReference != nil, requireEditable() else { return }
        commitEditing()
        mapLinkProblem = nil
        mapLocateNodeID = target
        isMapLocatorPresented = true
    }

    /// File picker result of "Locate…" (one undo step "Edit Link").
    func finishLocateMap(_ result: Result<URL, Error>) {
        guard let id = mapLocateNodeID else { return }
        mapLocateNodeID = nil
        guard case let .success(url) = result else { return }
        linkMap(at: url, to: id, targetTopicID: link(of: id)?.mapReference?.targetTopicID)
    }

    /// Links topic `id` to the map at `url` (optionally at one of its topics).
    @discardableResult
    func linkMap(at url: URL, to id: UUID, targetTopicID: UUID? = nil) -> Bool {
        setLink(.map(mapReference(to: url, targetTopicID: targetTopicID)), for: id)
    }

    func mapReference(to url: URL, targetTopicID: UUID? = nil) -> MapReference {
        mapResolver.reference(to: url, from: documentURL, targetTopicID: targetTopicID)
    }

    /// "New Map…": creates an empty map named after the topic next to this
    /// document and links it (one undo step "Add/Edit Link", see
    /// `linkCreatedMap`). Throws when the document was never saved or its
    /// folder is not writable — the caller then asks for a place with a save
    /// panel.
    @discardableResult
    func createLinkedMap(for id: UUID) throws -> URL {
        guard let documentURL else { throw CocoaError(.fileNoSuchFile) }
        guard let node = model.map.node(withID: id) else { throw CocoaError(.fileReadUnknown) }
        let url = try MapFiles.createMap(named: node.text, nextTo: documentURL)
        linkCreatedMap(at: url, to: id)
        return url
    }

    /// Links a map file "New Map…" just created. Undoing the link also puts
    /// the new file away if nobody touched it since (not open, unchanged):
    /// it moves to a holding folder and redo brings it back. An edited or
    /// open map is never removed.
    @discardableResult
    func linkCreatedMap(at url: URL, to id: UUID) -> Bool {
        guard let undoManager else { return linkMap(at: url, to: id) }
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        let stamp = CreatedMapFiles.stamp(of: url)
        registerCreatedMapCleanup(url, stamp: stamp, undoManager: undoManager)
        return linkMap(at: url, to: id)
    }

    private func registerCreatedMapCleanup(_ url: URL, stamp: Date?, undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { editor in
            let held = CreatedMapFiles.putAwayIfUntouched(url, stamp: stamp)
            undoManager.registerUndo(withTarget: editor) { editor in
                if let held { CreatedMapFiles.restore(held, to: url) }
                editor.registerCreatedMapCleanup(url, stamp: CreatedMapFiles.stamp(of: url), undoManager: undoManager)
            }
        }
    }

    /// Document saved for the first time / moved: map links get paths
    /// relative to its new folder (found through their bookmarks).
    func refreshMapLinkPaths() {
        guard let documentURL else { return }
        let updates = mapResolver.relativePathUpdates(for: model.map.mapLinks, documentURL: documentURL)
        if !updates.isEmpty { model.refreshMapLinks(updates) }
    }

    /// The map was opened from a link "at topic": reveal it now, or once
    /// the canvas knows its size.
    func revealRequestedTopic(_ topicID: UUID) {
        guard model.map.contains(topicID) else { return }
        if viewSize == .zero {
            pendingRevealID = topicID
        } else {
            show(topicID)
        }
    }
}

/// Files made by "New Map…" that an undo puts away (and redo restores).
enum CreatedMapFiles {
    /// Modification date of the package's map.json (nil = missing).
    static func stamp(of url: URL) -> Date? {
        let json = url.appendingPathComponent(MindMapPackage.mapFileName)
        return (try? FileManager.default.attributesOfItem(atPath: json.path))?[.modificationDate] as? Date
    }

    /// Moves `url` into a holding folder if it still has `stamp` and no
    /// window has it open; returns where it went (nil = left in place).
    static func putAwayIfUntouched(_ url: URL, stamp: Date?, isOpen: (URL) -> Bool = CreatedMapFiles.isOpen) -> URL? {
        guard let stamp, CreatedMapFiles.stamp(of: url) == stamp, !isOpen(url) else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MindMap Undone Maps", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let held = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: held)
            return held
        } catch {
            return nil
        }
    }

    /// Redo: the held file goes back (unless something new is there now).
    static func restore(_ held: URL, to url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.moveItem(at: held, to: url)
    }

    /// Whether a window of this app shows the map at `url`.
    static func isOpen(_ url: URL) -> Bool {
        #if os(macOS)
        let key = LaunchEnvironment.key(url)
        return NSDocumentController.shared.documents.contains { $0.fileURL.map(LaunchEnvironment.key) == key }
        #else
        return MainActor.assumeIsolated { DocumentSession.session(showing: url) != nil }
        #endif
    }
}
