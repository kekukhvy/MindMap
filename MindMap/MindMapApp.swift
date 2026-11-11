import SwiftUI

@main
struct MindMapApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { MindMapDocument() }) { file in
            ContentView(model: file.document.model)
        }
        .commands { MindMapCommands() }
    }
}
