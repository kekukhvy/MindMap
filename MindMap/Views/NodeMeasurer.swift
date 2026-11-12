import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
private typealias PlatformFont = NSFont
#else
import UIKit
private typealias PlatformFont = UIFont
#endif

/// Off-screen text measurement for node sizes (no SwiftUI layout feedback).
/// Cached by text + font; the views render the same system font and use the
/// measured frame, so layout is deterministic.
final class NodeMeasurer {
    static let maxTextWidth: CGFloat = 240
    static let minTextWidth: CGFloat = 16
    /// Longer texts are truncated in the node (full text in the editor),
    /// so topics stay compact.
    static let maxLines = 8

    private struct Key: Hashable {
        var text: String
        var fontSize: CGFloat
        var weight: TopicWeight
    }

    private var cache: [Key: CGSize] = [:]

    func textSize(_ text: String, fontSize: CGFloat, weight: TopicWeight) -> CGSize {
        let key = Key(text: text, fontSize: fontSize, weight: weight)
        if let cached = cache[key] { return cached }
        let font = PlatformFont.systemFont(ofSize: fontSize, weight: NodeMeasurer.platformWeight(weight))
        let rect = NodeMeasurer.bounds(text.isEmpty ? " " : text, font: font)
        let maxHeight = ceil(NodeMeasurer.bounds(
            Array(repeating: "X", count: NodeMeasurer.maxLines).joined(separator: "\n"), font: font).height)
        // +2: slack so SwiftUI never wraps a line the measurement kept whole.
        let size = CGSize(width: max(ceil(rect.width) + 2, NodeMeasurer.minTextWidth),
                          height: min(ceil(rect.height), maxHeight))
        if cache.count > 10_000 { cache.removeAll() }
        cache[key] = size
        return size
    }

    private static func bounds(_ text: String, font: PlatformFont) -> CGRect {
        (text as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
    }

    func nodeSize(text: String, appearance: NodeAppearance) -> CGSize {
        let text = textSize(text, fontSize: appearance.fontSize, weight: appearance.weight)
        return CGSize(width: text.width + 2 * appearance.paddingH, height: text.height + 2 * appearance.paddingV)
    }

    private static func platformWeight(_ weight: TopicWeight) -> PlatformFont.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }
}
