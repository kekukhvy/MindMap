import Foundation

/// Pure resolver for node colors. Precedence per node:
/// `customColor` > `colorTag.hex` > theme color of its branch.
/// Overrides apply to that node only; "apply to branch" sets them on every
/// node of the branch. Descendants inherit the branch's theme color.
enum ColorResolver {
    static func effectiveColors(in map: MindMap) -> [UUID: String] {
        var result: [UUID: String] = [:]
        result[map.root.id] = own(map.root) ?? map.theme.rootHex
        var branchIndex = 0
        let branches = map.root.children + map.floatingTopics.map(\.node)
        for branch in branches {
            visit(branch, themeColor: themeColor(map.theme, branchIndex: branchIndex), into: &result)
            branchIndex += 1
        }
        return result
    }

    static func effectiveColor(of id: UUID, in map: MindMap) -> String? {
        effectiveColors(in: map)[id]
    }

    static func themeColor(_ theme: ColorTheme, branchIndex: Int) -> String {
        guard let palette = theme.palette else { return theme.rootHex }
        return palette[branchIndex % palette.count]
    }

    private static func own(_ node: Node) -> String? {
        node.customColor ?? node.colorTag.hex
    }

    private static func visit(_ node: Node, themeColor: String, into result: inout [UUID: String]) {
        result[node.id] = own(node) ?? themeColor
        for child in node.children { visit(child, themeColor: themeColor, into: &result) }
    }
}
