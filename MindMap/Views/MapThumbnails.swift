import CryptoKit
import ImageIO
import SwiftUI

/// Small pictures of maps for the Welcome lists (WP13): the real canvas
/// (`CanvasView`, as the snapshot tests render it) drawn with
/// `ImageRenderer`, the whole map fitted in. Cached in memory and in
/// Caches/Thumbnails (key = path + modification date of the map data), so
/// each map renders once per change. Locked maps get none (lock icon).
@MainActor
final class MapThumbnails {
    static let shared = MapThumbnails()
    nonisolated static let size = CGSize(width: 66, height: 42)

    private var memory: [String: CGImage] = [:]
    private let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    /// Package is locked (WP12): no plaintext to draw.
    nonisolated static func isLocked(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(LockHeader.fileName).path)
    }

    /// When the map content last changed (map.json / map.json.enc / lock.json).
    nonisolated static func modificationDate(of url: URL) -> Date? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let names = [MindMapPackage.mapFileName, MindMapPackage.mapFileName + ".enc", LockHeader.fileName]
        let dates = names.compactMap { name in
            (try? url.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        return dates.max() ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func key(for url: URL) -> String {
        let date = Self.modificationDate(of: url)?.timeIntervalSinceReferenceDate ?? 0
        let digest = SHA256.hash(data: Data("\(LaunchEnvironment.key(url))|\(date)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Already rendered (no work).
    func cached(for url: URL) -> CGImage? {
        memory[key(for: url)]
    }

    /// Cached or newly rendered thumbnail; nil for locked / unreadable maps.
    func thumbnail(for url: URL) async -> CGImage? {
        guard !Self.isLocked(url) else { return nil }
        let key = key(for: url)
        if let image = memory[key] { return image }
        let file = folder.appendingPathComponent(key + ".png")
        if let image = Self.loadPNG(file) {
            memory[key] = image
            return image
        }
        await Task.yield()
        guard let map = Self.readMap(url), let image = Self.render(map) else { return nil }
        memory[key] = image
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = Self.pngData(image) { try? data.write(to: file) }
        return image
    }

    nonisolated static func readMap(_ url: URL) -> MindMap? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url.appendingPathComponent(MindMapPackage.mapFileName)) else { return nil }
        return try? MindMapPackage.decode(data)
    }

    /// The map drawn by the real canvas, fitted into `size` (points, @2x).
    static func render(_ map: MindMap, size: CGSize = MapThumbnails.size, scale: CGFloat = 2) -> CGImage? {
        let editor = EditorController(model: MindMapModel(map: map))
        editor.updateViewSize(size)
        let bounds = editor.contentBoundsIncludingPanel
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let margin: CGFloat = 3
        let fit = min((size.width - 2 * margin) / bounds.width, (size.height - 2 * margin) / bounds.height)
        // The canvas zooms out to 0.2 at most: draw a larger canvas at that
        // zoom and let the renderer scale the picture down.
        let zoom = min(max(fit, Viewport.minScale), 0.35)
        let shrink = min(fit, zoom) / zoom
        let canvas = CGSize(width: size.width / shrink, height: size.height / shrink)
        editor.updateViewSize(canvas)
        editor.viewport = Viewport(scale: zoom, offset: CGPoint(x: canvas.width / 2 - bounds.midX * zoom,
                                                                y: canvas.height / 2 - bounds.midY * zoom))
        let view = CanvasView(editor: editor)
            .frame(width: canvas.width, height: canvas.height)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale * shrink
        return renderer.cgImage
    }

    nonisolated static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    nonisolated static func loadPNG(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
