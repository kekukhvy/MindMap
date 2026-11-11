import CoreGraphics
import SwiftUI

enum TopicFill: Equatable {
    /// Filled with the branch color (root, main topics).
    case solid
    /// Light tint of the branch color with a colored border (boxed subtopics).
    case tint
    /// No background (underline / plain text).
    case none
}

enum TopicWeight: Hashable {
    case regular, semibold, bold

    var fontWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

/// Resolved visual style of one topic (pure, XMind-like defaults).
/// Levels: 0 = central topic, 1 = main topics and floating topics, 2+ = subtopics.
struct NodeAppearance: Equatable {
    var level: Int
    var shape: NodeShape
    var fill: TopicFill
    var colorHex: String
    var fontSize: CGFloat
    var weight: TopicWeight
    var paddingH: CGFloat
    var paddingV: CGFloat
    /// nil = no border drawn. For `.underline` it is the underline's style.
    var border: BorderStyle?

    static let underlineWidth: CGFloat = 2

    static func resolve(shape explicitShape: NodeShape?, border explicitBorder: BorderStyle?,
                        level: Int, colorHex: String) -> NodeAppearance {
        let shape = explicitShape ?? NodeShape.defaultShape(forDepth: level)
        let isBox = shape == .roundedRect || shape == .rectangle || shape == .capsule
        let fill: TopicFill = isBox ? (level <= 1 ? .solid : .tint) : .none
        let fontSize: CGFloat, weight: TopicWeight
        var paddingH: CGFloat, paddingV: CGFloat
        switch level {
        case 0: (fontSize, weight, paddingH, paddingV) = (22, .bold, 24, 14)
        case 1: (fontSize, weight, paddingH, paddingV) = (16, .semibold, 16, 9)
        default: (fontSize, weight, paddingH, paddingV) = (14, .regular, isBox ? 12 : 6, isBox ? 6 : 4)
        }
        if shape == .capsule { paddingH += 8 }
        if shape == .underline { paddingV += underlineWidth / 2 }
        let border: BorderStyle?
        switch fill {
        case .solid: border = explicitBorder
        case .tint: border = explicitBorder ?? .solid
        case .none: border = shape == .plainText ? explicitBorder : (explicitBorder ?? .solid)
        }
        return NodeAppearance(level: level, shape: shape, fill: fill, colorHex: colorHex, fontSize: fontSize,
                              weight: weight, paddingH: paddingH, paddingV: paddingV, border: border)
    }

    /// Text drawn on a solid fill uses white or dark text by contrast.
    var usesDarkTextOnFill: Bool { HexColor.prefersDarkText(on: colorHex) }

    var cornerRadius: CGFloat { level == 0 ? 10 : 7 }
}
