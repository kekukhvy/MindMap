import SwiftUI

/// Inline editor of a relationship / boundary label, placed over the label
/// on the canvas. Return, Esc and focus loss commit; empty removes the label.
struct LabelEditorOverlay: View {
    @Bindable var editor: EditorController
    let viewport: Viewport

    var body: some View {
        if let item = editor.labelEditing, let point = anchor(for: item) {
            LabelEditorField(editor: editor, item: item, scale: viewport.scale)
                .position(point)
        }
    }

    /// Screen center of the field: the relationship's label point, or the
    /// boundary's top-left label tab.
    private func anchor(for item: CanvasItem) -> CGPoint? {
        switch item {
        case let .relationship(id):
            return editor.relationshipPath(id)?.transformed(by: viewport).labelPoint
        case let .boundary(id):
            guard let outline = editor.scene.layout.boundaries[id] else { return nil }
            let screen = viewport.toScreen(CGPoint(x: outline.labelOrigin.x, y: outline.labelOrigin.y))
            let size = LabelEditorField.size(scale: viewport.scale)
            return CGPoint(x: screen.x + 8 * viewport.scale + size.width / 2,
                           y: screen.y + 3 * viewport.scale + size.height / 2)
        }
    }
}

private struct LabelEditorField: View {
    @Bindable var editor: EditorController
    let item: CanvasItem
    let scale: CGFloat
    @FocusState private var isFocused: Bool

    static func size(scale: CGFloat) -> CGSize {
        CGSize(width: max(160 * scale, 120), height: max(22 * scale, 22))
    }

    var body: some View {
        let size = Self.size(scale: scale)
        TextField("Label", text: $editor.labelDraft)
            .textFieldStyle(.plain)
            .font(.system(size: max(12 * scale, 11)))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 6)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.canvasBackground))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1.5))
            .focused($isFocused)
            .onSubmit { editor.commitLabelEdit(ifEditing: item) }
            .onKeyPress(.escape) {
                editor.commitLabelEdit(ifEditing: item)
                return .handled
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { editor.commitLabelEdit(ifEditing: item) }
            }
            .task {
                isFocused = true
            }
    }
}
