import SwiftUI

/// Find bar over the canvas (⌘F): phrase field, "n of m", previous / next, close.
struct FindBar: View {
    @Bindable var editor: EditorController
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        if editor.isFindOpen {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in topics and notes", text: $editor.findQuery)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 180)
                        .focused($isFieldFocused)
                        .onSubmit { editor.submitFind() }
                    Text(countText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Previous Match", systemImage: "chevron.up") { editor.stepFind(forward: false) }
                    Button("Next Match", systemImage: "chevron.down") { editor.stepFind(forward: true) }
                    Button("Close Find", systemImage: "xmark.circle.fill") { editor.closeFind() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                if let match = editor.currentFindMatch, match.noteID != nil {
                    Label(match.snippet.isEmpty ? "Note" : match.snippet, systemImage: "note.text")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.top, 10)
            .onAppear { isFieldFocused = true }
            .onChange(of: editor.findFocusToken) { isFieldFocused = true }
            .onChange(of: isFieldFocused) { _, focused in editor.isFindFieldFocused = focused }
            .onDisappear { editor.isFindFieldFocused = false }
            .onChange(of: editor.model.map) { editor.refreshFind() }
            .onKeyPress(.escape) { editor.closeFind(); return .handled }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var countText: String {
        editor.findMatches.isEmpty ? "0 of 0" : "\(editor.findIndex + 1) of \(editor.findMatches.count)"
    }
}
