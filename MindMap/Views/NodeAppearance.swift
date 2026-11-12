import CoreGraphics
import SwiftUI

enum TopicFill: Equatable {
    /// Filled with the branch color (main topics; boxed central topic).
    case solid
    /// Very pale tint of the branch color, no border by default (boxed subtopics).
    case tint
    /// No background (plain text / underline).
    case none
}

enum TopicWeight: Hashable {
    case regular, medium, semibold, bold, heavy

    var fontWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }
}

/// Resolved visual style of one topic (pure, XMind pastel defaults).
/// Levels: 0 = central topic, 1 = main topics and floating topics, 2+ = subtopics.
/// Default look: central topic = heavy plain text; main topics = pastel filled
/// rounded rects with near-black text; level 2 = pale tint rounded rects with a
/// dark shade of the branch color as text; level 3+ = plain text in that shade.
struct NodeAppearance: Equatable {
    var level: Int
    var shape: NodeShape
    var fill: TopicFill
    /// Branch color (connectors, borders, underline, solid fill).
    var colorHex: String
    var fontSize: CGFloat
    var weight: TopicWeight
    var paddingH: CGFloat
    var paddingV: CGFloat
    /// nil = no border drawn. For `.underline` it is the underline's style.
    var border: BorderStyle?

    static let underlineWidth: CGFloat = 2
    /// Share of the branch color over white for `.tint` fills.
    static let tintAmount = 0.22
    /// Central topic size relative to main topics (XMind ≈ 1.55x).
    static let rootFontSize: CGFloat = 25
    static let mainFontSize: CGFloat = 16
    static let subFontSize: CGFloat = 12.5

    static func resolve(shape explicitShape: NodeShape?, border explicitBorder: BorderStyle?,
                        level: Int, colorHex: String) -> NodeAppearance {
        let shape = explicitShape ?? NodeShape.defaultShape(forDepth: level)
        let isBox = shape == .roundedRect || shape == .rectangle || shape == .capsule
        let fill: TopicFill = isBox ? (level <= 1 ? .solid : .tint) : .none
        let fontSize: CGFloat, weight: TopicWeight
        var paddingH: CGFloat, paddingV: CGFloat
        switch level {
        case 0: (fontSize, weight, paddingH, paddingV) = (rootFontSize, .heavy, isBox ? 24 : 4, isBox ? 14 : 3)
        case 1: (fontSize, weight, paddingH, paddingV) = (mainFontSize, .medium, isBox ? 16 : 4, isBox ? 9 : 3)
        default: (fontSize, weight, paddingH, paddingV) = (subFontSize, .regular, isBox ? 10 : 3, isBox ? 5.5 : 2)
        }
        if shape == .capsule { paddingH += 8 }
        if shape == .underline { paddingV += underlineWidth / 2 }
        let border: BorderStyle?
        switch fill {
        case .solid, .tint: border = explicitBorder
        case .none: border = shape == .plainText ? explicitBorder : (explicitBorder ?? .solid)
        }
        return NodeAppearance(level: level, shape: shape, fill: fill, colorHex: colorHex, fontSize: fontSize,
                              weight: weight, paddingH: paddingH, paddingV: paddingV, border: border)
    }

    /// Background color of the shape (nil = transparent).
    var fillHex: String? {
        switch fill {
        case .solid: return colorHex
        case .tint: return HexColor.tint(colorHex, amount: NodeAppearance.tintAmount)
        case .none: return nil
        }
    }

    /// Text color: on solid fills near-black or white by contrast; the
    /// central topic in its own color; subtopics in a dark shade of the branch.
    var textColorHex: String {
        switch fill {
        case .solid:
            return HexColor.prefersDarkText(on: colorHex) ? ColorTheme.inkHex : "#FFFFFF"
        case .tint, .none:
            return level == 0 ? colorHex : HexColor.darkShade(colorHex)
        }
    }

    var cornerRadius: CGFloat {
        switch level {
        case 0: return 10
        case 1: return 5
        default: return 4
        }
    }
}
