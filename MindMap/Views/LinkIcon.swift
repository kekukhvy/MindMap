import SwiftUI

/// What a topic shows of its link: the icon before the title + tooltip.
struct LinkSummary: Equatable {
    enum Kind: Equatable {
        case web, topic
    }

    var kind: Kind
    /// Topic link whose target was deleted (icon dimmed).
    var isBroken: Bool
    /// macOS hover text: the URL, the target's path or the broken notice.
    var tooltip: String

    static let brokenMessage = "Target topic was deleted"

    init(kind: Kind, isBroken: Bool, tooltip: String) {
        self.kind = kind
        self.isBroken = isBroken
        self.tooltip = tooltip
    }

    /// Summary of `id`'s link in `map` (nil without a link).
    init?(of node: Node, in map: MindMap) {
        guard let resolved = map.resolvedLink(of: node.id) else { return nil }
        switch resolved {
        case let .web(url):
            self.init(kind: .web, isBroken: false, tooltip: url.absoluteString)
        case let .topic(target):
            self.init(kind: .topic, isBroken: false, tooltip: map.breadcrumb(to: target) ?? "")
        case .brokenTopic:
            self.init(kind: .topic, isBroken: true, tooltip: LinkSummary.brokenMessage)
        }
    }

    var systemImage: String {
        switch kind {
        case .web: return "link"
        case .topic: return "arrow.turn.down.right"
        }
    }
}

/// Pure metrics of the link icon at a topic's leading edge (map points at
/// zoom 1). `NodeMeasurer` adds `width` so the layout reserves it.
enum LinkIconMetrics {
    static func iconSize(fontSize: CGFloat) -> CGFloat { AttachmentIconRow.iconSize(fontSize: fontSize) }
    /// Gap between the icon and the title.
    static func trailingGap(fontSize: CGFloat) -> CGFloat { max(3, (fontSize * 0.3).rounded()) }
    static func width(fontSize: CGFloat) -> CGFloat { iconSize(fontSize: fontSize) + trailingGap(fontSize: fontSize) }
}

/// The link icon drawn inside a topic before its title, in the text color.
/// Tap / click = Go to (opens the URL or jumps to the linked topic).
struct LinkIconView: View {
    let link: LinkSummary
    let fontSize: CGFloat
    let scale: CGFloat
    let color: Color
    let onFollow: () -> Void

    var body: some View {
        let size = LinkIconMetrics.iconSize(fontSize: fontSize) * scale
        Button(action: onFollow) {
            Image(systemName: link.systemImage)
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .foregroundStyle(color.opacity(link.isBroken ? 0.3 : 0.85))
                .frame(width: size * 0.82, height: size * 0.82)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(link.tooltip)
        .accessibilityLabel(link.isBroken ? "Broken link" : (link.kind == .web ? "Open link" : "Go to linked topic"))
        .padding(.trailing, LinkIconMetrics.trailingGap(fontSize: fontSize) * scale)
    }
}
