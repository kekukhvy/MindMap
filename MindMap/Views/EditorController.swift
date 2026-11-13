import Observation
import SwiftUI

/// Node being dragged for reparenting / reordering (canvas coordinates).
struct NodeDrag: Equatable {
    var id: UUID
    /// Topics that move (the dragged one plus the rest of a multi-selection,
    /// without topics whose ancestor moves too), document order.
    var movingIDs: [UUID] = []
    /// Topics drawn as ghosts following the pointer (the whole selection).
    var ghostIDs: Set<UUID> = []
    var translation: CGSize
    var targetID: UUID?
    var placement: DropPlacement = .child
    /// Axis along which the target's siblings are stacked (for the indicator).
    var siblingAxis: ConnectorAxis?

    /// Target highlighted as new parent (not a sibling insertion).
    var parentTargetID: UUID? { placement == .child ? targetID : nil }
    /// Option held: drop moves freely even over a topic.
    var freeMove = false
}

/// Waiting for the user to click a target topic.
enum PickMode: Equatable {
    case relationship(from: UUID)
    case attach(UUID)
    /// Choosing the target of a topic link on the canvas.
    case link(from: UUID)

    var sourceID: UUID {
        switch self {
        case let .relationship(id), let .attach(id), let .link(id): return id
        }
    }

    /// Relationship / link picking draws a line from the source to the pointer.
    var drawsRubberBand: Bool {
        switch self {
        case .relationship, .link: return true
        case .attach: return false
        }
    }

    var prompt: String {
        switch self {
        case .relationship: return "Click the topic to connect to (Esc to cancel)"
        case .attach: return "Click the topic to attach to (Esc to cancel)"
        case .link: return "Click the topic to link to (Esc to cancel)"
        }
    }
}

/// Live drag of one relationship control-point handle (screen translation).
struct ControlPointDrag: Equatable {
    var relationshipID: UUID
    var isStart: Bool
    var translation: CGSize
}

/// Request for the custom color sheet.
struct ColorSheetRequest: Identifiable {
    enum Target: Equatable {
        /// One or several topics (a multi-selection).
        case nodes([UUID], wholeBranch: Bool)
        case relationship(UUID)
        case boundary(UUID)
        case theme
    }

    let id = UUID()
    var target: Target
    var initialHex: String
}

/// Request to show an attachment: sheet (iPad) / own window (macOS).
struct AttachmentRequest: Identifiable, Equatable {
    let id = UUID()
    var attachmentID: UUID
    /// iPad: full-screen cover (handwriting) instead of a page sheet.
    var fullScreen = false
}

/// UI state of one open map: selection, inline editing, viewport, drag.
/// All document changes go through `MindMapModel` with `undoManager`
/// (actions live in `EditorController+Actions.swift`).
@Observable
final class EditorController {
    let model: MindMapModel
    @ObservationIgnored weak var undoManager: UndoManager?

