import SwiftUI

/// Add / edit a topic's link: Web (URL, "https://" added when no scheme)
/// or Topic (searchable list of this map's topics with their path, or
/// pick the target on the canvas). Saving is one undo step.
struct LinkEditorSheet: View {
    enum Mode: Hashable {
        case web, topic
    }

    let editor: EditorController
    let nodeID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .web
    @State private var urlText = ""
    @State private var query = ""
    @State private var targetID: UUID?
    @FocusState private var urlFocused: Bool

    private var existing: TopicLink? { editor.link(of: nodeID) }
    private var normalizedURL: URL? { LinkURL.normalize(urlText) }

    private var newLink: TopicLink? {
        switch mode {
        case .web: return normalizedURL.map(TopicLink.web)
        case .topic: return targetID.flatMap { editor.model.map.contains($0) ? TopicLink.topic($0) : nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add Link" : "Edit Link")
                .font(.headline)
            Picker("Link to", selection: $mode) {
                Text("Web").tag(Mode.web)
                Text("Topic").tag(Mode.topic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch mode {
            case .web: webPane
            case .topic: topicPane
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 480, height: 440)
        #else
        .presentationDetents([.medium, .large])
        #endif
        .onAppear(perform: load)
    }

    // MARK: Web

    private var webPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("example.com or https://…", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .focused($urlFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .onSubmit(save)
            Group {
                if urlText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Opens in your default browser.")
                } else if let url = normalizedURL {
                    Text(url.absoluteString).lineLimit(2).truncationMode(.middle)
                } else {
                    Text("Not a valid web address").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Topic

    private var candidates: [LinkCandidate] {
        editor.model.map.linkCandidates(matching: query, excluding: nodeID)
    }

    private var topicPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search topics", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Pick on Canvas", systemImage: "scope") { editor.beginLinkPick(for: nodeID) }
                    .help("Close and click the target topic on the map (Esc cancels)")
            }
            List(candidates) { candidate in
                Button { targetID = candidate.id } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.text).lineLimit(1)
                            if !candidate.breadcrumb.isEmpty {
                                Text(candidate.breadcrumb)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        Spacer()
                        if candidate.id == targetID {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(candidate.id == targetID ? Color.accentColor.opacity(0.12) : nil)
            }
            .listStyle(.plain)
            .overlay {
                if candidates.isEmpty { Text("No matching topics").foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            if existing != nil {
                Button("Remove Link", role: .destructive) {
                    editor.removeLink(nodeID)
                    dismiss()
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(existing == nil ? "Add Link" : "Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(newLink == nil)
        }
    }

    private func load() {
        switch existing {
        case let .web(url):
            mode = .web
            urlText = url.absoluteString
        case let .topic(id):
            mode = .topic
            targetID = id
        case nil:
            mode = .web
        }
        urlFocused = mode == .web
    }

    private func save() {
        guard let newLink else { return }
        if newLink != existing { editor.setLink(newLink, for: nodeID) }
        dismiss()
    }
}
