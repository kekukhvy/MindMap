import CoreGraphics
import Foundation
import Testing
@testable import MindMap

struct PersistenceTests {
    private func sampleMap() -> MindMap {
        var root = TestTree.node("Central", children: [
            TestTree.node("Services", style: .treeDown, children: TestTree.leaves(2)),
            Node(text: "Ideas", isCollapsed: true, colorTag: .green, shape: .capsule, borderStyle: .dashed,
                 children: [Node(text: "x")], attachments: [Attachment()])
        ])
        root.layoutStyle = .balancedMap
        root.connectorStyle = .roundedElbow
        root.lineWidth = 2.5
        root.lineDash = .dotted
        root.customColor = "#112233"
        let a = root.children[0].id, b = root.children[1].id
        return MindMap(
            root: root,
            theme: .mono(hex: "#445566"),
            floatingTopics: [FloatingTopic(node: Node(text: "float", layoutStyle: .orgChartDown), position: CGPoint(x: 12, y: -40))],
            relationships: [Relationship(from: a, to: b, label: "rel", fromControlOffset: CGVector(dx: 1, dy: 2),
                                         style: RelationshipStyle(path: .straight, dash: .solid, startArrow: .dot))],
            boundaries: [Boundary(nodeID: a, siblingIDs: [b], label: "grp", colorHex: "#778899")]
        )
    }

    @Test func jsonRoundTrip() throws {
        let map = sampleMap()
        let decoded = try MindMapPackage.decode(MindMapPackage.encode(map))
        #expect(decoded == map)
    }

    @Test func packageRoundTripKeepsAttachmentsFolder() throws {
        let map = sampleMap()
        let wrapper = try MindMapPackage.fileWrapper(for: map)
        #expect(wrapper.isDirectory)
        #expect(wrapper.fileWrappers?["map.json"]?.isRegularFile == true)
        #expect(wrapper.fileWrappers?["attachments"]?.isDirectory == true)
        #expect(try MindMapPackage.read(wrapper) == map)

        // Write to disk and read back, as the document system would.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mindmap")
        defer { try? FileManager.default.removeItem(at: url) }
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        let reread = try FileWrapper(url: url)
        #expect(try MindMapPackage.read(reread) == map)
    }

    @Test func decodesMinimalLegacyJSON() throws {
        let id = UUID()
        let json = #"{"formatVersion":1,"root":{"id":"\#(id.uuidString)","text":"Old","children":[{"id":"\#(UUID().uuidString)"}]}}"#
        let map = try MindMapPackage.decode(Data(json.utf8))
        #expect(map.root.id == id)
        #expect(map.root.layoutStyle == nil)
        #expect(map.root.shape == nil)
        #expect(map.root.children.first?.text == "")
        #expect(map.theme == .rainbow)
        #expect(map.floatingTopics.isEmpty && map.relationships.isEmpty && map.boundaries.isEmpty)
    }

    @Test func unknownEnumValuesFallBack() throws {
        let json = #"{"formatVersion":1,"root":{"id":"\#(UUID().uuidString)","colorTag":"magenta","layoutStyle":"spiral","shape":"star"}}"#
        let map = try MindMapPackage.decode(Data(json.utf8))
        #expect(map.root.colorTag == ColorTag.none)
        #expect(map.root.layoutStyle == nil)
        #expect(map.root.shape == nil)
    }

    @Test func optionalFieldsOmittedWhenNil() throws {
        let data = try MindMapPackage.encode(MindMap(root: Node(text: "r")))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("layoutStyle"))
        #expect(!text.contains("shape"))
        #expect(!text.contains("borderStyle"))
        #expect(!text.contains("connectorStyle"))
        #expect(!text.contains("customColor"))
    }

    @Test func relationshipWithoutStyleGetsDefaults() throws {
        let json = #"{"id":"\#(UUID().uuidString)","fromNodeID":"\#(UUID().uuidString)","toNodeID":"\#(UUID().uuidString)"}"#
        let relationship = try JSONDecoder().decode(Relationship.self, from: Data(json.utf8))
        #expect(relationship.style == RelationshipStyle())
        #expect(relationship.label == nil)
    }

    @Test func documentTypeConformsToPackage() {
        #expect(UTTypeCheck.conformsToPackage)
    }
}

import UniformTypeIdentifiers

private enum UTTypeCheck {
    static var conformsToPackage: Bool { UTType.mindMap.conforms(to: .package) }
}
