import Foundation

/// Map-level color theme. Colors are "#RRGGBB" hex strings (views convert).
enum ColorTheme: Codable, Equatable {
    /// Each main branch (root child / floating topic) takes the next palette
    /// color; its whole subtree inherits it.
    case rainbow
    /// Every branch uses the same color.
    case mono(hex: String)

    static let rainbowPalette = ["#E8524A", "#F59B2B", "#F2C94C", "#4CB97A", "#3D8FE0", "#8E62D9", "#E0629B"]
    static let rootColorHex = "#2F3640"
}

extension ColorTag {
    /// Hex for semantic tags; nil for `.none` (= use theme).
    var hex: String? {
        switch self {
        case .none: return nil
        case .red: return "#E8524A"
        case .orange: return "#F59B2B"
        case .yellow: return "#F2C94C"
        case .green: return "#4CB97A"
        case .blue: return "#3D8FE0"
        case .purple: return "#8E62D9"
        case .gray: return "#8E8E93"
        }
    }
}
