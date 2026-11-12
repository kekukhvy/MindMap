import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Wraps a document's editor (WP12): shows `LockScreenView` instead of the
/// map while a locked map is locked, runs lock requests from menus
/// (`DocumentLock.request`) with the document's undo manager, and relocks:
/// idle timeout (setting, default 5 min), iPad: app in background, macOS:
/// screen sleep / screen lock / fast user switch; "Lock Now" from the menus.
/// Relocking saves first, then clears the undo history (it holds plaintext
/// and must not change the hidden map) — see `LockRelocker`.
///
/// The gate itself has no state: everything lives in `MapLockGateModifier`,
/// whose re-renders never re-create the wrapped editor view value (an
/// editor view re-created per render would build a throwaway
/// `EditorController` each time).
struct MapLockGate<Content: View>: View {
    let model: MindMapModel
    /// Document name for prompts (never stored in the package).
    let title: String
    var documentURL: URL?
    /// iPad: saves the document now and calls back (macOS uses NSDocument).
    var save: ((@escaping () -> Void) -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().modifier(MapLockGateModifier(model: model, title: title, documentURL: documentURL, save: save))
    }
}

struct MapLockGateModifier: ViewModifier {
    let model: MindMapModel
    let title: String
    var documentURL: URL?
    var save: ((@escaping () -> Void) -> Void)?

    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(LockSettings.autoLockKey) private var autoLockMinutes = LockSettings.defaultMinutes
    @AppStorage(LockSettings.noteInfoKey) private var didShowNoteInfo = false
    @State private var alert: LockAlert?
    #if os(macOS)
    /// Not observed: a window change must not re-render the gate (each
    /// re-render re-creates the content view value, see `body`).
    @State private var windowBox = HostWindowBox()
    private var hostWindow: NSWindow? { windowBox.window }
    #endif

    private var lock: DocumentLock { model.lock }

