import Foundation

/// Map-level color theme. Colors are "#RRGGBB" hex strings (views convert).
enum ColorTheme: Codable, Equatable {
    /// "XMind Pastel" (default): each main branch (root child / floating
    /// topic) takes the next soft pastel color; its whole subtree inherits it.
    /// (Case name kept for file compatibility: older maps saved "rainbow".)
    case rainbow
    /// "Classic Rainbow": the earlier saturated palette, same per-branch rule.
    case classic
    /// Every branch uses the same color.
    case mono(hex: String)

    /// XMind Pastel palette, in the order branches are added.
    static let rainbowPalette = ["#EE7471", "#F2A16D", "#8BCBF1", "#9EDFD5", "#A3D3B5",
                                 "#B9A9E6", "#F5D27A", "#F2A7C3"]
    static let classicPalette = ["#E8524A", "#F59B2B", "#F2C94C", "#4CB97A", "#3D8FE0", "#8E62D9", "#E0629B"]
    /// Graphite: classic central topic color and generic fallback.
    static let rootColorHex = "#2F3640"
    /// Near-black central topic / main topic text of the pastel theme.
    static let inkHex = "#1E1E1E"

    var palette: [String]? {
        switch self {
        case .rainbow: return ColorTheme.rainbowPalette
        case .classic: return ColorTheme.classicPalette
        case .mono: return nil
        }
    }

    /// Color of the central topic.
    var rootHex: String {
        switch self {
        case .rainbow: return ColorTheme.inkHex
        case .classic: return ColorTheme.rootColorHex
        case let .mono(hex): return hex
        }
    }
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
