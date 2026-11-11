import Foundation

/// How a node arranges its descendants. Stored per node; `nil` on a node
/// means "inherit from the nearest ancestor" (root default: `.balancedMap`).
enum LayoutStyle: String, Codable, CaseIterable {
    /// Children split left/right of the node (XMind "Mind Map").
    /// Applies only on the node where it is set; descendants continue
    /// as `.rightMap` / `.leftMap` on their side.
    case balancedMap
    /// All children to the right (logic chart right).
    case rightMap
    /// All children to the left, mirrored (logic chart left).
    case leftMap
    /// Children stacked below the parent, indented (MindManager tree chart).
    case treeDown
    /// Children in a row below the parent, centered (org chart).
    case orgChartDown

    static let rootDefault: LayoutStyle = .balancedMap
}