    func body(content: Content) -> some View {
        ZStack {
            if lock.isShowingLockScreen {
                LockScreenView(model: model, title: title)
                    .transition(.opacity)
            } else {
                content
            }
        }
        .focusedSceneValue(\.lockModel, model)
        .onAppear {
            LockActivity.shared.start()
            #if DEBUG
            DebugLockActions.run(model, title: title)
            #endif
        }
        .onChange(of: lock.request, initial: true) { _, request in handle(request) }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in checkIdle() }
        // Map edits count as activity; observed in a child view so the gate
        // itself does not re-render (and re-create its content) per edit.
        .background { MapActivityObserver(model: model) }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            if phase == .background { relock(autoPrompt: true) }
            #endif
        }
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
               presenting: alert) { alert in
            switch alert {
            case .confirmLockMap:
                Button("Lock Map") { performLockMap() }
                Button("Cancel", role: .cancel) {}
            case let .noteInfo(id):
                Button("Lock") { performLockNote(id) }
                Button("Cancel", role: .cancel) {}
            case .message:
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message(methodName: lock.services.authenticator.methodName))
        }
        #if os(iOS)
        .background { TouchActivityObserver().allowsHitTesting(false) }
        #else
        .background { HostWindowReader { windowBox.window = $0 } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in
            relock(autoPrompt: false)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in
            relock(autoPrompt: false)
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked"))) { _ in
            relock(autoPrompt: false)
        }
        #endif
    }

    // MARK: Requests

    private func handle(_ request: LockRequest?) {
        guard let request else { return }
        lock.request = nil
        switch request {
        case .lockMap:
            alert = .confirmLockMap(title: title)
        case .lockNow:
            relock(autoPrompt: false)
        case .unlockMap:
            Task { await model.unlockMap(reason: "Unlock “\(title)”") }
        case .removeMapLock:
            Task {
                let result = await model.removeMapLock(reason: "Remove the lock of “\(title)”", undoManager: undoManager)
                show(result)
            }
        case let .lockNote(id):
            if didShowNoteInfo { performLockNote(id) } else { alert = .noteInfo(id) }
        case .saveAndPurgeVersions:
            LockRelocker.saveAndPurgeVersions(of: model, documentURL: currentURL, save: saveAction)
        case let .removeNoteLock(id):
            Task {
                let result = await model.removeNoteLock(id, reason: "Remove the lock of a note", undoManager: undoManager)
                show(result)
            }
        }
    }

    private func show(_ result: LockAuthResult) {
        switch result {
        case let .failed(message), let .unavailable(message): alert = .message("Lock", message)
        case .success, .cancelled: break
        }
    }

    private func performLockMap() {
        do {
            let storage = try model.lockMap(undoManager: undoManager)
            LockRelocker.saveAndPurgeVersions(of: model, documentURL: currentURL, save: saveAction)
            if storage == .thisDevice { alert = .message("Map Locked", LockAlert.thisDeviceMessage) }
        } catch {
            alert = .message("Lock Map", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func performLockNote(_ id: UUID) {
        didShowNoteInfo = true
        do {
            let storage = try model.lockNote(id, undoManager: undoManager)
            LockRelocker.saveAndPurgeVersions(of: model, documentURL: currentURL, save: saveAction)
            if storage == .thisDevice { alert = .message("Note Locked", LockAlert.thisDeviceMessage) }
        } catch {
            alert = .message("Lock Note", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: Relock

    private func checkIdle() {
        let timeout = TimeInterval(autoLockMinutes * 60)
        if lock.isIdleExpired(now: Date(), lastActivity: LockActivity.shared.lastActivity, timeout: timeout) {
            relock(autoPrompt: false)
        }
    }

    private func relock(autoPrompt: Bool) {
        LockRelocker.relock(model, autoPrompt: autoPrompt, undoManager: undoManager, save: saveAction)
    }

    /// Saves the document now, then calls back (nil: cannot save from here).
    private var saveAction: ((@escaping () -> Void) -> Void)? {
        #if os(macOS)
        guard let window = hostWindow, let document = NSDocumentController.shared.document(for: window) else {
            return nil
        }
        return { [weak document] done in
            guard let document else { return done() }
            document.autosave(withImplicitCancellability: false) { _ in done() }
        }
        #else
        return save
        #endif
    }

    private var currentURL: URL? {
        #if os(macOS)
        if let window = hostWindow, let url = NSDocumentController.shared.document(for: window)?.fileURL { return url }
        #endif
        return documentURL
    }
}

#if os(macOS)
final class HostWindowBox {
    weak var window: NSWindow?
}
#endif

/// Records map edits as user activity (idle auto-lock).
private struct MapActivityObserver: View {
    let model: MindMapModel

    var body: some View {
        Color.clear
            .onChange(of: model.map) { _, _ in LockActivity.shared.touch() }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Relock + history policy (testable without views).
enum LockRelocker {
    /// Hides the map (and forgets unlocked notes). When the map was visible,
    /// saves, then clears the undo history: its steps hold plaintext and
    /// must not change the hidden map (⌘Z while locked). Without a way to
    /// save, the history is kept (clearing could lose unsaved changes).
    @MainActor
    static func relock(_ model: MindMapModel, autoPrompt: Bool, undoManager: UndoManager?,
                       save: ((@escaping () -> Void) -> Void)?) {
        guard model.lock.relock(autoPrompt: autoPrompt) else { return }
        guard let save else { return }
        save { [weak model, weak undoManager] in
            guard model?.lock.isShowingLockScreen == true else { return }
            undoManager?.removeAllActions()
        }
    }

    /// After locking: save now (encrypted), then remove the file's other
    /// versions (macOS Versions / iCloud), which still hold plaintext.
    @MainActor
    static func saveAndPurgeVersions(of model: MindMapModel, documentURL: URL?,
                                     save: ((@escaping () -> Void) -> Void)?) {
        guard let save else { return }
        save {
            guard let url = documentURL else { return }
            DispatchQueue.global(qos: .utility).async {
                let coordinator = NSFileCoordinator(filePresenter: nil)
                coordinator.coordinate(writingItemAt: url, options: [], error: nil) { url in
                    try? NSFileVersion.removeOtherVersionsOfItem(at: url)
                }
            }
        }
    }
}

/// Alerts of the gate.
enum LockAlert: Identifiable, Equatable {
    case confirmLockMap(title: String)
    case noteInfo(UUID)
    case message(String, String)

    static let thisDeviceMessage =
        "The key is stored in this Mac's keychain only: this build is not signed with your team, so iCloud Keychain cannot sync it and other devices cannot open it yet. See REPORT.md (WP12)."

    var id: String {
        switch self {
        case .confirmLockMap: return "lockMap"
        case let .noteInfo(id): return "note-\(id)"
        case let .message(title, text): return "msg-\(title)-\(text)"
        }
    }

    var title: String {
        switch self {
        case let .confirmLockMap(title): return "Lock “\(title)”?"
        case .noteInfo: return "Lock Note?"
        case let .message(title, _): return title
        }
    }

    func message(methodName: String) -> String {
        switch self {
        case .confirmLockMap:
            return "The map, its notes and files are encrypted on disk. Opening it needs \(methodName) or your device passcode / Mac password. The key is kept in your iCloud Keychain so your other devices can open it. There is no recovery key: without your iCloud Keychain the map cannot be opened."
        case .noteInfo:
            return "The note is encrypted on disk. Obsidian and other apps can no longer read it. Opening it needs \(methodName) or your device passcode / Mac password; the key is kept in your iCloud Keychain."
        case let .message(_, text):
            return text
        }
    }
}

struct LockModelKey: FocusedValueKey {
    typealias Value = MindMapModel
}

extension FocusedValues {
    /// Model of the focused map window (File menu lock items).
    var lockModel: MindMapModel? {
        get { self[LockModelKey.self] }
        set { self[LockModelKey.self] = newValue }
    }
}
