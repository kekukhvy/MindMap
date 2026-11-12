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

    /// - Parameter minWidth: lower bound (topic text keeps a clickable width;
    ///   short badge texts such as "!" pass 0).
    func textSize(_ text: String, fontSize: CGFloat, weight: TopicWeight,
                  minWidth: CGFloat = NodeMeasurer.minTextWidth) -> CGSize {
        let key = Key(text: text, fontSize: fontSize, weight: weight)
        let raw: CGSize
        if let cached = cache[key] {
            raw = cached
        } else {
            let font = PlatformFont.systemFont(ofSize: fontSize, weight: NodeMeasurer.platformWeight(weight))
            let rect = NodeMeasurer.bounds(text.isEmpty ? " " : text, font: font)
            let maxHeight = ceil(NodeMeasurer.bounds(
                Array(repeating: "X", count: NodeMeasurer.maxLines).joined(separator: "\n"), font: font).height)
            // +2: slack so SwiftUI never wraps a line the measurement kept whole.
            raw = CGSize(width: ceil(rect.width) + 2, height: min(ceil(rect.height), maxHeight))
            if cache.count > 10_000 { cache.removeAll() }
            cache[key] = raw
        }
        return CGSize(width: max(raw.width, minWidth), height: raw.height)
    }

    private static func bounds(_ text: String, font: PlatformFont) -> CGRect {
        (text as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
    }

    /// Task checkbox + priority, link icon (leading) + text + due chip +
    /// attachment icon row (trailing) + shape padding.
    func nodeSize(text: String, appearance: NodeAppearance, attachments: [AttachmentSummary] = [],
                  hasLink: Bool = false, task: TaskSummary? = nil) -> CGSize {
        let fontSize = appearance.fontSize
        let text = textSize(text, fontSize: appearance.fontSize, weight: appearance.weight)
        let items = AttachmentIconRow.items(attachments)
        let icons = AttachmentIconRow.width(items, fontSize: fontSize)
        let link = hasLink ? LinkIconMetrics.width(fontSize: fontSize) : 0
        let taskWidth = task.map {
            TaskBadgeMetrics.leadingWidth($0, fontSize: fontSize) + TaskBadgeMetrics.trailingWidth($0, fontSize: fontSize)
        } ?? 0
        var height = text.height
        if !items.isEmpty { height = max(height, AttachmentIconRow.iconSize(fontSize: fontSize)) }
        if hasLink { height = max(height, LinkIconMetrics.iconSize(fontSize: fontSize)) }
        if let task { height = max(height, TaskBadgeMetrics.minHeight(task, fontSize: fontSize)) }
        return CGSize(width: taskWidth + link + text.width + icons + 2 * appearance.paddingH,
                      height: height + 2 * appearance.paddingV)
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