    /// Primary selected topic = keyboard focus (exclusive with
    /// `selectedItem`). Setting it to a topic outside `selectedIDs`
    /// collapses the multi-selection to that topic; nil clears it.
    var selectedID: UUID? {
        didSet {
            if let selectedID {
                if !selectedIDs.contains(selectedID) { selectedIDs = [selectedID] }
            } else {
                if !selectedIDs.isEmpty { selectedIDs = [] }
                if palette.isRequested || palette.pendingToken != nil { palette.selectionCleared() }
            }
        }
    }
    /// All selected topics (contains `selectedID`; empty without one).
    /// Changed through `EditorController+Selection`.
    var selectedIDs: Set<UUID> = []
    /// iPad "Select" mode: taps toggle topics, background drags draw a marquee.
    var isSelectMode = false
    /// iPad floating action palette (WP11, `EditorController+Touch`).
    var palette = ActionPaletteState()
    @ObservationIgnored var tapSequence = TapSequence()
    /// Single tap on an expanded topic: its collapse after the double-tap
    /// interval (WP16, `TopicTapPlan`).
    @ObservationIgnored var pendingTapCollapse: PendingTapCollapse?
    @ObservationIgnored var tapCollapseCounter = 0
    /// Last tap on a button inside a topic (checkbox / link / attachment
    /// icon), uptime: the topic's own tap recognizer ignores that tap.
    @ObservationIgnored var lastAccessoryTap: (id: UUID, time: TimeInterval)?
    /// Runs the deferred palette show after a tap (replaced by tests).
    @ObservationIgnored var paletteScheduler: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// Last Apple Pencil location over the canvas (hover / touch), screen.
    @ObservationIgnored var lastPencilPoint: CGPoint?
    /// Pencil hovering over the canvas now (screen), for squeeze.
    @ObservationIgnored var pencilHoverPoint: CGPoint?
    /// Topic under the hovering Apple Pencil (highlight + "+" handle).
    var pencilHoveredID: UUID?
    /// "Gestures & Apple Pencil" help sheet (iPad).
    var isGestureHelpPresented = false
    /// Settings sheet (iPad "…" menu; macOS uses the Settings window).
    var isSettingsPresented = false
    /// Rubber-band selection in progress (screen coordinates).
    var marquee: MarqueeDrag?
    /// Boundary whose members are being edited (= the topic selection).
    var boundaryMemberEditing: UUID?
    /// Selected relationship / boundary.
    var selectedItem: CanvasItem?
    var pickMode: PickMode?
    /// Pointer location (screen) while picking, for the rubber band.
    var pickPointer: CGPoint?
    var controlDrag: ControlPointDrag?
    /// Relationship / boundary whose label is edited inline (`labelDraft`).
    private(set) var labelEditing: CanvasItem?
    var labelDraft = ""
    /// Last secondary-click location (screen), for "Add Floating Topic" there.
    @ObservationIgnored var contextPoint: CGPoint?
    /// Topic added and being named now: its rename joins the add undo step.
    @ObservationIgnored var namingNewID: UUID?
    private(set) var editingID: UUID?
    var draftText = ""
    /// Whether the inline editor selects all text when it appears.
    private(set) var editSelectsAll = true
    var viewport = Viewport()
    var viewSize: CGSize = .zero
    var drag: NodeDrag?
    /// Topic (or its collapse toggle) under the pointer (macOS hover).
    private(set) var hoveredID: UUID?
    var colorSheet: ColorSheetRequest?
    /// Attachment to open now (ContentView presents it, then clears on macOS).
    var presentedAttachment: AttachmentRequest?
    /// "Attach File…" picker shown; files go to `fileImportTarget`.
    var isFileImporterPresented = false
    @ObservationIgnored var fileImportTarget: UUID?
    /// Topic under files being dragged over the canvas (highlighted).
    var fileDropTargetID: UUID?
    /// Message for files that could not be attached (alert).
    var fileImportError: String?
    /// Link editor shown for a topic (sheet).
    var linkEditor: LinkEditorRequest?
    /// "Go to" notice (broken topic link), shown as an alert.
    var linkMessage: String?
    /// Topics to return to with Back (⌘[) after following topic links.
    var navigationHistory = TopicNavigationHistory()
    /// Tasks panel: "Show Completed" (view state, not saved).
    var taskPanelShowsCompleted = false
    /// Tasks panel: list every row instead of the first `TaskPanelLayout.maxRows`.
    var taskPanelShowsAll = false
    /// Tasks just completed from the panel, still shown (checked) until they fade out.
    var lingeringTaskIDs: Set<UUID> = []
    /// How long a completed row stays in the panel before fading out.
    @ObservationIgnored var taskLingerDelay: TimeInterval = 1.2
    /// Live translation (screen points) while the panel header is dragged.
    var taskPanelDrag: CGSize?
    /// Last click on a topic's checkbox: a second click soon after must not
    /// count as a double-click on the topic (which adds a child).
    @ObservationIgnored var lastCheckboxClick: (id: UUID, time: Date)?
    /// Topic whose due-day picker popover is shown.
    var dueDatePickerID: UUID?
    /// Opens web links (default browser); replaced by tests.
    @ObservationIgnored var openURL: (URL) -> Void = EditorController.openInBrowser
    /// The document's file (nil while never saved); map links store paths
    /// relative to its folder. Set by the window hosting the editor.
    var documentURL: URL? {
        didSet {
            guard documentURL.map(LaunchEnvironment.key) != oldValue.map(LaunchEnvironment.key) else { return }
            refreshMapLinkPaths()
        }
    }
    /// Opens a linked map file (macOS: new tab; iPad: new window or in this
    /// window) and reports failure text; set by the hosting window.
    @ObservationIgnored var mapOpener: MapOpener?
    @ObservationIgnored var mapResolver = MapLinkResolver()
    /// A map link that could not be followed (alert with Locate…).
    var mapLinkProblem: MapLinkProblem?
    /// "Locate…": file picker shown for the map link of `mapLocateNodeID`.
    var isMapLocatorPresented = false
    @ObservationIgnored var mapLocateNodeID: UUID?
    #if os(macOS)
    /// Window showing this editor (linked maps open as tabs of it).
    @ObservationIgnored weak var hostWindow: NSWindow?
    #endif
    /// Store actions of this map (WP14b: rename, import/move/export, duplicate).
    @MainActor var storage: MapStorageController {
        if let storageController { return storageController }
        let created = MapStorageController(editor: self)
        storageController = created
        return created
    }
    @ObservationIgnored private var storageController: MapStorageController?
    /// Topic to reveal once the canvas has its size (opened at a topic).
    @ObservationIgnored var pendingRevealID: UUID?
    private(set) var canUndo = false
    private(set) var canRedo = false

