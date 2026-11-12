import Foundation

/// Opens a map file for a map link: `(url, topic to reveal, completion)`;
/// completion gets nil on success, else the reason it failed.
typealias MapOpener = (URL, UUID?, @escaping (String?) -> Void) -> Void

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

    /// Go to on a map link: opens the map (new tab on macOS, new window on
    /// iPad) and reveals its target topic; missing → "Locate…" alert.
    func openMapLink(of id: UUID) {
        guard let reference = link(of: id)?.mapReference else { return }
        select(id)
        switch mapResolver.resolve(reference, documentURL: documentURL) {
        case .missing:
            mapLinkProblem = MapLinkProblem(nodeID: id, message: Self.missingMessage(reference))
        case let .found(url, refreshed):
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
        guard let target = id ?? selectedID, link(of: target)?.mapReference != nil else { return }
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
    /// document and links it (one undo step "Add/Edit Link"; undo keeps the
    /// file). Throws when the document was never saved or its folder is not
    /// writable — the caller then asks for a place with a save panel.
    @discardableResult
    func createLinkedMap(for id: UUID) throws -> URL {
        guard let documentURL else { throw CocoaError(.fileNoSuchFile) }
        guard let node = model.map.node(withID: id) else { throw CocoaError(.fileReadUnknown) }
        let url = try MapFiles.createMap(named: node.text, nextTo: documentURL)
        linkMap(at: url, to: id)
        return url
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
