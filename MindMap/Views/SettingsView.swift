import SwiftUI
import UniformTypeIdentifiers

/// App settings (macOS Settings window ⌘, ; iPad sheet from the "…" /
/// documents menu): Storage (mode, iCloud status, Move Maps…), Mirror
/// library to folder (Obsidian), Lock (Auto-Lock).
struct SettingsView: View {
    let service: LibraryService
    /// iPad sheet: Done button.
    let onDone: (() -> Void)?

    @AppStorage(LockSettings.autoLockKey) private var autoLockMinutes = LockSettings.defaultMinutes
    @State private var isShowingMoveMaps = false
    @State private var isChoosingFolder = false
    @State private var showsFix: Bool

    init(service: LibraryService? = nil, showsFix: Bool = false, onDone: (() -> Void)? = nil) {
        self.service = service ?? .shared
        self.onDone = onDone
        _showsFix = State(initialValue: showsFix)
    }

    var body: some View {
        #if os(macOS)
        form
            .frame(width: 540)
            .frame(minHeight: 560)
        #else
        NavigationStack {
            form
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let onDone {
                        ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
                    }
                }
        }
        #endif
    }

    private var form: some View {
        Form {
            storageSection
            mirrorSection
            lockSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingMoveMaps) {
            MoveMapsView(service: service) { isShowingMoveMaps = false }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            try? service.mirror.settings.setFolder(url)
            service.mirror.updateNow()
        }
    }

    // MARK: Storage

    private var storageMode: Binding<StorageMode> {
        Binding(get: { service.settings.storageMode }, set: { service.settings.storageMode = $0 })
    }

    private var storageSection: some View {
        Section {
            Picker("New maps", selection: storageMode) {
                Text("iCloud Sync (works without iCloud Drive)").tag(StorageMode.library)
                Text("Files").tag(StorageMode.files)
            }
            #if os(macOS)
            .pickerStyle(.radioGroup)
            #else
            .pickerStyle(.inline)
            #endif
            Text(storageExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            statusRow
            LabeledContent {
                Button("Move Maps…") { isShowingMoveMaps = true }
            } label: {
                Text("Switching does not move existing maps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Storage")
        }
    }

    private var storageExplanation: String {
        switch service.settings.storageMode {
        case .library:
            return "Maps are kept in MindMap's own iCloud library (CloudKit) and synced to all your devices — "
                + "iCloud Drive can be off. They stay available offline. File ▸ Open… still opens .mindmap files."
        case .files:
            return "Each map is a .mindmap file in a folder you choose (on this device or in iCloud Drive). "
                + "The library stays available from File ▸ Open from Library…"
        }
    }

    private var statusRow: some View {
        let status = service.status
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: status.systemImage)
                    .foregroundStyle(statusColor(status))
                Text(status.title)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if status.fixHint != nil {
                    Button(showsFix ? "Hide" : "How to fix") { showsFix.toggle() }
                        .buttonStyle(.borderless)
                }
            }
            if showsFix, let hint = status.fixHint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusColor(_ status: LibrarySyncStatus) -> Color {
        switch status {
        case .synced: return .green
        case .syncing, .checking: return .accentColor
        case .offline: return .orange
        case .unavailable: return .red
        }
    }

    // MARK: Mirror

    private var mirrorSection: some View {
        let mirror = service.mirror
        let settings = mirror.settings
        return Section {
            Toggle("Mirror library to folder", isOn: Binding(get: { settings.isEnabled }, set: { on in
                settings.isEnabled = on
                if on, settings.folderBookmark == nil { isChoosingFolder = true } else { mirror.updateNow() }
            }))
            LabeledContent("Folder") {
                HStack {
                    Text(settings.folderURL?.lastPathComponent ?? "None")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { isChoosingFolder = true }
                }
            }
            Toggle("Also write .mindmap copies", isOn: Binding(get: { settings.includesMapCopies }, set: {
                settings.includesMapCopies = $0
                mirror.updateNow()
            }))
            .disabled(!settings.isEnabled)
            if settings.isEnabled, let result = mirror.lastResult {
                LabeledContent {
                    Button("Update Now") { mirror.updateNow() }
                        .buttonStyle(.borderless)
                } label: {
                    Text(result).font(.callout).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Mirror")
        } footer: {
            Text("One way, library → folder: every library map is written as a plain Markdown note (outline + notes) "
                + "that Obsidian and other editors can read. Edits in the folder are not read back. Locked maps and "
                + "locked notes are never written in plaintext.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Lock

    private var lockSection: some View {
        Section {
            Picker("Auto-Lock", selection: $autoLockMinutes) {
                ForEach(LockSettings.choices, id: \.self) { minutes in
                    Text(LockSettings.title(minutes: minutes)).tag(minutes)
                }
            }
        } header: {
            Text("Lock")
        } footer: {
            Text("Locked maps lock again after this time without input, and always when the device sleeps or "
                + "MindMap goes to the background.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// "Move Maps…": files → library (import, optionally trashing the files)
/// and library → folder (export, optionally removing them from the library).
struct MoveMapsView: View {
    let service: LibraryService
    let onDone: () -> Void

    @State private var isPickingFiles = false
    @State private var isPickingFolder = false
    @State private var trashFiles = false
    @State private var removeFromLibrary = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Move the files to the Trash afterwards", isOn: $trashFiles)
                    Button("Choose .mindmap Files…") { isPickingFiles = true }
                } header: {
                    Text("Files → iCloud Library")
                } footer: {
                    Text("Copies maps into the library (attachments and locks included).")
                }
                Section {
                    Toggle("Remove them from the library afterwards", isOn: $removeFromLibrary)
                    Button("Export All to Folder…") { isPickingFolder = true }
                        .disabled(service.store.maps().isEmpty)
                } header: {
                    Text("iCloud Library → Files")
                } footer: {
                    Text("Writes every library map (\(service.store.maps().count)) as a .mindmap file into a folder.")
                }
                if let result {
                    Section { Text(result).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Move Maps")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
            .background {
                Color.clear.fileImporter(isPresented: $isPickingFiles, allowedContentTypes: [.mindMap],
                                         allowsMultipleSelection: true) { picked in
                    if case let .success(urls) = picked { importFiles(urls) }
                }
            }
            .background {
                Color.clear.fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { picked in
                    if case let .success(url) = picked { exportAll(to: url) }
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 380)
        #endif
    }

    private func importFiles(_ urls: [URL]) {
        let outcome = LibraryMoves.importFiles(urls, into: service.store, trashOriginals: trashFiles)
        result = outcome.summary(verb: "moved to the library")
    }

    private func exportAll(to folder: URL) {
        let outcome = LibraryMoves.exportAll(service.store, to: folder, removeFromLibrary: removeFromLibrary) { url in
            #if os(macOS)
            MapTabOpener.document(for: url) != nil
            #else
            DocumentSession.session(showing: url) != nil
            #endif
        }
        result = outcome.summary(verb: "exported")
    }
}
