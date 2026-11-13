import SwiftUI

/// Compact "Gestures" help (iPad): shown once on first launch and from the
/// toolbar "…" menu / Help menu. Content is pure data (`GestureHelp.sections`).
enum GestureHelp {
    struct Row: Identifiable, Equatable {
        var systemImage: String
        var gesture: String
        var action: String
        var id: String { gesture }
    }

    struct Section: Identifiable, Equatable {
        var title: String
        var rows: [Row]
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Touch", rows: [
            Row(systemImage: "hand.tap", gesture: "Tap a topic",
                action: "Select it, fold or unfold its branch, show the action bar"),
            Row(systemImage: "hand.tap.fill", gesture: "Double-tap a topic", action: "Add a child inside and name it"),
            Row(systemImage: "plus.circle.fill", gesture: "Tap +", action: "Add a child topic"),
            Row(systemImage: "plus.forwardslash.minus", gesture: "Tap +N or −", action: "Unfold or fold the branch"),
            Row(systemImage: "hand.point.up.left", gesture: "Long-press a topic", action: "All topic actions"),
            Row(systemImage: "character.cursor.ibeam", gesture: "Rename",
                action: "Edit in the action bar, Rename in the long-press menu, or write on it"),
            Row(systemImage: "plus.rectangle", gesture: "Sibling topic",
                action: "Sibling in the action bar or menu, or the toolbar button"),
            Row(systemImage: "link", gesture: "Tap a link icon",
                action: "Open the link (web page, topic or map); also Link › Go to in the menu"),
            Row(systemImage: "arrow.up.and.down.and.arrow.left.and.right", gesture: "Drag a topic",
                action: "Move it onto another topic, between siblings or anywhere"),
            Row(systemImage: "hand.draw", gesture: "Drag empty canvas", action: "Pan"),
            Row(systemImage: "arrow.up.left.and.arrow.down.right", gesture: "Pinch", action: "Zoom"),
            Row(systemImage: "rectangle.dashed", gesture: "Double-tap empty canvas", action: "Floating topic there"),
            Row(systemImage: "hand.tap", gesture: "Tap empty canvas", action: "Deselect"),
            Row(systemImage: "checkmark.circle", gesture: "Select (toolbar)",
                action: "Tap several topics or drag an area, then act on all"),
        ]),
        Section(title: "Apple Pencil", rows: [
            Row(systemImage: "pencil.and.scribble", gesture: "Write on a topic", action: "Rename it with Scribble"),
            Row(systemImage: "pencil", gesture: "Tap · double-tap", action: "Same as with a finger"),
            Row(systemImage: "pencil.tip", gesture: "Hover (iPad Pro)", action: "Highlight a topic and show its +"),
            Row(systemImage: "hand.pinch", gesture: "Squeeze (Pencil Pro)",
                action: "Action bar on a topic, Insert bar over empty canvas"),
            Row(systemImage: "pencil.tip.crop.circle.badge.plus", gesture: "Double-tap the Pencil",
                action: "Add a child to the selected topic (follows Settings › Apple Pencil)"),
            Row(systemImage: "scribble", gesture: "Handwritten notes", action: "Pencil draws, fingers scroll and zoom"),
        ]),
        Section(title: "Keyboard", rows: [
            Row(systemImage: "keyboard", gesture: "Tab · Return", action: "Child · sibling topic"),
            Row(systemImage: "keyboard", gesture: "Space or F2 · Delete", action: "Rename · delete"),
            Row(systemImage: "keyboard", gesture: "⌘Z · ⇧⌘Z", action: "Undo · redo"),
        ]),
    ]

    /// UserDefaults flag: the sheet was shown once.
    static let shownKey = "MindMap.didShowGestureHelp"

    /// First launch only; never in the test host or a DEBUG screenshot run.
    static func shouldShowOnLaunch(defaults: UserDefaults, environment: [String: String], isTesting: Bool) -> Bool {
        guard !isTesting, !defaults.bool(forKey: shownKey) else { return false }
        return !environment.keys.contains { $0.hasPrefix("MINDMAP_DEBUG_") }
    }
}

struct GestureHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                // Two columns (Touch | Pencil + Keyboard) when the sheet is wide.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        column(Array(GestureHelp.sections.prefix(1)))
                        column(Array(GestureHelp.sections.dropFirst()))
                    }
                    .frame(minWidth: 720)
                    column(GestureHelp.sections)
                }
                .padding(20)
            }
            .navigationTitle("Gestures")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func column(_ sections: [GestureHelp.Section]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    VStack(spacing: 0) {
                        ForEach(section.rows) { row in
                            rowView(row)
                            if row != section.rows.last { Divider().padding(.leading, 46) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.08)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func rowView(_ row: GestureHelp.Row) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(NodeView.selectionBlue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.gesture).font(.callout.weight(.medium))
                Text(row.action).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension View {
    /// Wide page sheet on iPad (two columns fit), large detent otherwise.
    @ViewBuilder
    func gestureHelpSizing() -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            presentationSizing(.page)
        } else {
            presentationDetents([.large])
        }
        #else
        self
        #endif
    }
}

#Preview {
    GestureHelpSheet()
}
