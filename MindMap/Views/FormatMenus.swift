import SwiftUI

/// Menu item with a checkmark when `checked`.
struct CheckItem: View {
    let title: String
    let checked: Bool
    let action: () -> Void

    init(_ title: String, checked: Bool, action: @escaping () -> Void) {
        self.title = title
        self.checked = checked
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

extension LayoutStyle {
    var title: String {
        switch self {
        case .balancedMap: return "Map"
        case .rightMap: return "Logic Right"
        case .leftMap: return "Logic Left"
        case .treeDown: return "Tree Down"
        case .orgChartDown: return "Org Chart"
        }
    }

    /// Small menu icon (SF Symbol).
    var systemImage: String {
        switch self {
        case .balancedMap: return "arrow.left.and.right"
        case .rightMap: return "arrow.right"
        case .leftMap: return "arrow.left"
        case .treeDown: return "list.bullet.indent"
        case .orgChartDown: return "rectangle.3.group"
        }
    }

    /// One-line explanation (help tags).
    var summary: String {
        switch self {
        case .balancedMap: return "Branches on both sides"
        case .rightMap: return "All branches to the right"
        case .leftMap: return "All branches to the left"
        case .treeDown: return "Topics hang below, one under another"
        case .orgChartDown: return "Topics in a row below"
        }
    }
}

/// "Layout" submenu for one topic: Inherit + one item per style with its
/// icon and a checkmark on the current choice (inline picker). Choosing a
/// style re-lays out the topic's children at once (one undo step).
struct LayoutStyleMenu: View {
    let editor: EditorController
    let id: UUID

    var body: some View {
        let current = editor.model.map.node(withID: id)?.layoutStyle
        Menu {
            Picker("Layout", selection: Binding(get: { current }, set: { editor.setLayoutStyle($0, for: id) })) {
                Label("Inherit from Parent", systemImage: "arrow.turn.left.up").tag(LayoutStyle?.none)
                ForEach(LayoutStyle.allCases, id: \.self) { style in
                    Label(style.title, systemImage: style.systemImage)
                        .tag(LayoutStyle?.some(style))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Layout", systemImage: (current ?? .treeDown).systemImage)
        }
    }
}

extension NodeShape {
    var title: String {
        switch self {
        case .roundedRect: return "Rounded Rectangle"
        case .rectangle: return "Rectangle"
        case .capsule: return "Capsule"
        case .underline: return "Underline"
        case .plainText: return "No Border (Text)"
        }
    }
}

extension ConnectorStyle {
    var title: String {
        switch self {
        case .curved: return "Curved"
        case .straight: return "Straight"
        case .elbow: return "Elbow"
        case .roundedElbow: return "Rounded Elbow"
        }
    }
}

extension LineDash {
    var title: String { rawValue.capitalized }
}

/// Format submenus for one topic (context menu and toolbar Format menu).
/// Every item is a single undo step via `MindMapModel`.
struct NodeFormatMenus: View {
    let editor: EditorController
    let id: UUID
    /// The context menu shows Layout higher up, on its own.
    var includesLayout = true

    private var model: MindMapModel { editor.model }
    private var undo: UndoManager? { editor.undoManager }
    private var node: Node? { model.map.node(withID: id) }

    var body: some View {
        if let node {
            if includesLayout { LayoutStyleMenu(editor: editor, id: id) }
            shapeMenu(node)
            borderMenu(node)
            colorMenu(node)
            lineMenu(node)
        }
    }

    private func shapeItems(_ node: Node, wholeBranch: Bool) -> some View {
        Group {
            CheckItem("Default", checked: !wholeBranch && node.shape == nil) {
                model.setShape(nil, for: id, wholeBranch: wholeBranch, undoManager: undo)
            }
            ForEach(NodeShape.allCases, id: \.self) { shape in
                CheckItem(shape.title, checked: !wholeBranch && node.shape == shape) {
                    model.setShape(shape, for: id, wholeBranch: wholeBranch, undoManager: undo)
                }
            }
        }
    }

    private func shapeMenu(_ node: Node) -> some View {
        Menu("Shape") {
            shapeItems(node, wholeBranch: false)
            Divider()
            Menu("Apply to Branch") { shapeItems(node, wholeBranch: true) }
        }
    }

    private func borderItems(_ node: Node, wholeBranch: Bool) -> some View {
        Group {
            CheckItem("Default", checked: !wholeBranch && node.borderStyle == nil) {
                model.setBorderStyle(nil, for: id, wholeBranch: wholeBranch, undoManager: undo)
            }
            ForEach(BorderStyle.allCases, id: \.self) { style in
                CheckItem(style.rawValue.capitalized, checked: !wholeBranch && node.borderStyle == style) {
                    model.setBorderStyle(style, for: id, wholeBranch: wholeBranch, undoManager: undo)
                }
            }
        }
    }

    private func borderMenu(_ node: Node) -> some View {
        Menu("Border") {
            borderItems(node, wholeBranch: false)
            Divider()
            Menu("Apply to Branch") { borderItems(node, wholeBranch: true) }
        }
    }

    private func colorItems(_ node: Node, wholeBranch: Bool) -> some View {
        Group {
            ForEach(ColorPresets.all, id: \.hex) { preset in
                CheckItem(preset.name, checked: !wholeBranch && node.customColor == preset.hex) {
                    model.setCustomColor(preset.hex, for: id, wholeBranch: wholeBranch, undoManager: undo)
                }
            }
            Button("Custom…") {
                let current = ColorResolver.effectiveColor(of: id, in: model.map) ?? ColorTheme.rootColorHex
                editor.colorSheet = ColorSheetRequest(target: .node(id, wholeBranch: wholeBranch),
                                                      initialHex: current)
            }
            Divider()
            Button("Reset to Theme") { editor.resetColor(id, wholeBranch: wholeBranch) }
        }
    }

    private func colorMenu(_ node: Node) -> some View {
        Menu("Color") {
            colorItems(node, wholeBranch: false)
            Divider()
            Menu("Apply to Branch") { colorItems(node, wholeBranch: true) }
        }
    }

    private func lineMenu(_ node: Node) -> some View {
        Menu("Branch Line") {
            Menu("Style") {
                CheckItem("Inherit", checked: node.connectorStyle == nil) {
                    model.setConnectorStyle(nil, for: id, undoManager: undo)
                }
                ForEach(ConnectorStyle.allCases, id: \.self) { style in
                    CheckItem(style.title, checked: node.connectorStyle == style) {
                        model.setConnectorStyle(style, for: id, undoManager: undo)
                    }
                }
            }
            Menu("Width") {
                CheckItem("Inherit", checked: node.lineWidth == nil) {
                    model.setLineWidth(nil, for: id, undoManager: undo)
                }
                ForEach([1.0, 1.5, 2, 3, 4], id: \.self) { width in
                    CheckItem(width.formatted() + " pt", checked: node.lineWidth == width) {
                        model.setLineWidth(width, for: id, undoManager: undo)
                    }
                }
            }
            Menu("Dash") {
                CheckItem("Inherit", checked: node.lineDash == nil) {
                    model.setLineDash(nil, for: id, undoManager: undo)
                }
                ForEach(LineDash.allCases, id: \.self) { dash in
                    CheckItem(dash.title, checked: node.lineDash == dash) {
                        model.setLineDash(dash, for: id, undoManager: undo)
                    }
                }
            }
        }
    }
}

/// Map color theme menu items.
struct ThemeMenuItems: View {
    let editor: EditorController

    var body: some View {
        let theme = editor.model.map.theme
        CheckItem("XMind Pastel", checked: theme == .rainbow) {
            editor.model.setTheme(.rainbow, undoManager: editor.undoManager)
        }
        CheckItem("Classic Rainbow", checked: theme == .classic) {
            editor.model.setTheme(.classic, undoManager: editor.undoManager)
        }
        Menu("Single Color") {
            ForEach(ColorPresets.all, id: \.hex) { preset in
                CheckItem(preset.name, checked: theme == .mono(hex: preset.hex)) {
                    editor.model.setTheme(.mono(hex: preset.hex), undoManager: editor.undoManager)
                }
            }
            Divider()
            Button("Custom…") {
                let current: String
                if case let .mono(hex) = theme { current = hex } else { current = ColorPresets.all[4].hex }
                editor.colorSheet = ColorSheetRequest(target: .theme, initialHex: current)
            }
        }
    }
}
