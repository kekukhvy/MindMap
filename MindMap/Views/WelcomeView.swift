import SwiftUI

/// What the Welcome screen asks its host to do (macOS window / iPad window).
struct WelcomeActions {
    var newMap: () -> Void
    /// File ▸ Open… (open panel / document picker).
    var openFile: () -> Void
    /// Opens a map package (library or file).
    var open: (URL) -> Void
    /// iPad: back to the open map (nil = no map behind the Welcome screen).
    var close: (() -> Void)?
}

/// The Welcome screen (WP13, VS Code-like): Start actions on the left
/// (New Map in the default store, Open…, Open Sample, Welcome Tour, "Show
/// Welcome on launch"), on the right a search field and two lists —
/// Library (iCloud Sync maps) and Recent Files (10 most recent `.mindmap`
/// files, thumbnails, Remove from List / Show in Finder). Platform-neutral;
/// the host opens maps and closes the window.
struct WelcomeView: View {
    var flow: WelcomeFlow = .shared
    let actions: WelcomeActions
    /// The Welcome Tour sheet (per window on iPad).
    @Binding var isShowingTour: Bool
    /// Extra recents from the system (macOS NSDocumentController).
    var systemRecents: () -> [URL] = { [] }

    @State private var search = ""
    @State private var recents: [RecentMap] = []
    @State private var pendingDelete: MapSummary?
    @State private var errorText: String?
    @State private var showsAllLibraryMaps = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Library maps listed before "Show All".
    private static let libraryPreviewCount = 5

    private var service: LibraryService { flow.service }

