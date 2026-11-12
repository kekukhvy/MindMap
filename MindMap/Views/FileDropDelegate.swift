import SwiftUI
import UniformTypeIdentifiers

/// Files dragged over the canvas: the topic under the pointer is
/// highlighted; dropping attaches the files to it, or creates a floating
/// topic per file on empty canvas (`EditorController.dropFiles`).
struct FileDropDelegate: DropDelegate {
    let editor: EditorController

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.item])
    }

    func dropEntered(info: DropInfo) {
        track(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        track(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        editor.fileDropTargetID = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        editor.dropFiles(info.itemProviders(for: [.item]), at: info.location)
    }

    private func track(_ info: DropInfo) {
        let target = editor.topic(atScreen: info.location)
        if editor.fileDropTargetID != target { editor.fileDropTargetID = target }
    }
}
