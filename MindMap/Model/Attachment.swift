import Foundation

/// Placeholder for Stage 2 attachments (markdown, handwriting, files).
/// Files will live in the package's `attachments/` folder, named by `id`.
struct Attachment: Identifiable, Equatable, Codable {
    var id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}
