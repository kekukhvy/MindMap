#if os(iOS)
import SwiftUI
import UIKit

extension Notification.Name {
    static let mindMapTabKey = Notification.Name("MindMapTabKey")
}

extension UIWindow {
    /// Target of the Tab key command (the window is in every responder chain).
    @objc func mindMapTabPressed(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .mindMapTabKey, object: self)
    }
}

/// iPadOS uses Tab for focus navigation; this registers a Tab key command
/// with priority over system behaviour on the window's root controller and
/// forwards presses from this window to `onTab`.
struct TabKeyBridge: UIViewRepresentable {
    var onTab: () -> Void

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.onTab = onTab
        return view
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        uiView.onTab = onTab
    }

    final class BridgeView: UIView {
        var onTab: (() -> Void)?
        private var observer: NSObjectProtocol?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            removeObserver()
            guard let window else { return }
            let action = #selector(UIWindow.mindMapTabPressed(_:))
            if let root = window.rootViewController, !(root.keyCommands ?? []).contains(where: { $0.action == action }) {
                let command = UIKeyCommand(input: "\t", modifierFlags: [], action: action)
                command.wantsPriorityOverSystemBehavior = true
                root.addKeyCommand(command)
            }
            observer = NotificationCenter.default.addObserver(forName: .mindMapTabKey, object: window,
                                                              queue: .main) { [weak self] _ in
                self?.onTab?()
            }
        }

        private func removeObserver() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        deinit {
            removeObserver()
        }
    }
}
#endif
