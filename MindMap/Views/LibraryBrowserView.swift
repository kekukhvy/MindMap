import SwiftUI

/// The iCloud map library as a list (WP14b "Open from Library…"; WP13 builds
/// the Welcome screen from it): search, sort, open, delete (confirmed),
/// New Map. Platform-neutral — the host decides how a map opens.
struct LibraryBrowserView: View {
    var service: LibraryService = .shared
    /// Opens a library package (host: new window / tab, or this window).
    let onOpen: (URL) -> Void
    var onNewMap: (() -> Void)?
    /// Closes the sheet / window (nil = no Cancel button).
    var onCancel: (() -> Void)?

    @State private var search = ""
    @AppStorage("MindMap.librarySort") private var sort = LibrarySort.modified
    @State private var selection: MapLocation?
    @State private var pendingDelete: MapSummary?
    @State private var errorText: String?

    private var items: [MapSummary] {
        _ = service.revision
        return LibraryListModel.items(service.store.maps(), search: search, sort: sort)
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            header
            searchField
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            Divider()
            if items.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(items)
            }
            Divider()
            footer(items)
        }
        .confirmationDialog(pendingDelete.map { "Delete “\($0.title)”?" } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { map in
            Button("Delete Map", role: .destructive) { delete(map) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The map is removed from the library on all your devices. This cannot be undone.")
        }
        .alert("Library", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("iCloud Library")
                    .font(.title2.weight(.semibold))
                Label(service.status.shortTitle, systemImage: service.status.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(service.status.title)
            }
            Spacer()
            Picker("Sort By", selection: $sort) {
                ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search maps", text: $search)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { search = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }

    private func list(_ items: [MapSummary]) -> some View {
        List(selection: $selection) {
            ForEach(items) { map in
                LibraryMapRow(map: map, status: map.libraryID.map(service.status(of:)))
                    .tag(map.location)
                    #if os(iOS)
                    .contentShape(Rectangle())
                    .onTapGesture { open(map) }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = map }
                    }
                    #endif
            }
        }
        .listStyle(.plain)
        .contextMenu(forSelectionType: MapLocation.self) { locations in
            if let location = locations.first, let map = items.first(where: { $0.location == location }) {
                Button("Open", systemImage: "arrow.up.forward.app") { open(map) }
                Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = map }
            }
        } primaryAction: { locations in
            if let location = locations.first, let map = items.first(where: { $0.location == location }) { open(map) }
        }
        #if os(macOS)
        .onDeleteCommand {
            if let selection, let map = items.first(where: { $0.location == selection }) { pendingDelete = map }
        }
        #endif
    }

    @ViewBuilder private var emptyState: some View {
        if search.isEmpty {
            ContentUnavailableView {
                Label("No Maps in the Library", systemImage: "icloud")
            } description: {
                Text("New maps go here when Storage is set to iCloud Sync. Files can be moved in with "
                    + "Move to Library.")
            } actions: {
                if let onNewMap { Button("New Map", action: onNewMap) }
            }
        } else {
            ContentUnavailableView.search(text: search)
        }
    }

    private func footer(_ items: [MapSummary]) -> some View {
        HStack {
            if let onNewMap {
                Button("New Map", systemImage: "plus", action: onNewMap)
            }
            Spacer()
            Text("\(items.count) map\(items.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let onCancel {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            Button("Open") {
                if let selection, let map = items.first(where: { $0.location == selection }) { open(map) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection == nil || !items.contains { $0.location == selection })
        }
        .padding(12)
    }

    private func open(_ map: MapSummary) {
        guard let url = service.store.packageURL(for: map.location) else {
            errorText = "“\(map.title)” is not available any more."
            return
        }
        onOpen(url)
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
                if selection == map.location { selection = nil }
            } catch {
                errorText = "“\(map.title)” could not be deleted (\(error.localizedDescription))."
            }
        }
    }
}

/// One library map: lock / map icon, title, modified date, sync state.
struct LibraryMapRow: View {
    let map: MapSummary
    var status: LibrarySyncStatus?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: map.isLocked ? "lock.fill" : "point.3.connected.trianglepath.dotted")
                .font(.system(size: 15))
                .foregroundStyle(map.isLocked ? Color.orange : Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(map.title)
                    .lineLimit(1)
                Text(Self.dateText(map.modified))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if map.isLocked {
                Text("Locked")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Only maps waiting to upload (the header shows the library state).
            if let status, status == .syncing {
                Image(systemName: status.systemImage)
                    .foregroundStyle(.secondary)
                    .help("Waiting to upload")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    static func dateText(_ date: Date?) -> String {
        guard let date else { return "Not modified yet" }
        if Calendar.current.isDateInToday(date) {
            return "Today, " + date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday, " + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

#if os(macOS)
/// macOS "Open from Library…" window (⇧⌘O). Closes when a map opens.
struct LibraryWindow: View {
    static let id = "library"
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        LibraryBrowserView(onOpen: { url in
            MapHost.open(url)
            dismissWindow(id: Self.id)
        }, onNewMap: {
            if let summary = try? LibraryService.shared.store.createUntitledMap(),
               let url = LibraryService.shared.store.packageURL(for: summary.location) {
                MapHost.open(url)
                dismissWindow(id: Self.id)
            }
        }, onCancel: { dismissWindow(id: Self.id) })
        .frame(minWidth: 460, idealWidth: 520, minHeight: 380, idealHeight: 480)
    }
}
#endif
