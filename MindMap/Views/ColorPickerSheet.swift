import SwiftUI

/// Custom color chooser for a topic/branch or the single-color theme.
struct ColorPickerSheet: View {
    let request: ColorSheetRequest
    let onApply: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var color: Color

    init(request: ColorSheetRequest, onApply: @escaping (String) -> Void) {
        self.request = request
        self.onApply = onApply
        _color = State(initialValue: Color(hex: request.initialHex))
    }

    private var title: String {
        switch request.target {
        case .node(_, wholeBranch: false): return "Topic Color"
        case .node(_, wholeBranch: true): return "Branch Color"
        case .relationship: return "Relationship Color"
        case .boundary: return "Boundary Color"
        case .theme: return "Map Color"
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(title).font(.headline)
            ColorPicker("Color", selection: $color, supportsOpacity: false)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Apply") {
                    if let hex = HexColor.string(from: color) { onApply(hex) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 280)
        .presentationDetents([.height(220)])
    }
}