    var body: some View {
        Group {
            if sizeClass == .compact {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        startColumn
                        listsColumn
                    }
                    .padding(20)
                }
            } else {
                HStack(spacing: 0) {
                    startColumn
                        .frame(width: 270)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 28)
                    Divider()
                    ScrollView {
                        listsColumn
                            .padding(.horizontal, 28)
                            .padding(.vertical, 24)
                    }
                }
            }
        }
        .background(WelcomeColors.background)
        .task(id: flow.recentsRevision) { reloadRecents() }
        .onReceive(NotificationCenter.default.publisher(for: Self.activation)) { _ in reloadRecents() }
        .sheet(isPresented: $isShowingTour) {
            WelcomeTourSheet(flow: flow, openMap: actions.open) { isShowingTour = false }
        }
        .confirmationDialog(pendingDelete.map { "Delete “\($0.title)”?" } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { map in
            Button("Delete Map", role: .destructive) { delete(map) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The map is removed from the library on all your devices. This cannot be undone.")
        }
        .alert("MindMap", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    #if os(macOS)
    private static let activation = NSApplication.didBecomeActiveNotification
    #else
    private static let activation = UIApplication.didBecomeActiveNotification
    #endif

    // MARK: Start

    private var startColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image("WelcomeIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MindMap")
                        .font(.system(size: 28, weight: .bold))
                    Text("Think in maps.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 28)

            sectionTitle("Start")
            VStack(alignment: .leading, spacing: 4) {
                StartAction(title: "New Map", detail: newMapDetail, systemImage: "plus.square.on.square",
                            action: actions.newMap)
                    .accessibilityIdentifier("welcome.newMap")
                StartAction(title: "Open…", detail: "A .mindmap file", systemImage: "folder", action: actions.openFile)
                StartAction(title: "Open Sample", detail: SampleMaps.featuresName, systemImage: "sparkles",
                            action: openSample)
                StartAction(title: "Welcome Tour", detail: "What MindMap can do", systemImage: "play.rectangle",
                            action: { isShowingTour = true })
            }
            Spacer(minLength: 24)
            Toggle("Show Welcome on launch", isOn: Binding(get: { flow.showsWelcomeOnLaunch },
                                                           set: { flow.showsWelcomeOnLaunch = $0 }))
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .font(.callout)
                .foregroundStyle(.secondary)
            if let close = actions.close {
                Button("Back to Map", systemImage: "chevron.backward", action: close)
                    .padding(.top, 12)
            }
        }
    }

    private var newMapDetail: String {
        service.settings.storageMode == .library ? "In iCloud Sync" : "As a .mindmap file"
    }

    // MARK: Lists

    private var listsColumn: some View {
        let library = libraryItems
        let recent = filteredRecents
        return VStack(alignment: .leading, spacing: 22) {
            WelcomeSearchField(text: $search)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    sectionTitle("Library")
                    Spacer()
                    Label(service.status.shortTitle, systemImage: service.status.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(service.status.title)
                }
                if library.isEmpty {
                    emptyText(search.isEmpty ? "No maps in iCloud Sync yet. New maps go here when Storage is "
                        + "iCloud Sync." : "No library maps match “\(search)”.")
                } else {
                    let shown = showsAllLibraryMaps || !search.isEmpty ? library
                        : Array(library.prefix(Self.libraryPreviewCount))
                    ForEach(shown) { map in
                        if let url = service.store.packageURL(for: map.location) {
                            WelcomeMapRow(url: url, title: map.title, detail: LibraryMapRow.dateText(map.modified),
                                          location: "iCloud Sync", isLocked: map.isLocked) {
                                actions.open(url)
                            }
                            .contextMenu {
                                Button("Open", systemImage: "arrow.up.forward.app") { actions.open(url) }
                                Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = map }
                            }
                        }
                    }
                    if library.count > shown.count || showsAllLibraryMaps && search.isEmpty
                        && library.count > Self.libraryPreviewCount {
                        Button(showsAllLibraryMaps ? "Show Fewer" : "Show All \(library.count) Maps") {
                            withAnimation(.snappy) { showsAllLibraryMaps.toggle() }
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .padding(.leading, 8)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Recent Files")
                if recent.isEmpty {
                    emptyText(search.isEmpty ? "Maps you open from files appear here."
                        : "No recent files match “\(search)”.")
                } else {
                    ForEach(recent) { item in
                        WelcomeMapRow(url: item.url, title: item.name,
                                      detail: LibraryMapRow.dateText(MapThumbnails.modificationDate(of: item.url)),
                                      location: RecentLocation.text(for: item.url),
                                      isLocked: MapThumbnails.isLocked(item.url)) {
                            actions.open(item.url)
                        }
                        .contextMenu {
                            Button("Open", systemImage: "arrow.up.forward.app") { actions.open(item.url) }
                            Button("Remove from List", systemImage: "minus.circle") { flow.removeRecent(item.url) }
                            #if os(macOS)
                            Button("Show in Finder", systemImage: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            }
                            #endif
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    private var libraryItems: [MapSummary] {
        _ = service.revision
        return LibraryListModel.items(service.store.maps(), search: search, sort: .modified)
    }

    private var filteredRecents: [RecentMap] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return recents }
        return recents.filter {
            $0.name.localizedStandardContains(needle) || RecentLocation.text(for: $0.url).localizedStandardContains(needle)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 6)
    }

    // MARK: Actions

    private func reloadRecents() {
        recents = flow.recents.merged(with: systemRecents()) { service.libraryMapID(of: $0) != nil }
    }

    private func openSample() {
        Task {
            do {
                actions.open(try await flow.sampleURL())
            } catch {
                errorText = "The sample map could not be copied (\(error.localizedDescription))."
            }
        }
    }

    private func delete(_ map: MapSummary) {
        Task {
            if let url = service.store.packageURL(for: map.location) {
                #if os(macOS)
                MapHost.close(url)
                #else
                await DocumentSession.closeLibraryMap(url)
                #endif
            }
            do {
                try service.store.deleteMap(map.location)
            } catch {
                errorText = "“\(map.title)” could not be deleted (\(error.localizedDescription))."
            }
        }
    }
}

/// Colors of the Welcome screen and tour.
enum WelcomeColors {
    #if os(macOS)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    #else
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    #endif
    static let brand = Color(red: 0.16, green: 0.62, blue: 0.42)
}

/// "New Map", "Open…" … in the Start column.
private struct StartAction: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(WelcomeColors.brand)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(isHovered ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct WelcomeSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search maps", text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.12)))
    }
}

/// Human description of where a file lives ("iCloud Drive › MindMap",
/// "~/Documents/Maps", "On My iPad › MindMap").
enum RecentLocation {
    static func text(for url: URL) -> String {
        let folder = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let parts = folder.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "Mobile Documents"), index + 1 < parts.count {
            let container = parts[index + 1]
            var rest = Array(parts[(index + 2)...])
            var head = ["iCloud Drive"]
            if container != "com~apple~CloudDocs" {
                // App folder: iCloud~com~kekukh~MindMap/Documents → "MindMap".
                head.append(container.split(separator: "~").last.map(String.init) ?? container)
                if rest.first == "Documents" { rest.removeFirst() }
            }
            return (head + rest).joined(separator: " › ")
        }
        if let index = parts.firstIndex(of: "Containers"), index + 2 < parts.count, parts[index + 2] == "Data" {
            // macOS sandbox container: the app's own folders.
            return (["MindMap"] + parts[(index + 3)...]).joined(separator: " › ")
        }
        #if os(iOS)
        if let index = parts.firstIndex(of: "Documents"), parts.contains("Application") || parts.contains("Containers") {
            return (["On My iPad", "MindMap"] + parts[(index + 1)...]).joined(separator: " › ")
        }
        #endif
        let home = realHome
        if folder == home { return "~" }
        if folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
        return folder
    }

    /// The user's home folder (not the sandbox container).
    private static var realHome: String {
        #if os(macOS)
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        #endif
        return NSHomeDirectory()
    }
}
