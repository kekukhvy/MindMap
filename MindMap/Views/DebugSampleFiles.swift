#if DEBUG
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sample files for screenshots and tests (DEBUG only): a one-page PDF and
/// a PNG drawn with CoreGraphics, written to a temp folder under the given
/// names (the import then copies them like any user file).
enum DebugSampleFiles {
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MindMap Samples/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// "Project Brief.pdf"-style document with a title, text lines and a chart.
    @discardableResult
    static func writePDF(named name: String = "Project Brief.pdf", in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.93, green: 0.45, blue: 0.44, alpha: 1))
        context.fill(CGRect(x: 0, y: 712, width: 612, height: 80))
        draw("Project Brief", at: CGPoint(x: 48, y: 738), size: 30, bold: true, color: CGColor(gray: 1, alpha: 1), in: context)
        draw("Launch plan · Q3", at: CGPoint(x: 48, y: 660), size: 18, bold: true, in: context)
        let lines = ["Goals: ship the mind-map app with attachments.",
                     "Scope: notes, handwriting, files with QuickLook preview.",
                     "Owners: design, iOS, macOS.",
                     "Risks: large files, iCloud sync, Pencil input."]
        for (index, line) in lines.enumerated() {
            draw("•  " + line, at: CGPoint(x: 56, y: 620 - CGFloat(index) * 28), size: 14, in: context)
        }
        let colors: [CGColor] = [CGColor(red: 0.55, green: 0.80, blue: 0.95, alpha: 1),
                                 CGColor(red: 0.62, green: 0.87, blue: 0.84, alpha: 1),
                                 CGColor(red: 0.95, green: 0.63, blue: 0.43, alpha: 1),
                                 CGColor(red: 0.73, green: 0.66, blue: 0.90, alpha: 1)]
        for (index, height) in [120.0, 210, 160, 260].enumerated() {
            context.setFillColor(colors[index])
            context.fill(CGRect(x: 80 + CGFloat(index) * 120, y: 180, width: 80, height: height))
        }
        context.setStrokeColor(CGColor(gray: 0.3, alpha: 1))
        context.setLineWidth(1.5)
        context.stroke(CGRect(x: 60, y: 170, width: 492, height: 300))
        draw("Milestones", at: CGPoint(x: 64, y: 480), size: 14, bold: true, in: context)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// Pastel "mockup" PNG of `size` pixels.
    @discardableResult
    static func writePNG(named name: String = "Mockup.png", size: CGSize = CGSize(width: 1200, height: 800),
                         in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [CGColor(red: 0.55, green: 0.80, blue: 0.95, alpha: 1),
                                           CGColor(red: 0.73, green: 0.66, blue: 0.90, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        context.setFillColor(CGColor(gray: 1, alpha: 0.9))
        context.addPath(CGPath(roundedRect: CGRect(x: size.width * 0.15, y: size.height * 0.2, width: size.width * 0.7,
                                                   height: size.height * 0.6), cornerWidth: 40, cornerHeight: 40,
                               transform: nil))
        context.fillPath()
        context.setFillColor(CGColor(red: 0.93, green: 0.45, blue: 0.44, alpha: 1))
        context.fillEllipse(in: CGRect(x: size.width * 0.22, y: size.height * 0.45, width: size.height * 0.25,
                                       height: size.height * 0.25))
        draw("Mockup", at: CGPoint(x: size.width * 0.45, y: size.height * 0.5), size: size.height * 0.09, bold: true,
             in: context)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, bold: Bool = false,
                             color: CGColor = CGColor(gray: 0.12, alpha: 1), in context: CGContext) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
#endif
