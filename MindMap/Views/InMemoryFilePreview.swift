import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Preview of a file in a LOCKED map (WP12): QuickLook needs a file on
/// disk, which would be a plaintext copy, so images, PDFs and text are shown
/// from memory instead; anything else offers the explicit Open / Export
/// actions (a deliberate, user-initiated decrypted copy).
struct InMemoryFilePreview: View {
    let data: Data?
    let fileExtension: String

    private var type: UTType? { UTType(filenameExtension: fileExtension) }

    var body: some View {
        Group {
            if let data, let type {
                if type.conforms(to: .pdf), let document = PDFDocument(data: data) {
                    PDFDataView(document: document)
                } else if type.conforms(to: .image), let image = PlatformImage(data: data) {
                    ScrollView([.horizontal, .vertical]) {
                        imageView(image)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                    }
                } else if type.conforms(to: .text), data.count <= 2_000_000 {
                    ScrollView {
                        Text(String(decoding: data, as: UTF8.self))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                } else {
                    unavailable
                }
            } else {
                unavailable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailable: some View {
        ContentUnavailableView("No Preview in a Locked Map", systemImage: "lock.doc",
                               description: Text("Previewing this kind of file would write a decrypted copy to disk. Use Open or Export to view it in another app."))
    }

    private func imageView(_ image: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }
}

#if os(macOS)
typealias PlatformImage = NSImage

private struct PDFDataView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
#else
typealias PlatformImage = UIImage

private struct PDFDataView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
#endif
