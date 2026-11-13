import SwiftUI

/// Store actions of the focused map (macOS File menu, iPad documents menu,
/// store badge): library map → Rename… / Duplicate / Export as File…;
/// file → Import to Library / Move to Library… / Duplicate.
struct MapStorageMenuItems: View {
    let isLibraryMap: Bool
    let hasFile: Bool
    /// Looked up when an item is chosen (the map's view may create it later).
    let storage: () -> MapStorageController?
    /// macOS File menu: the standard Rename… / Duplicate items exist there
    /// already (a library map duplicates as "Duplicate in Library").
    var isFileMenu = false

    init(storage: MapStorageController?, isFileMenu: Bool = false) {
        isLibraryMap = storage?.isLibraryMap == true
        hasFile = storage?.documentURL != nil
        self.storage = { storage }
        self.isFileMenu = isFileMenu
    }

    /// iPad documents menu: the open document of the window.
    init(model: MindMapModel, documentURL: URL?) {
        isLibraryMap = LibraryService.shared.libraryMapID(of: documentURL) != nil
        hasFile = documentURL != nil
        storage = { MapStorageController.controller(for: model) }
    }

    var body: some View {
        if isLibraryMap {
            if !isFileMenu {
                Button("Rename…", systemImage: "pencil") { storage()?.beginRename() }
            }
            Button(isFileMenu ? "Duplicate in Library" : "Duplicate", systemImage: "plus.square.on.square") {
                storage()?.duplicate()
            }
            Button("Export as File…", systemImage: "square.and.arrow.up") { storage()?.beginExport() }
        } else {
            #if os(iOS)
            Button("Rename…", systemImage: "pencil") { storage()?.beginRename() }
                .disabled(!hasFile)
            #endif
            Button("Import to Library", systemImage: "icloud.and.arrow.up") { storage()?.importToLibrary() }
                .disabled(!hasFile)
            Button("Move to Library…", systemImage: "arrow.up.doc.on.clipboard") { storage()?.beginMove() }
                .disabled(!hasFile)
            if !isFileMenu {
                Button("Duplicate", systemImage: "plus.square.on.square") { storage()?.duplicate() }
                    .disabled(!hasFile)
            }
        }
    }
}

/// Small store badge in the map's toolbar: cloud (library map, with its
/// sync state) or document (file). Its menu shows where the map lives and
/// the store actions. iPad: icon + map name, standing in for the title.
struct StoreBadge: View {
    let storage: MapStorageController
    var service: LibraryService = .shared

    private var status: LibrarySyncStatus? {
        storage.libraryID.map(service.status(of:))
    }

    var body: some View {
        Menu {
            Section(location) {
                if let status { Text(status.title) }
            }
            MapStorageMenuItems(storage: storage)
        } label: {
            #if os(iOS)
            // iPad: the badge is the window's title menu (icon + map name).
            HStack(spacing: 6) {
                Image(systemName: status?.systemImage ?? "doc")
                Text(storage.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            #else
            Label(location, systemImage: status?.systemImage ?? "doc")
            #endif
        }
        .menuIndicator(.hidden)
        .help(status.map { "\(location) — \($0.title)" } ?? location)
        .accessibilityLabel(status.map { "iCloud Library, \($0.shortTitle)" } ?? "File")
    }

    private var location: String {
        if storage.isLibraryMap { return "iCloud Library" }
        return storage.documentURL == nil ? "Not Saved" : "File"
    }
}

#if os(macOS)
/// macOS File menu: New Map (⌘N, storage setting), Open from Library…
/// (⇧⌘O), and the focused map's store actions.
struct StorageCommands: Commands {
    @FocusedValue(\.mindMapEditor) private var editor

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Replaces only the standard "New" (Open… / Open Recent stay).
            Button("New Map") { MapHost.newMap() }
                .keyboardShortcut("n", modifiers: .command)
            // The Welcome window lists the library (WP13).
            Button("Open from Library…") { WelcomeWindowController.shared.show() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            Divider()
            // Rename: the standard File ▸ Rename… (a library map takes the new
            // package name as its title, `MapStorageController.documentURLDidChange`).
            MapStorageMenuItems(storage: editor?.storage, isFileMenu: true)
        }
    }
}
#endif
