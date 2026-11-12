import SwiftUI

extension ArrowHead {
    var title: String {
        switch self {
        case .none: return "None"
        case .arrow: return "Arrow"
        case .filledArrow: return "Filled Arrow"
        case .dot: return "Dot"
        case .diamond: return "Diamond"
        }
    }
}

extension RelationshipPathStyle {
    var title: String { rawValue.capitalized }
}

/// Context / Format menu of a relationship or boundary.
struct CanvasItemMenu: View {
    let editor: EditorController
    let item: CanvasItem

    var body: some View {
        Group {
            Button("Edit Label…", systemImage: "character.cursor.ibeam") { editor.beginLabelEdit(item) }
            switch item {
            case let .relationship(id):
                if let relationship = editor.relationship(id) {
                    RelationshipStyleMenus(editor: editor, relationship: relationship)
                }
            case let .boundary(id):
                if let boundary = editor.boundary(id) {
                    ItemColorMenu(editor: editor, current: boundary.colorHex, target: .boundary(id),
                                  defaultTitle: "Branch Color",
                                  apply: { editor.setBoundaryColor($0, for: id) })
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { editor.removeItem(item) }
        }
    }
}

/// Path, dash, arrowheads, width and color of a relationship (one undo step each).
private struct RelationshipStyleMenus: View {
    let editor: EditorController
    let relationship: Relationship

    private var id: UUID { relationship.id }
    private var style: RelationshipStyle { relationship.style }

    var body: some View {
        Menu("Path") {
            ForEach(RelationshipPathStyle.allCases, id: \.self) { path in
                CheckItem(path.title, checked: style.path == path) {
                    editor.updateRelationshipStyle(id) { $0.path = path }
                }
            }
            Divider()
            Button("Reset Curve") { editor.resetRelationshipCurve(id) }
                .disabled(relationship.fromControlOffset == nil && relationship.toControlOffset == nil)
        }
        Menu("Dash") {
            ForEach(LineDash.allCases, id: \.self) { dash in
                CheckItem(dash.title, checked: style.dash == dash) {
                    editor.updateRelationshipStyle(id) { $0.dash = dash }
                }
            }
        }
        arrowMenu("Start Arrow", current: style.startArrow) { head in
            editor.updateRelationshipStyle(id) { $0.startArrow = head }
        }
        arrowMenu("End Arrow", current: style.endArrow) { head in
            editor.updateRelationshipStyle(id) { $0.endArrow = head }
        }
        Menu("Width") {
            ForEach([1.0, 1.5, 2, 3, 4], id: \.self) { width in
                CheckItem(width.formatted() + " pt", checked: style.width == width) {
                    editor.updateRelationshipStyle(id) { $0.width = width }
                }
            }
        }
        ItemColorMenu(editor: editor, current: style.colorHex, target: .relationship(id), defaultTitle: "Default",
                      apply: { editor.setRelationshipColor($0, for: id) })
    }

    private func arrowMenu(_ title: String, current: ArrowHead, set: @escaping (ArrowHead) -> Void) -> some View {
        Menu(title) {
            ForEach(ArrowHead.allCases, id: \.self) { head in
                CheckItem(head.title, checked: current == head) { set(head) }
            }
        }
    }
}

/// Color presets + custom + default for a relationship / boundary.
private struct ItemColorMenu: View {
    let editor: EditorController
    let current: String?
    let target: ColorSheetRequest.Target
    let defaultTitle: String
    let apply: (String?) -> Void

    var body: some View {
        Menu("Color") {
            CheckItem(defaultTitle, checked: current == nil) { apply(nil) }
            Divider()
            ForEach(ColorPresets.all, id: \.hex) { preset in
                CheckItem(preset.name, checked: current == preset.hex) { apply(preset.hex) }
            }
            Button("Custom…") {
                editor.colorSheet = ColorSheetRequest(target: target,
                                                      initialHex: current ?? RelationshipsLayer.defaultColorHex)
            }
        }
    }
}

/// Insert items (toolbar, menus): floating topic, relationship, boundary,
/// note, handwritten note and file on the selected topic.
struct InsertMenuItems: View {
    let editor: EditorController

    var body: some View {
        let selected = editor.selectedID.flatMap { editor.scene.nodes[$0] != nil ? $0 : nil }
        Button("Floating Topic", systemImage: "rectangle.dashed") { editor.addFloatingTopic() }
        Button("Relationship", systemImage: "arrow.triangle.turn.up.right.diamond") {
            if let selected { editor.beginRelationship(from: selected) }
        }
        .disabled(selected == nil)
        Button("Boundary", systemImage: "square.dashed") {
            if let selected { editor.addBoundary(around: selected) }
        }
        .disabled(selected == nil || selected == editor.model.root.id)
        Divider()
        Button("Note", systemImage: "note.text.badge.plus") {
            if let selected { editor.addNote(to: selected) }
        }
        .disabled(selected == nil)
        Button("Handwritten Note", systemImage: "pencil.and.scribble") {
            if let selected { editor.addDrawing(to: selected) }
        }
        .disabled(selected == nil)
        Button("Attach File…", systemImage: "paperclip") {
            if let selected { editor.beginAttachFile(to: selected) }
        }
        .disabled(selected == nil)
    }
}
