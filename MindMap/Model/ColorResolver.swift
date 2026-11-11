import Foundation

/// Pure resolver for node colors. Precedence per node:
/// `customColor` > `colorTag.hex` > theme color of its branch.
/// Overrides apply to that node only; "apply to branch" sets them on every
/// node of the branch. Descendants inherit the branch's theme color.
enum ColorResolver {
    static func effectiveColors(in map: MindMap) -> [UUID: String] {
        var result: [UUID: String] = [:]
        let rootTheme: String
        switch map.theme {
        case .rainbow: rootTheme = ColorTheme.rootColorHex
        case let .mono(hex): rootTheme = hex
        }
        result[map.root.id] = own(map.root) ?? rootTheme
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
        switch theme {
        case .rainbow:
            let palette = ColorTheme.rainbowPalette
            return palette[branchIndex % palette.count]
        case let .mono(hex):
            return hex
        }
    }

    private static func own(_ node: Node) -> String? {
        node.customColor ?? node.colorTag.hex
    }

    private static func visit(_ node: Node, themeColor: String, into result: inout [UUID: String]) {
        result[node.id] = own(node) ?? themeColor
        for child in node.children { visit(child, themeColor: themeColor, into: &result) }
    }
}
