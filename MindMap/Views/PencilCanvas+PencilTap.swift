#if os(iOS)
import PencilKit
import UIKit

/// Pencil barrel double-tap in a handwritten note: the note's own
/// `UIPencilInteraction` on the canvas switches the tool picker's tool as the
/// user's setting says (`NotePencilPolicy`); the canvas follows the picker.
/// PencilKit's own interaction lives on the tool picker palette, in another
/// window, and on iPad it did not switch the tool (the Pencil's haptic came,
/// the eraser did not). When it does handle a tap, the note leaves that tap
/// alone, so a tap never switches twice.
extension PencilCanvas.Coordinator: UIPencilInteractionDelegate, PKToolPickerObserver {
    func installPencilTap() {
        guard let canvas else { return }
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        canvas.addInteraction(pencil)
        guard #available(iOS 18.0, *), let toolPicker else { return }
        currentToolID = toolPicker.selectedToolItemIdentifier
        toolPicker.addObserver(self)
    }

    @available(iOS 18.0, *)
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        noteSelectedTool(toolPicker.selectedToolItemIdentifier)
    }

    private func noteSelectedTool(_ id: String) {
        toolChangedAt = ProcessInfo.processInfo.systemUptime
        guard id != currentToolID else { return }
        previousToolID = currentToolID
        currentToolID = id
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        pencilTapped(preference: PencilBridge.BridgeView.preference(UIPencilInteraction.preferredTapAction),
                     at: tap.timestamp)
    }

    /// Acts on the next turn of the main loop, after every Pencil interaction
    /// (PencilKit's too) had the tap. `time`: system uptime of the tap.
    func pencilTapped(preference: PencilPreference, at time: TimeInterval) {
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated { self?.switchTool(preference: preference, tapAt: time) }
        }
    }

    private func switchTool(preference: PencilPreference, tapAt time: TimeInterval) {
        guard #available(iOS 18.0, *), !parent.isReadOnly, let toolPicker,
              NotePencilPolicy.shouldSwitch(toolChangedAt: toolChangedAt, tapAt: time) else { return }
        let items = toolPicker.toolItems
        guard let eraser = items.first(where: { $0 is PKToolPickerEraserItem })?.identifier,
              let pen = items.first(where: { $0 is PKToolPickerInkingItem })?.identifier,
              let target = NotePencilPolicy.tool(preference: preference, current: toolPicker.selectedToolItemIdentifier,
                                                 previous: previousToolID, eraser: eraser, fallback: pen)
        else { return }
        toolPicker.selectedToolItemIdentifier = target
        noteSelectedTool(toolPicker.selectedToolItemIdentifier)
    }
}
#endif
