import SwiftUI
import UniformTypeIdentifiers

/// What the Map pane of the link editor has chosen.
struct MapLinkChoice: Equatable {
    /// The chosen map file (nil = none yet / existing link's file missing).
    var url: URL?
    /// Name shown when the existing link's file is missing.
    var missingName: String?
    var targetTopicID: UUID?
}

/// Link editor "Map" pane: choose a `.mindmap` (file importer) or create a
/// new map next to this one ("New Map…", named after the topic), and
/// optionally a topic of that map to open at (read from its map.json).
struct MapLinkPane: View {
    let editor: EditorController
    let nodeID: UUID
    @Binding var choice: MapLinkChoice
    /// The new map was created and linked: the sheet closes.
    let onLinkedNewMap: () -> Void

    @State private var isChoosing = false
    @State private var isExportingNewMap = false
    @State private var topics: [LinkCandidate] = []
    @State private var topicsError: String?
    @State private var query = ""
    @State private var newMapError: String?

    private var topicText: String { editor.model.map.node(withID: nodeID)?.text ?? "" }

    private var isCurrentDocument: Bool {
        guard let url = choice.url, let documentURL = editor.documentURL else { return false }
        return LaunchEnvironment.key(url) == LaunchEnvironment.key(documentURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            fileRow
            newMapRow
            Divider()
            topicSection
        }
        .task(id: choice.url) { loadTopics() }
    }

    // MARK: File

    private var fileRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "map")
                .font(.title2)
                .foregroundStyle(choice.url == nil ? Color.secondary : Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                if let url = choice.url {
                    Text(MapPaths.displayName(of: url)).font(.body.weight(.semibold)).lineLimit(1)
                    Text(locationText(url)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if isCurrentDocument {
                        Text("This is the current map — use the Topic tab to link to its topics.")
                            .font(.caption).foregroundStyle(.red)
                    }
                } else if let missing = choice.missingName {
                    Text(missing).font(.body.weight(.semibold)).lineLimit(1)
                    Text("File not found — choose it again (Locate…)").font(.caption).foregroundStyle(.red)
                } else {
                    Text("No map chosen").foregroundStyle(.secondary)
                    Text("Choose a .mindmap file or create a new one.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(choice.missingName != nil && choice.url == nil ? "Locate…" : "Choose…") { isChoosing = true }
                .help("Choose a .mindmap file")
        }
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.mindMap]) { result in
            guard case let .success(url) = result else { return }
            choice = MapLinkChoice(url: url, missingName: nil, targetTopicID: nil)
        }
    }

    private func locationText(_ url: URL) -> String {
        if let documentURL = editor.documentURL, let path = MapPaths.relativePath(from: documentURL, to: url) {
            return path
        }
        return url.path
    }

    private var newMapRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("New Map…", systemImage: "doc.badge.plus", action: createNewMap)
                .help("Creates “\(MapPaths.fileNameBase(forTopic: topicText)).\(MapPaths.fileExtension)” "
                      + "next to this map and links it")
            if let newMapError {
                Text(newMapError).font(.caption).foregroundStyle(.red)
            }
        }
        .fileExporter(isPresented: $isExportingNewMap, document: NewMapFile(topicText: topicText),
                      contentType: .mindMap, defaultFilename: MapPaths.fileNameBase(forTopic: topicText)) { result in
            switch result {
            case let .success(url):
                editor.linkMap(at: url, to: nodeID)
                onLinkedNewMap()
            case let .failure(error):
                newMapError = "The map could not be created (\(error.localizedDescription))."
            }
        }
    }

    /// Next to the document directly; a save panel when the document was
    /// never saved or its folder is not writable (sandbox).
    private func createNewMap() {
        newMapError = nil
        do {
            try editor.createLinkedMap(for: nodeID)
            onLinkedNewMap()
        } catch {
            isExportingNewMap = true
        }
    }

    // MARK: Topic

    private var filteredTopics: [LinkCandidate] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return topics }
        return topics.filter { $0.text.localizedStandardContains(needle) || $0.breadcrumb.localizedStandardContains(needle) }
    }

    @ViewBuilder private var topicSection: some View {
        HStack {
            Text("Open at topic").font(.subheadline.weight(.semibold))
            Spacer()
            if !topics.isEmpty {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
        }
        List {
            row(text: "Whole map", detail: "Opens at the central topic", isSelected: choice.targetTopicID == nil) {
                choice.targetTopicID = nil
            }
            ForEach(filteredTopics) { candidate in
                row(text: candidate.text, detail: candidate.breadcrumb, isSelected: choice.targetTopicID == candidate.id) {
                    choice.targetTopicID = candidate.id
                }
            }
        }
        .listStyle(.plain)
        .overlay(alignment: .bottom) {
            if let topicsError {
                Text(topicsError).font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .disabled(choice.url == nil)
    }

    private func row(text: String, detail: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer()
                if isSelected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : nil)
    }

    private func loadTopics() {
        topicsError = nil
        guard let url = choice.url else {
            topics = []
            return
        }
        do {
            topics = try MapFiles.topics(at: url)
            if let target = choice.targetTopicID, !topics.contains(where: { $0.id == target }) {
                topicsError = "The linked topic no longer exists in that map."
            }
        } catch {
            topics = []
            topicsError = "The topics of this map could not be read."
        }
    }
}

/// The package "New Map…" writes when the user picks the place (save panel).
struct NewMapFile: FileDocument {
    static var readableContentTypes: [UTType] { [.mindMap] }

    var topicText: String

    init(topicText: String) {
        self.topicText = topicText
    }

    init(configuration: ReadConfiguration) throws {
        topicText = try MindMapPackage.read(configuration.file).root.text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try MapFiles.newMapPackage(named: topicText)
    }
}