    @ObservationIgnored let measurer = NodeMeasurer()
    @ObservationIgnored private var cachedScene: (map: MindMap, editing: UUID?, draft: String, day: Date,
                                                  panel: CGRect?, scene: MapScene)?
    /// Current time (due chips, completion stamps); replaced by tests.
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var didPlaceViewport = false

    init(model: MindMapModel) {
        self.model = model
        #if DEBUG
        Self.debugInstances.append(WeakEditor(editor: self))
        #endif
        // Main topics keep the side they are shown on (WP17).
        model.sideSplitProvider = { [weak self] in self?.scene.layout.balanced }
    }

    #if DEBUG
    struct WeakEditor { weak var editor: EditorController? }
    /// Debug-only registry so in-app event tests can find the editor of a
    /// real document window.
    nonisolated(unsafe) static var debugInstances: [WeakEditor] = []
    #endif

    /// Current scene; rebuilt only when the map or the edited draft changes.
    var scene: MapScene {
        let map = model.map
        let editing = editingID
        let draft = editing == nil ? "" : draftText
        let now = now()
        // Due chips say "Today" / overdue: rebuild when the day changes.
        let day = Calendar.current.startOfDay(for: now)
        // A dragged Tasks panel stays put: topics keep clear of it (WP17).
        let panel = fixedTaskPanelFrame
        if let cachedScene, cachedScene.editing == editing, cachedScene.draft == draft, cachedScene.day == day,
           cachedScene.panel == panel, cachedScene.map == map {
            return cachedScene.scene
        }
        let scene = MapScene.build(map: map, measurer: measurer, editing: editing.map { ($0, draft) }, now: now,
                                   fixedObstacles: panel.map { [$0] } ?? [], hidesAttachment: hidesAttachmentIcon)
        cachedScene = (map, editing, draft, day, panel, scene)
        return scene
    }

    var commandState: EditorCommandState {
        let selected = selectedID.flatMap { scene.nodes[$0] }
        return EditorCommandState(isEditing: editingID != nil || labelEditing != nil, hasSelection: selected != nil || selectedItem != nil,
                                  hasNodeSelection: selected != nil,
                                  selectionIsMainRoot: selectedID == model.root.id,
                                  selectionHasChildren: selected?.hasChildren ?? false,
                                  selectionIsCollapsed: selected?.isCollapsed ?? false,
                                  selectionIsFreelyPositioned: selectedID.map(isFreelyPositioned) ?? false,
                                  selectionHasNote: selected?.attachments.contains { $0.kind == .markdown } ?? false,
                                  selectionHasDrawing: selected?.attachments.contains { $0.kind == .drawing } ?? false,
                                  selectionHasLink: selected?.link != nil,
                                  canGoBack: backTargetID != nil,
                                  selectionIsTask: selected?.task != nil,
                                  selectionIsDoneTask: selected?.task?.isDone == true,
                                  selectionCount: selectedIDs.count,
                                  menu: selected == nil ? TopicMenuFacts() : selectedID.map(menuFacts(for:)) ?? TopicMenuFacts())
    }

