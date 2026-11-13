import SwiftUI

/// "Lock Editing" toolbar toggle (WP15): a native button-style toggle with
/// lock.open / lock.fill, highlighted while the map is read-only. The same
/// switch is Edit ▸ Lock Editing (⌥⌘L) in the menu bar.
struct ReadOnlyToggle: View {
    static let title = "Lock Editing"
    static let shortcut = KeyboardShortcut("l", modifiers: [.command, .option])
    static let lockHelp = "Lock editing (⌥⌘L): the map becomes read-only — select, fold, follow links and read notes, no changes"
    static let unlockHelp = "Editing is locked — click to unlock (⌥⌘L)"

    let editor: EditorController

    var body: some View {
        let locked = editor.isReadOnly
        Toggle(isOn: Binding(get: { editor.isReadOnly }, set: { editor.setReadOnly($0) })) {
            Label(Self.title, systemImage: locked ? "lock.fill" : "lock.open")
        }
        .toggleStyle(.button)
        .help(locked ? Self.unlockHelp : Self.lockHelp)
        .accessibilityValue(locked ? "On" : "Off")
    }
}

/// Brief notice over the canvas when an edit is refused on a read-only map
/// (non-modal; hides by itself, `EditorController.showReadOnlyNotice`).
struct ReadOnlyNoticeView: View {
    let editor: EditorController

    var body: some View {
        if editor.readOnlyNotice != nil {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                Text(EditorController.readOnlyMessage)
                    .font(.callout.weight(.medium))
                Button("Unlock") { editor.unlockFromNotice() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Header line of an attachment viewer on a read-only map: says why
/// nothing can be typed / drawn / renamed / deleted.
struct ReadOnlyAttachmentBanner: View {
    var body: some View {
        Label("Read Only — editing of this map is locked", systemImage: "lock.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .help("Unlock editing in the map's toolbar (⌥⌘L) to change it")
    }
}
