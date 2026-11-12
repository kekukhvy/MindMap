import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Viewer of an imported file: name (rename), type/size, QuickLook preview
/// and actions. iPad (sheet): Share, Open In…, Rename, Remove. macOS
/// (window): Share, Open with the default app, Export…, Rename, Remove.
///
/// The file lives inside the map package, so preview / share / open-in /
/// export all use a temp copy named with the attachment's title. Changes
/// another app makes to such a copy are NOT saved back into the map
/// (out of scope; re-attach the edited file instead).
struct FileAttachmentView: View {
    let model: MindMapModel
    let attachment: Attachment
    let undoManager: UndoManager?

    @State private var title = ""
    @State private var didLoad = false
    /// Temp copy for preview + share (refreshed on rename / content change).
    @State private var copyURL: URL?
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var openIn = OpenInPresenter()
    #endif

    private var store: AttachmentStore { model.attachmentStore }
    private var storedExtension: String { (attachment.fileName as NSString).pathExtension }
    private var copyKey: String { "\(store.revision(of: attachment.fileName))|\(AttachmentFileName.exportName(for: attachment))" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            preview
        }
        .toolbar { toolbar }
        .onAppear {
            guard !didLoad else { return }
            title = attachment.title
            didLoad = true
        }
        .task(id: copyKey) { refreshCopy() }
        .onChange(of: attachment.title) { _, newTitle in
            if !titleFocused { title = newTitle }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
        }
        .onDisappear(perform: commitTitle)
        .alert("File", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.symbol(forExtension: storedExtension))
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                TextField("File Name", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        #if os(iOS)
        .background(alignment: .topTrailing) { OpenInAnchor(presenter: openIn).frame(width: 1, height: 1) }
        #endif
    }

    @ViewBuilder private var preview: some View {
        if let copyURL {
            QuickLookPreview(url: copyURL, title: attachment.title)
        } else {
            ContentUnavailableView("No Preview", systemImage: "doc.questionmark",
                                   description: Text("The file is missing from the map."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var details: String {
        var parts: [String] = []
        if let type = UTType(filenameExtension: storedExtension), let name = type.localizedDescription {
            parts.append(name)
        } else if !storedExtension.isEmpty {
            parts.append(storedExtension.uppercased() + " file")
        }
        if let size = store.size(of: attachment.fileName) {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let copyURL {
                ShareLink(item: copyURL) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            #if os(macOS)
            Button("Open", systemImage: "arrow.up.forward.app", action: openWithDefaultApp)
                .help("Open a copy with the default app (changes there are not saved into the map)")
            #endif
            Menu("Actions", systemImage: "ellipsis.circle") {
                #if os(iOS)
                Button("Open In…", systemImage: "arrow.up.forward.app", action: presentOpenIn)
                #else
                Button("Open with Default App", systemImage: "arrow.up.forward.app", action: openWithDefaultApp)
                Button("Export…", systemImage: "square.and.arrow.down", action: export)
                #endif
                Button("Rename", systemImage: "pencil") { titleFocused = true }
                Divider()
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
            }
        }
    }

    // MARK: Actions

    private func refreshCopy() {
        let old = copyURL
        copyURL = try? model.exportCopy(of: attachment.id)
        if let old, old != copyURL { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
    }

    private func commitTitle() {
        guard didLoad else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            title = attachment.title
            return
        }
        model.renameAttachment(attachment.id, to: trimmed, undoManager: undoManager)
    }

    private func remove() {
        titleFocused = false
        model.removeAttachment(attachment.id, undoManager: undoManager)
        dismiss()
    }

    #if os(iOS)
    private func presentOpenIn() {
        do {
            openIn.present(try model.exportCopy(of: attachment.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #else
    /// Opens a fresh temp copy (the package file itself stays untouched).
    private func openWithDefaultApp() {
        do {
            let url = try model.exportCopy(of: attachment.id)
            if !NSWorkspace.shared.open(url) { errorMessage = "No app can open “\(url.lastPathComponent)”." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Save As a copy anywhere, then reveal it in Finder.
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AttachmentFileName.exportName(for: attachment)
        panel.canCreateDirectories = true
        let fileName = attachment.fileName
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                // The panel already asked about replacing an existing file.
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try store.copy(fileName, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    #endif

    /// SF Symbol for a file type (by extension).
    static func symbol(forExtension ext: String) -> String {
        guard let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

#if os(iOS)
/// "Open In…" (UIDocumentInteractionController): apps that can open a copy;
/// falls back to the options menu (Share, Save to Files, Print…).
final class OpenInPresenter {
    weak var anchor: UIView?
    private var controller: UIDocumentInteractionController?

    func present(_ url: URL) {
        guard let anchor else { return }
        let controller = UIDocumentInteractionController(url: url)
        self.controller = controller
        let rect = CGRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1)
        if !controller.presentOpenInMenu(from: rect, in: anchor, animated: true) {
            controller.presentOptionsMenu(from: rect, in: anchor, animated: true)
        }
    }
}

/// Invisible view the Open In… popover points at.
private struct OpenInAnchor: UIViewRepresentable {
    let presenter: OpenInPresenter

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        presenter.anchor = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        presenter.anchor = view
    }
}
#endif
