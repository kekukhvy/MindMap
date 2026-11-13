#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MindMap

/// Pictures of the Welcome Tour (WP13): the real canvas (`CanvasView` +
/// `ImageRenderer`, like `renderFeaturesSnapshot`) drawing parts of the
/// bundled "MindMap Features" sample, plus iPad simulator screenshots from
/// Tools/preview for the Pencil page. Written to `<tmp>/Tour/tour-N.png`;
/// `Tools/tour/generate.sh` runs this suite and copies them into the asset
/// catalog (TourN.imageset).
@MainActor
struct TourImageGenerator {
    static let size = CGSize(width: 1200, height: 720)
    static var outputFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Tour", isDirectory: true)
    }

    static func featuresMap() throws -> MindMap {
        let archive = try SampleMaps.archive(SampleMaps.featuresResource)
        return try MindMapPackage.decode(try #require(archive.files[MindMapPackage.mapFileName]))
    }

    /// The map with only the main branches in `keep` (in that order of the
    /// original), `collapse` collapsed; relationships / boundaries whose
    /// topics are gone are dropped.
    static func subset(_ map: MindMap, keep: [String]? = nil, collapse: Set<String> = [],
                       keepFloating: Bool = false) -> MindMap {
        var result = map
        if let keep {
            result.root.children = map.root.children.filter { keep.contains($0.text) }
        }
        for index in result.root.children.indices where collapse.contains(result.root.children[index].text) {
            result.root.children[index].isCollapsed = true
        }
        if !keepFloating { result.floatingTopics = [] }
        let visible = visibleIDs(result)
        result.relationships = result.relationships.filter { visible.contains($0.fromNodeID) && visible.contains($0.toNodeID) }
        result.boundaries = result.boundaries.compactMap { boundary in
            var boundary = boundary
            boundary.memberIDs = boundary.memberIDs.filter(visible.contains)
            return boundary.memberIDs.isEmpty ? nil : boundary
        }
        return result
    }

    /// A main branch of `map` as the central topic of its own map.
    static func branch(_ map: MindMap, _ text: String) throws -> MindMap {
        var node = try #require(map.root.children.first { $0.text == text })
        node.layoutStyle = nil
        node.manualPosition = nil
        var result = map
        result.root = node
        return subset(result)
    }

    static func visibleIDs(_ map: MindMap) -> Set<UUID> {
        var ids = Set<UUID>()
        func visit(_ node: Node) {
            ids.insert(node.id)
            if !node.isCollapsed { node.children.forEach(visit) }
        }
        visit(map.root)
        map.floatingTopics.forEach { visit($0.node) }
        return ids
    }

    static func ids(_ map: MindMap, _ texts: [String]) -> Set<UUID> {
        var result = Set<UUID>()
        func visit(_ node: Node) {
            if texts.contains(node.text) { result.insert(node.id) }
            node.children.forEach(visit)
        }
        visit(map.root)
        return result
    }

    /// The canvas showing `map` fitted into `size` (at most 1:1).
    static func canvas(_ map: MindMap, size: CGSize, selected: Set<UUID> = [], includePanel: Bool = false,
                       maxScale: CGFloat = 1.1) -> some View {
        let editor = EditorController(model: MindMapModel(map: map))
        editor.updateViewSize(size)
        let bounds = includePanel ? editor.contentBoundsIncludingPanel : editor.scene.layout.bounds
        editor.viewport = .fitting(bounds, in: size, margin: 36, maxScale: maxScale)
        if let first = selected.first {
            editor.select(first)
            editor.selectedIDs = selected
        }
        return CanvasView(editor: editor)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
    }

    /// iPad simulator screenshots copied from Tools/preview into
    /// `<tmp>/TourInput/` by the script (the test host is sandboxed).
    static func screenshot(_ name: String) throws -> NSImage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TourInput/\(name)")
        return try #require(NSImage(contentsOf: url), "run Tools/tour/generate.sh (copies \(name))")
    }

    /// The screenshot without its status bar (top `statusBar` fraction) and
    /// below `bottom` (fraction of the height).
    static func cropped(_ image: NSImage, statusBar: CGFloat = 0.032, bottom: CGFloat = 1) throws -> CGImage {
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let top = Int(CGFloat(cg.height) * statusBar)
        let rect = CGRect(x: 0, y: top, width: cg.width, height: Int(CGFloat(cg.height) * bottom) - top)
        return try #require(cg.cropping(to: rect))
    }

    /// An iPad screenshot in a simple device frame.
    static func device(_ image: NSImage, height: CGFloat) throws -> some View {
        let cg = try cropped(image)
        let aspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
        return Image(decorative: cg, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(aspect, contentMode: .fit)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 28).fill(Color(white: 0.12)))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    /// The top `fraction` of a screenshot as a rounded card.
    static func card(_ image: NSImage, top fraction: CGFloat, width: CGFloat) throws -> some View {
        let cropped = try cropped(image, bottom: fraction)
        let aspect = CGFloat(cropped.width) / CGFloat(cropped.height)
        return Image(decorative: cropped, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(aspect, contentMode: .fit)
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
    }

    /// Moves the Tasks panel out of the picture.
    static func hidingPanel(_ map: MindMap) -> MindMap {
        var map = map
        map.taskPanel = TaskPanelState(position: CGPoint(x: 100_000, y: 0))
        return map
    }

    static func write<V: View>(_ view: V, page: Int) throws -> URL {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let url = outputFolder.appendingPathComponent("tour-\(page).png")
        try png.write(to: url)
        print("TOUR \(url.path)")
        return url
    }

    /// Runs when the script copied the iPad screenshots (not in plain test runs).
    nonisolated static var hasInputs: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory
            .appendingPathComponent("TourInput/handwriting-ipad.png").path)
    }

    @Test(.enabled(if: TourImageGenerator.hasInputs, "run Tools/tour/generate.sh"))
    func renderTourPages() throws {
        let features = try Self.featuresMap()
        let size = Self.size

        // 1 The XMind-style map: all main branches, two layouts open.
        let overview = Self.hidingPanel(Self.subset(features, collapse: ["Editing & Keyboard", "Hotkeys", "Links", "Attachments",
                                                        "Documents & iCloud", "Tasks", "Known gaps / Roadmap",
                                                        "Structure", "Look & Format"]))
        _ = try Self.write(Self.canvas(overview, size: size), page: 1)

        // 2 Styles, shapes, themes: the "Look & Format" branch.
        _ = try Self.write(Self.canvas(try Self.branch(features, "Look & Format"), size: size), page: 2)

        // 3 Notes, handwriting, files: the Attachments branch + a note and a sketch on iPad.
        let attachments = try Self.branch(features, "Attachments")
        let handwriting = try Self.screenshot("handwriting-ipad.png")
        let palette = try Self.screenshot("touch-palette-ipad.png")
        let note = try Self.screenshot("note-sheet-ipad.png")
        let noteCard = try Self.card(note, top: 0.27, width: 470)
        let sketchCard = try Self.card(handwriting, top: 0.5, width: 470)
        let page3 = HStack(spacing: 24) {
            Self.canvas(attachments, size: CGSize(width: 660, height: 680), maxScale: 1.3)
            VStack(spacing: 22) {
                noteCard
                sketchCard
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.white)
        _ = try Self.write(page3, page: 3)

        // 4 Links, map links and the Tasks panel.
        let links = Self.subset(features, keep: ["Links", "Tasks", "Known gaps / Roadmap"])
        _ = try Self.write(Self.canvas(links, size: size, includePanel: true), page: 4)

        // 5 Multi-select, boundaries, relationships.
        var structure = Self.subset(features, keep: ["Look & Format", "Attachments", "Tasks", "Known gaps / Roadmap",
                                                     "Structure"],
                                    collapse: ["Known gaps / Roadmap"])
        if let index = structure.root.children.firstIndex(where: { $0.text == "Look & Format" }) {
            structure.root.children[index].children.removeAll { !["Shapes", "Borders"].contains($0.text) }
        }
        structure = Self.hidingPanel(Self.subset(structure))
        let selected = Self.ids(structure, ["Relationships (⌘L)", "Boundaries (⌘B)", "Collapse & levels"])
        _ = try Self.write(Self.canvas(structure, size: size, selected: selected), page: 5)

        // 6 iPad + Pencil: simulator screenshots.
        let paletteDevice = try Self.device(palette, height: 620)
        let handwritingDevice = try Self.device(handwriting, height: 620)
        let page6 = HStack(spacing: 40) {
            paletteDevice
            handwritingDevice
        }
        .frame(width: size.width, height: size.height)
        .background(Color.white)
        _ = try Self.write(page6, page: 6)
    }
}
#endif
