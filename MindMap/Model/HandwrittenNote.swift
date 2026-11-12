import CoreGraphics
import Foundation
import PencilKit

/// Helpers for handwritten notes: the attachment file is exactly
/// `PKDrawing.dataRepresentation()` (`attachments/<UUID>.drawing`).
///
/// Coordinates: the drawing lives on a "page" `pageWidth` points wide with
/// the origin at the top left (PencilKit's convention); it grows downwards
/// as the user writes. iPad and macOS show the same page width, scaled to fit.
enum HandwrittenNote {
    static let pageWidth: CGFloat = 1024
    /// Empty space kept below the lowest stroke so writing can continue (Notes-like).
    static let bottomMargin: CGFloat = 600

    static var emptyData: Data { PKDrawing().dataRepresentation() }

    /// Decodes stored data; nil/empty/corrupt data is an empty drawing.
    static func drawing(_ data: Data?) -> PKDrawing {
        guard let data, !data.isEmpty, let drawing = try? PKDrawing(data: data) else { return PKDrawing() }
        return drawing
    }

    /// Page height for `drawing` shown in a viewport `minHeight` points high (page coordinates).
    static func pageHeight(for drawing: PKDrawing, minHeight: CGFloat) -> CGFloat {
        let bounds = drawing.bounds
        guard !bounds.isNull, !bounds.isEmpty else { return minHeight }
        return max(minHeight, bounds.maxY + bottomMargin)
    }

    /// Default title of the `index`-th (0-based) handwritten note of a topic.
    static func defaultTitle(index: Int) -> String {
        index == 0 ? "Handwritten Note" : "Handwritten Note \(index + 1)"
    }
}