    // MARK: Editing state

    func setLabelEditing(_ item: CanvasItem?, text: String) {
        labelDraft = text
        labelEditing = item
    }

    func setEditing(_ id: UUID?, text: String, selectAll: Bool) {
        draftText = text
        editSelectsAll = selectAll
        editingID = id
    }

    func setHovered(_ id: UUID, _ inside: Bool) {
        if inside {
            if hoveredID != id { hoveredID = id }
        } else if hoveredID == id {
            hoveredID = nil
        }
    }

    // MARK: Viewport

    func updateViewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if !didPlaceViewport {
            didPlaceViewport = true
            viewport = Viewport(scale: 1, offset: CGPoint(x: size.width / 2, y: size.height / 2))
            let bounds = scene.layout.bounds
            if bounds.width > size.width - 80 || bounds.height > size.height - 80 {
                viewport = .fitting(bounds, in: size, maxScale: 1)
            }
            if let id = pendingRevealID {
                pendingRevealID = nil
                DispatchQueue.main.async { [weak self] in self?.show(id) }
            }
        } else {
            // Keep the content center fixed on resize.
            viewport.pan(dx: (size.width - viewSize.width) / 2, dy: (size.height - viewSize.height) / 2)
        }
        viewSize = size
    }

    // MARK: Undo state

    func refreshUndoState() {
        let undo = undoManager?.canUndo ?? false, redo = undoManager?.canRedo ?? false
        // Assign only on change: checkpoints are frequent and would re-render.
        if undo != canUndo { canUndo = undo }
        if redo != canRedo { canRedo = redo }
    }

    /// Keeps selection/editing valid after external changes (undo, redo).
    func validateSelection() {
        let scene = scene
        if let editingID, scene.nodes[editingID] == nil { setEditing(nil, text: "", selectAll: true) }
        if let item = selectedItem, !itemExists(item) { selectedItem = nil }
        if let item = labelEditing, !itemExists(item) { setLabelEditing(nil, text: "") }
        if let pickMode, scene.nodes[pickMode.sourceID] == nil { cancelPick() }
        if let boundaryMemberEditing, model.map.boundaries.allSatisfy({ $0.id != boundaryMemberEditing }) {
            self.boundaryMemberEditing = nil
        }
        // Hidden / deleted topics leave a multi-selection.
        let stale = selectedIDs.filter { scene.nodes[$0] == nil }
        if !stale.isEmpty, let primary = selectedID, scene.nodes[primary] != nil { selectedIDs.subtract(stale) }
        guard var id = selectedID, scene.nodes[id] == nil else { return }
        while let parent = model.map.parentID(of: id) {
            if scene.nodes[parent] != nil {
                selectedID = parent
                return
            }
            id = parent
        }
        selectedID = nil
    }
}

/// Snapshot published to menu commands (FocusedValue).
struct EditorCommandState: Equatable {
    var isEditing: Bool
    /// A topic, relationship or boundary is selected.
    var hasSelection: Bool
    var hasNodeSelection: Bool
    var selectionIsMainRoot: Bool
    var selectionHasChildren: Bool
    var selectionIsCollapsed: Bool
    var selectionIsFreelyPositioned: Bool
    var selectionHasNote: Bool = false
    var selectionHasDrawing: Bool = false
    var selectionHasLink: Bool = false
    var canGoBack: Bool = false
    var selectionIsTask: Bool = false
    var selectionIsDoneTask: Bool = false
    /// Selected topics (> 1 = multi-selection).
    var selectionCount: Int = 0
    /// Task / Link / Note / Attachments submenus of the selection.
    var menu = TopicMenuFacts()
}
