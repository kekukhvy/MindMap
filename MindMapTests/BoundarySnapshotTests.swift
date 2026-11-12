import SwiftUI
import Testing
@testable import MindMap

/// Reference renders of boundaries over topics of different branches and
/// of a multi-selection (macOS: PNGs in the app container temp dir, copies
/// in Tools/preview/boundary-*.png).
@MainActor
struct BoundarySnapshotTests {
    struct Sample {
        var map: MindMap
        var pricing: UUID, mobile: UUID, launch: UUID, api: UUID, campaigns: UUID
    }

    static func sample() -> Sample {
        let pricing = Node(text: "Pricing"), launch = Node(text: "Launch plan")
        let api = Node(text: "Public API"), mobile = Node(text: "Mobile app", children: [Node(text: "iPad"),
                                                                                           Node(text: "iPhone")])
        let campaigns = Node(text: "Campaigns")
        let root = Node(text: "Q3 Planning", layoutStyle: .rightMap, children: [
            Node(text: "Product", children: [Node(text: "Roadmap"), pricing, Node(text: "Research"), launch]),
            Node(text: "Engineering", children: [api, Node(text: "Infrastructure"), mobile, Node(text: "QA")]),
            Node(text: "Marketing", children: [campaigns, Node(text: "Website")])
        ])
        var map = MindMap(root: root)
        map.boundaries = [
            // Non-adjacent topics of two branches.
            Boundary(memberIDs: [pricing.id, mobile.id], label: "Q3 focus"),
            // Adjacent across branches: one rectangle.
            Boundary(memberIDs: [launch.id, api.id], label: "Release", colorHex: "#3D8FE0")
        ]
        return Sample(map: map, pricing: pricing.id, mobile: mobile.id, launch: launch.id, api: api.id,
                      campaigns: campaigns.id)
    }

    @Test func renderCrossBranchBoundary() throws {
        let sample = Self.sample()
        try LayoutSnapshotTests.render(sample.map, name: "boundary-cross-branch") { editor in
            let layout = editor.scene.layout
            let zone = layout.boundaries[sample.map.boundaries[0].id]
            let release = layout.boundaries[sample.map.boundaries[1].id]
            #expect(zone?.isRectangle == false)
            #expect(release?.isRectangle == true)
            // Multi-selection shown: two topics, Campaigns primary.
            editor.setSelection([sample.campaigns, sample.api], primary: sample.campaigns)
        }
    }

    /// Balanced map: members on both sides of the central topic.
    @Test func renderBoundaryAcrossSides() throws {
        let left = Node(text: "Left idea"), right = Node(text: "Right idea")
        let root = Node(text: "Central Topic", children: [
            Node(text: "Main Topic", children: [right, Node(text: "Subtopic")]),
            Node(text: "Main Topic", children: [Node(text: "Subtopic")]),
            Node(text: "Main Topic", children: [left]),
            Node(text: "Main Topic")
        ])
        var map = MindMap(root: root)
        map.boundaries = [Boundary(memberIDs: [right.id, left.id], label: "Linked")]
        try LayoutSnapshotTests.render(map, name: "boundary-both-sides") { editor in
            let outline = editor.scene.layout.boundaries[map.boundaries[0].id]
            #expect(outline != nil)
            for id in [left.id, right.id] {
                if let frame = editor.scene.layout.frames[id] {
                    #expect(outline?.contains(CGPoint(x: frame.midX, y: frame.midY)) == true)
                }
            }
        }
    }
}
