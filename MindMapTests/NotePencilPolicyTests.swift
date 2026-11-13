import Foundation
import Testing
@testable import MindMap

/// Pencil barrel double-tap in a handwritten note (owner's report: the
/// haptic came, the eraser did not).
struct NotePencilPolicyTests {
    private let eraser = "eraser", pen = "pen", marker = "marker"

    @Test("BUG-eraser-1: double-tap switches to the eraser and back, as the Pencil setting says")
    func doubleTapSwitchesTheToolAsTheSettingSays() {
        // "Switch between current tool and eraser" (the default).
        #expect(NotePencilPolicy.tool(preference: .switchEraser, current: marker, previous: pen, eraser: eraser,
                                      fallback: pen) == eraser)
        #expect(NotePencilPolicy.tool(preference: .switchEraser, current: eraser, previous: marker, eraser: eraser,
                                      fallback: pen) == marker)
        #expect(NotePencilPolicy.tool(preference: .switchEraser, current: eraser, previous: nil, eraser: eraser,
                                      fallback: pen) == pen)
        // "Switch between current tool and last used".
        #expect(NotePencilPolicy.tool(preference: .switchPrevious, current: marker, previous: eraser, eraser: eraser,
                                      fallback: pen) == eraser)
        #expect(NotePencilPolicy.tool(preference: .switchPrevious, current: marker, previous: nil, eraser: eraser,
                                      fallback: pen) == nil)
        // Not a tool switch: left to the tool picker / the system.
        for preference in [PencilPreference.ignore, .showColorPalette, .showInkAttributes, .showContextualPalette,
                           .runSystemShortcut, .other] {
            #expect(NotePencilPolicy.tool(preference: preference, current: pen, previous: marker, eraser: eraser,
                                          fallback: pen) == nil)
        }
    }

    @Test("BUG-eraser-2: a tap PencilKit's tool picker already handled is not switched a second time")
    func tapHandledByTheToolPickerIsNotSwitchedTwice() {
        let tap: TimeInterval = 1000
        #expect(NotePencilPolicy.shouldSwitch(toolChangedAt: nil, tapAt: tap))
        #expect(NotePencilPolicy.shouldSwitch(toolChangedAt: tap - 5, tapAt: tap))
        #expect(!NotePencilPolicy.shouldSwitch(toolChangedAt: tap, tapAt: tap))
        #expect(!NotePencilPolicy.shouldSwitch(toolChangedAt: tap + 0.01, tapAt: tap))
    }
}
