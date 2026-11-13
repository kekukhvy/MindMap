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
/// forwards presses from this window to `onTab`. Only while `isActive` (the
/// canvas or its topic editor has focus): otherwise the command is removed,
/// so Tab moves between fields of sheets (hex color, link editor) and works
/// in note text views instead of adding a topic behind them.
struct TabKeyBridge: UIViewRepresentable {
    var isActive: Bool
    var onTab: () -> Void

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.onTab = onTab
        view.isActive = isActive
        return view
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        uiView.onTab = onTab
        uiView.isActive = isActive
    }

    final class BridgeView: UIView {
        var onTab: (() -> Void)?
        var isActive = true {
            didSet { if isActive != oldValue { updateCommand() } }
        }
        private var observer: NSObjectProtocol?
        private weak var commandOwner: UIViewController?
        private lazy var command: UIKeyCommand = {
            let command = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(UIWindow.mindMapTabPressed(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }()

        /// Whether this bridge's Tab command is installed (tests).
        var isCommandInstalled: Bool {
            commandOwner?.keyCommands?.contains(command) == true
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            removeObserver()
            updateCommand()
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: .mindMapTabKey, object: window,
                                                              queue: .main) { [weak self] _ in
                self?.onTab?()
            }
        }

        private func updateCommand() {
            let root = window?.rootViewController
            if let owner = commandOwner, owner !== root || !isActive {
                owner.removeKeyCommand(command)
                commandOwner = nil
            }
            guard isActive, let root, commandOwner == nil else { return }
            root.addKeyCommand(command)
            commandOwner = root
        }

        private func removeObserver() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        deinit {
            removeObserver()
            commandOwner?.removeKeyCommand(command)
        }
    }
}
#endif
