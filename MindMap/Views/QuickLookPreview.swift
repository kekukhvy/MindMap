import SwiftUI

/// QuickLook preview of one local file (a temp copy of an attachment):
/// `QLPreviewController` on iPad, `QLPreviewView` on macOS. Read-only:
/// Markup editing is disabled (it would only change the temp copy).
#if os(iOS)
import QuickLook

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let title: String

    func makeCoordinator() -> Coordinator { Coordinator(item: PreviewItem(url: url, title: title)) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        let item = context.coordinator.item
        guard item.previewItemURL != url || item.previewItemTitle != title else { return }
        context.coordinator.item = PreviewItem(url: url, title: title)
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var item: PreviewItem

        init(item: PreviewItem) { self.item = item }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { item }

        func previewController(_ controller: QLPreviewController,
                               editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode { .disabled }
    }

    final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(url: URL, title: String) {
            previewItemURL = url
            previewItemTitle = title
        }
    }
}
#else
import QuickLookUI

struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    let title: String

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        view.autostarts = true
        view.shouldCloseWithWindow = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Its window closed: QuickLook closed the view (`shouldCloseWithWindow`);
        // setting an item now raises an assertion.
        if let window = view.window, !window.isVisible, !window.isMiniaturized { return }
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    // No `close()` on dismantle: closing a preview view that QuickLook has
    // not activated yet (or that its window already closed, see
    // `shouldCloseWithWindow`) raises an assertion and crashes.
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.previewItem = nil
    }
}
#endif
