import SwiftUI

/// Map lock items (File menu on macOS / iPad menu bar, iPad documents
/// menu): Lock Map… / Lock Now / Remove Map Lock… / Unlock Map (the
/// Auto-Lock interval is in Settings ▸ Lock). They only post a
/// `LockRequest`; the document's `MapLockGate` performs it.
struct MapLockMenuItems: View {
    let model: MindMapModel?

    var body: some View {
        if let lock = model?.lock, lock.isMapLocked {
            if lock.isShowingLockScreen {
                Button("Unlock Map…", systemImage: "lock.open") { lock.request = .unlockMap }
            } else {
                Button("Lock Now", systemImage: "lock") { lock.request = .lockNow }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                Button("Remove Map Lock…", systemImage: "lock.slash") { lock.request = .removeMapLock }
            }
        } else {
            Button("Lock Map…", systemImage: "lock") { model?.lock.request = .lockMap }
                .disabled(model == nil)
        }
    }
}

/// File menu (macOS) / iPad menu bar: the focused map's lock items.
struct LockCommands: Commands {
    @FocusedValue(\.lockModel) private var model

    var body: some Commands {
        #if os(macOS)
        CommandGroup(after: .saveItem) {
            Divider()
            MapLockMenuItems(model: model)
        }
        #else
        CommandGroup(after: .newItem) {
            Divider()
            MapLockMenuItems(model: model)
        }
        #endif
    }
}

/// Lock items of one note / handwritten note (topic menus, editor toolbar):
/// "Lock Note" (plain) or "Unlock Note" + "Remove Lock" (locked). Files
/// cannot be locked (lock the whole map instead).
enum NoteLockMenu {
    enum Action: Hashable {
        case lock(UUID)
        case unlock(UUID)
        case removeLock(UUID)
    }

    /// Stand-in target of the disabled "Lock Note" when a topic has no note.
    static let noNote = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    static func actions(for attachment: Attachment, isDraft: Bool) -> [Action] {
        guard attachment.kind != .file, !isDraft else { return [] }
        return attachment.isLocked ? [.unlock(attachment.id), .removeLock(attachment.id)] : [.lock(attachment.id)]
    }

    static func title(_ action: Action) -> String {
        switch action {
        case .lock: return "Lock Note"
        case .unlock: return "Unlock Note"
        case .removeLock: return "Remove Lock"
        }
    }

    static func systemImage(_ action: Action) -> String {
        switch action {
        case .lock: return "lock"
        case .unlock: return "lock.open"
        case .removeLock: return "lock.slash"
        }
    }
}

extension EditorController {
    /// Lock menu actions of one note (see `NoteLockMenu`).
    func noteLockActions(_ attachmentID: UUID) -> [NoteLockMenu.Action] {
        guard let attachment = model.attachment(attachmentID) else { return [] }
        return NoteLockMenu.actions(for: attachment, isDraft: model.isDraft(attachmentID))
    }

    /// Lock Note goes through the gate (one-time info, errors); Unlock
    /// opens the note (its editor asks for Face ID / Touch ID); Remove Lock
    /// asks too, then decrypts (one undo step).
    func performNoteLock(_ action: NoteLockMenu.Action) {
        commitEditing()
        switch action {
        case let .lock(id): model.lock.request = .lockNote(id)
        case let .unlock(id): openAttachment(id)
        case let .removeLock(id): model.lock.request = .removeNoteLock(id)
        }
    }
}

/// Editor toolbar button of a note / handwritten note: Lock Note (stays
/// readable until the window / sheet closes) or Remove Lock.
struct NoteLockToolbarButton: View {
    let model: MindMapModel
    let attachmentID: UUID
    let undoManager: UndoManager?
    @AppStorage(LockSettings.noteInfoKey) private var didShowNoteInfo = false
    @State private var showsInfo = false
    @State private var errorMessage: String?

    var body: some View {
        if let attachment = model.attachment(attachmentID), attachment.kind != .file {
            Group {
                if attachment.isLocked {
                    Button("Remove Lock", systemImage: "lock.slash") { removeLock() }
                        .help("Remove the lock: the note is stored unencrypted again")
                } else {
                    Button("Lock Note", systemImage: "lock") {
                        if didShowNoteInfo { lock() } else { showsInfo = true }
                    }
                    .help("Lock this note with \(model.lock.services.authenticator.methodName)")
                    .disabled(model.isDraft(attachmentID))
                }
            }
            .alert("Lock Note?", isPresented: $showsInfo) {
                Button("Lock") { lock() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(LockAlert.noteInfo(attachmentID).message(methodName: model.lock.services.authenticator.methodName))
            }
            .alert("Lock", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func lock() {
        didShowNoteInfo = true
        do {
            let storage = try model.lockNote(attachmentID, keepUnlocked: true, undoManager: undoManager)
            model.lock.request = .saveAndPurgeVersions
            if storage == .thisDevice { errorMessage = LockAlert.thisDeviceMessage }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func removeLock() {
        Task {
            switch await model.removeNoteLock(attachmentID, reason: "Remove the lock of a note", undoManager: undoManager) {
            case let .failed(text), let .unavailable(text): errorMessage = text
            case .success, .cancelled: break
            }
        }
    }
}
