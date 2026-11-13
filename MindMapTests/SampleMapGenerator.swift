#if os(macOS)
import AppKit
import PencilKit
import SwiftUI
import Testing
@testable import MindMap
@testable import struct MindMap.Attachment

/// WP9 sample maps: "MindMap Features.mindmap" (this app described with all
/// its features, each shown by using it) and "MindMap Roadmap.mindmap" (small
/// map it links to). Built with the real model types and written with
/// `MindMapPackage`, so the packages are exactly what the app saves.
///
/// The hosted test runs inside the app sandbox, so the packages and the
/// snapshot go to the app container temp dir (`<tmp>/Samples/`);
/// `Tools/samples/generate.sh` runs this suite and copies them to `Samples/`
/// and `Tools/preview/features-map.png`.
enum FeaturesSample {
    static let featuresFileName = "MindMap Features.mindmap"
    static let roadmapFileName = "MindMap Roadmap.mindmap"
    static let created = Date(timeIntervalSince1970: 1_794_441_600) // 2026-11-12

    struct Package {
        var map: MindMap
        var files: [String: Data]
    }

    // MARK: - Features map

    static let tipX: CGFloat = -260

    static func features(now: Date = Date(), roadmapTarget: UUID? = nil) -> Package {
        var files: [String: Data] = [:]
        func note(_ title: String, _ markdown: String) -> Attachment {
            let attachment = Attachment(kind: .markdown, title: title, createdAt: created)
            files[attachment.fileName] = MarkdownNote.data(markdown)
            return attachment
        }
        func day(_ offset: Int) -> Date {
            Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: now))!
        }
        func leaves(_ texts: [String]) -> [Node] { texts.map { Node(text: $0) } }

        // Hotkeys first: other branches link to its groups.
        func group(_ title: String, _ keys: [String]) -> Node { Node(text: title, children: leaves(keys)) }
        let hkEditing = group("Editing", [
            "Tab — Add Child Topic",
            "Return — Add Sibling Topic",
            "Delete — Delete Topic / Item",
            "Space or F2 — Rename",
            "Type a character — Rename with it",
            "Return / Esc — Finish Editing",
            "Tab while editing — Finish + Add Child",
            "⇧Return / ⌥Return — New Line in Topic",
            "⌘C / ⌘X / ⌘V — Copy / Cut / Paste Topics",
            "⌘Z / ⇧⌘Z — Undo / Redo",
            "⌥⌘L — Lock Editing (read-only)",
            "⌥-drag — Free Move (Mac)",
        ])
        let hkNavigation = group("Navigation", [
            "Arrow keys — Select Neighbour Topic",
            "Arrow towards the children — Expand a Folded Topic",
            "⌘= / ⌘- — Zoom In / Out",
            "⌘0 — Zoom to Fit",
            "⌘-scroll / pinch — Zoom",
            "Esc — Cancel Pick / Deselect",
        ])
        let hkFind = group("Find", [
            "⌘F — Find in Topics and Notes",
            "⌘G / ⇧⌘G — Next / Previous Match",
            "Return — Next Match (opens the note of a note match)",
            "Esc — Close Find",
        ])
        let hkSelection = group("Selection", [
            "⌘-click topic — Add / Remove from Selection",
            "⇧-click topic — Add Range",
            "⌘A — Select All",
            "⇧/⌘-drag empty canvas — Select Area",
            "Esc — Keep Only the Primary Topic",
        ])
        let hkView = group("View & Collapse", [
            "⌘/ — Collapse / Expand Topic",
            "⌥⌘1…4 — Collapse to Level 1–4",
            "⌥⌘0 — Expand All",
        ])
        let hkLinks = group("Links", [
            "⌘K — Add/Edit Link",
            "Click link icon — Go to Link",
            "⌘[ — Back",
            "Return / Esc — Save / Cancel Link",
        ])
        let hkTasks = group("Tasks", [
            "⌘Return — Mark as Done / Not Done",
        ])
        let hkAttachments = group("Attachments", [
            "⇧⌘N — Add/Open Note",
            "⇧⌘D — Add/Open Handwritten Note",
            "⇧⌘A — Attach File…",
            "⌘V — Paste Files / Images",
            "Drag an icon sideways — Reorder",
            "Esc — Close Note Window (Done)",
        ])
        let hkItems = group("Relationships & Boundaries", [
            "⌘L — Relationship (then click target)",
            "⌘B — Boundary",
            "Space — Edit Label",
            "Delete — Remove Selected Item",
        ])
        let hkDocuments = group("Documents", [
            "⌘N — New Map",
            "⌥⌘N — New Window (iPad)",
            "⌘O — Open…",
            "⇧⌘O — Open from Library…",
            "⇧⌘1 — Welcome (Mac)",
            "⌃⌘L — Lock Now (locked maps)",
        ])
        let hotkeys = Node(text: "Hotkeys", layoutStyle: .treeDown,
                           children: [hkEditing, hkNavigation, hkFind, hkSelection, hkView, hkLinks, hkTasks, hkAttachments,
                                      hkItems, hkDocuments],
                           attachments: [note("Hotkeys", """
                           # Hotkeys

                           Collected from the app's code (Topic / View / File menus and the canvas key handler).

                           - Plain keys (Tab, Return, Delete, Space, arrows) work while the **canvas** has focus and no topic is being edited.
                           - While editing, keys go to the text field: Return / Esc finish, Tab finishes and adds a child, ⇧Return / ⌥Return start a new line.
                           - On iPad the same shortcuts work with a hardware keyboard (hold ⌘ to see the list).
                           """)])

        // Editing & Keyboard (one deep branch collapsed: +N toggle).
        let mouse = Node(text: "Mouse & touch", isCollapsed: true, children: [
            Node(text: "Double-click topic — add child"),
            Node(text: "Drag topic — reparent / reorder", children: [
                Node(text: "Middle — make child"),
                Node(text: "Top / bottom edge — insert before / after"),
                Node(text: "Empty space — free position"),
            ]),
            Node(text: "Right-click / long press — menu"),
            Node(text: "iPad: tap folds, double-tap adds child"),
            Node(text: "Pinch, ⌘-scroll — zoom; drag background — pan"),
        ])
        let editing = Node(text: "Editing & Keyboard", layoutStyle: .rightMap, children: [
            Node(text: "Tab — child, Return — sibling"),
            Node(text: "Just type to rename"),
            Node(text: "One undo step per action"),
            Node(text: "Sort Children A → Z / Z → A"),
            Node(text: "Arrow towards children — unfolds"),
            mouse,
        ], attachments: [note("How to edit", """
        # Editing & Keyboard

        1. Select a topic and press **Tab** for a child or **Return** for a sibling.
        2. Start typing to rename (or **Space** / **F2**); Return or Esc finishes.
        3. Drag a topic onto another to reparent it, onto its top/bottom edge to reorder.
        4. Every change is one undo step: **⌘Z** / **⇧⌘Z**.
        5. **⇧Return** (or **⌥Return**) while typing starts a new line in the topic.
        6. **⌘C / ⌘X / ⌘V** copy, cut and paste whole branches (with notes, files, tasks, links); text from other apps pastes as topics, one per line.

        7. **Sort Children** (topic menu, right-click): reorders a topic's direct children A → Z or Z → A by their text, in one undo step.
        8. An arrow key towards a folded topic's children unfolds it. A new topic left empty is removed when you finish editing.

        The collapsed branch "Mouse & touch" shows the **+N** toggle: click it to expand.
        """)])

        // Layout Styles.
        let layouts = Node(text: "Layout Styles", children: [
            Node(text: "Map — central topic (balanced)"),
            Node(text: "Logic Right", layoutStyle: .rightMap, children: leaves(["Step 1", "Step 2"])),
            Node(text: "Tree Down", layoutStyle: .treeDown, children: leaves(["Item A", "Item B", "Item C"])),
            Node(text: "Org Chart", layoutStyle: .orgChartDown, children: leaves(["Team A", "Team B", "Team C"])),
            Node(text: "Logic Left — see Tasks"),
        ], attachments: [note("Layout styles", """
        # Layout Styles

        Right-click a topic → **Layout** (or Format ▸ Layout) and pick:

        - **Map** — balanced left/right (the central topic here)
        - **Logic Right / Logic Left** — branches grow to one side
        - **Tree Down** — an indented list below the topic (Hotkeys, Known gaps)
        - **Org Chart** — children side by side below (Documents & iCloud)
        - **Inherit from Parent** — back to the default

        Any branch can have its own style; styles can be mixed freely.
        """)])

        // Look & Format.
        let shapes = Node(text: "Shapes", children: [
            Node(text: "Rounded", shape: .roundedRect),
            Node(text: "Rectangle", shape: .rectangle),
            Node(text: "Capsule", shape: .capsule),
            Node(text: "Underline", shape: .underline),
        ])
        let look = Node(text: "Look & Format", children: [
            Node(text: "Themes", children: leaves(["XMind Pastel (default)", "Classic Rainbow", "Mono"])),
            shapes,
            Node(text: "Borders", children: [
                Node(text: "Solid border", shape: .rectangle, borderStyle: .solid),
                Node(text: "Dashed border", shape: .roundedRect, borderStyle: .dashed),
            ]),
            Node(text: "Branch lines", connectorStyle: .straight, lineWidth: 2,
                 children: leaves(["Curved · Straight", "Elbow · Rounded elbow", "Dashed · Dotted · Width"])),
            Node(text: "Colors", children: [
                Node(text: "Color tag", colorTag: .red),
                Node(text: "Custom color", customColor: "#3D8FE0"),
            ]),
        ], attachments: [note("Formatting", """
        # Look & Format

        - **Theme**: Format ▸ Theme — XMind Pastel, Classic Rainbow or Mono. Each main branch gets its own color.
        - **Shape / Border / Color / Branch Line**: select a topic, then Format menu or right-click.
        - **Apply to Branch** applies the change to the whole subtree in one undo step.
        - Lines: curved, straight, elbow, rounded elbow; solid, dashed or dotted; any width.
        """)])

        // Structure.
        let floatingDemo = Node(text: "Floating topics")
        let freeDemo = Node(text: "Free position (dropped here)", manualPosition: CGPoint(x: 250, y: 70))
        let structure = Node(text: "Structure", connectorStyle: .roundedElbow, children: [
            Node(text: "Relationships (⌘L)"),
            Node(text: "Boundaries (⌘B)"),
            Node(text: "Collapse & levels", children: leaves(["+N toggle on the topic", "⌥⌘1…4 / ⌥⌘0"])),
            Node(text: "Favorites", children: leaves(["Mark as Favorite (topic menu)", "Favorites panel — click a row to jump"])),
            Node(text: "View ▸ Rebalance Map"),
            freeDemo,
            floatingDemo,
        ], attachments: [note("Structure", """
        # Structure

        - **Floating topic**: double-click empty canvas (or Insert ▸ Floating Topic). Drop it on a topic to attach.
        - **Relationship**: select a topic, **⌘L**, click the target. Double-click the line to label it; drag its handles to bend it.
        - **Boundary**: select a topic, **⌘B**. Double-click the tab to label it.
        - **Free position**: drop a topic on empty space (⌥-drag on Mac); "Reset Position" puts it back.
        - **Collapse**: the −/+N toggle, ⌘/, or View ▸ Collapse to Level 1–4 / Expand All.
        - **Favorites**: topic menu ▸ **Mark as Favorite** (several selected topics at once; "Remove from Favorites" undoes it). The **Favorites** panel appears on the canvas while any topic is a favorite: click a row to select the topic and scroll to it; drag the header to move the panel, the chevron folds it. Marks and panel position are saved with the map.
        - **Rebalance Map** (View menu): main branches never change side by themselves; this command balances them again.
        """)])

        // Attachments.
        let markdownDemo = Node(text: "Markdown notes", children: leaves(["Opens in Preview when it has text", "Lock Note — encrypted"]),
                                attachments: [note("Example note", """
        # Example note

        Notes are plain **Markdown** files inside the package (`attachments/<UUID>.md`), readable in Obsidian.

        - [x] Edit / Preview switch (a note with text opens in Preview, an empty one in Edit)
        - [ ] Add your own text here
        """)])
        let drawing = Attachment(kind: .drawing, title: "Arrow sketch", createdAt: created)
        files[drawing.fileName] = arrowDrawing().dataRepresentation()
        let handwriting = Node(text: "Handwriting (PencilKit)",
                               link: .web(URL(string: "https://developer.apple.com/documentation/pencilkit")!),
                               children: leaves(["Endless canvas — draw in any direction",
                                                 "Pinch to zoom; opens fitted to the ink",
                                                 "iPad: hold a shape to straighten it",
                                                 "iPad: Pencil double-tap — eraser and back"]),
                               attachments: [drawing])
        let icon = Attachment(kind: .file, title: "MindMap Icon.png", originalExtension: "png", createdAt: created)
        files[icon.fileName] = iconPNG(side: 256)
        let filesDemo = Node(text: "Files (any type)", attachments: [icon])
        let attachments = Node(text: "Attachments", link: .topic(hkAttachments.id), children: [
            Node(text: "Icons stay small on the topic"),
            filesDemo, markdownDemo, handwriting,
        ], attachments: [note("Attachments", """
        # Attachments

        A topic can hold any number of attachments; they show as small icons after the text.

        - **Note** (⇧⌘N): Markdown with Edit / Preview.
        - **Handwritten note** (⇧⌘D): PencilKit page — full screen on iPad, window with pen/eraser on Mac. The canvas is endless: draw in any direction, pinch to zoom; a note whose ink is bigger than the page opens zoomed out to show it all.
        - On iPad, draw a line, circle, ellipse, rectangle or triangle and **hold** the pen still: the shape is straightened, as in Apple Notes (one Draw undo step).
        - On iPad, the **Pencil double-tap** does what Settings ▸ Apple Pencil says; "Switch between current tool and eraser" swaps to the eraser and back.
        - **File** (⇧⌘A, drag & drop, ⌘V): copied into the package, QuickLook preview, Share / Open / Export.
        - Drag an icon sideways to change the order; the Preview shows headings, lists, tasks, quotes, code and tables.
        - **Lock Note** (note menu): encrypts a note; locked notes are skipped by Find.

        Click an icon to open it. Edits are part of the map's undo history.
        """)])

        // Links.
        let links = Node(text: "Links", link: .topic(hkLinks.id), children: [
            Node(text: "Inspired by XMind", link: .web(URL(string: "https://xmind.com")!)),
            Node(text: "Jump to Hotkeys", link: .topic(hotkeys.id)),
            Node(text: "MindMap Roadmap (other map)",
                 link: .map(MapReference(relativePath: roadmapFileName, displayName: "MindMap Roadmap",
                                         targetTopicID: roadmapTarget))),
            Node(text: "Click the link icon — Go to; ⌘[ — Back"),
        ], attachments: [note("Links", """
        # Links

        Select a topic and press **⌘K** (Add/Edit Link). Three kinds:

        - **Web** — opens in the browser (try "Inspired by XMind").
        - **Topic** — jumps to another topic of this map and expands it; **⌘[** or the Back pill returns.
        - **Map** — opens another `.mindmap` in a new tab (Mac) / window (iPad), optionally at a topic. Stored as a relative path, so maps in one iCloud folder keep working.

        Click (tap) the link icon before the title to follow it, or right-click → **Link ▸ Go to**.
        ⌘-click on a linked topic only selects it (multi-selection), like on any topic.
        The **Link ▸** menu (Add/Edit Link… ⌘K, Go to, Copy Link, Locate…, Remove Link) sits next to **Task ▸**.
        """)])

        // Tasks.
        let tasks = Node(text: "Tasks", layoutStyle: .leftMap, shape: .capsule, link: .topic(hkTasks.id), children: [
            Node(text: "Task ▸ Convert to Task"),
            Node(text: "Priority !!! / !! / !"),
            Node(text: "Due date: Today, Tomorrow, …"),
            Node(text: "Tasks panel = all open tasks"),
            Node(text: "Logic Left layout (this branch)"),
        ], attachments: [note("Tasks", """
        # Tasks

        1. Right-click a topic → **Task ▸ Convert to Task** (a checkbox appears before the title).
        2. Set **Priority** and **Due Date** in the same **Task ▸** menu; **⌘Return** marks it done. With several topics selected, Task ▸ applies to all of them.
        3. The **Tasks** panel on the canvas lists every open task: click a row to jump, tick to complete. Drag its header to move it.

        See the tasks under "Known gaps / Roadmap".
        """)])

        // Documents & iCloud (org chart).
        let ipad = Node(text: "iPad", children: leaves(["Welcome screen", "Multi-window"]))
        let package = Node(text: "Package", children: leaves(["map.json", "attachments/"]))
        let documents = Node(text: "Documents & iCloud", layoutStyle: .orgChartDown, children: [
            Node(text: "Mac", children: leaves(["Welcome window", "Map tabs"])),
            ipad,
            package,
            Node(text: "iCloud Sync", children: leaves(["Tap the cloud badge — Sync Now", "Tour asks for storage if available"])),
            Node(text: "Settings", children: leaves(["Version, build, commit", "Mirror library to folder"])),
        ], attachments: [note("Documents", """
        # Documents & iCloud

        - A map is a `.mindmap` package: `map.json` + `attachments/` (plain files, no absolute paths).
        - **Storage** (Settings): **iCloud Sync** library (CloudKit, works without iCloud Drive, merges edits per topic) or **Files** (`.mindmap` in a folder you choose, also iCloud Drive).
        - **Mac**: Welcome window (⇧⌘1) with the library and recent files; linked maps open as tabs.
        - **iPad**: Welcome screen, New Map ⌘N, Open… ⌘O, Open from Library ⇧⌘O, several windows.
        - **Cloud badge** (title bar): on a library map, a tap syncs now; a long press (click and hold on Mac) opens the menu, which also has Sync Now.
        - The **Welcome tour** asks where new maps go only while the iCloud Sync library is available; otherwise the first tour sets Files.
        - **Settings** shows the app version, build number and commit (the Mac About panel too); **Mirror library to folder** writes each library map as a plain `.md` for Obsidian (one way, locked maps never).
        - **Lock Map** (File menu): encrypted, opens with Face ID / Touch ID; **Lock Editing** (⌥⌘L) only makes a map read-only.
        """)])

        // Known gaps / Roadmap (tree down, tasks).
        let gaps = Node(text: "Known gaps / Roadmap", layoutStyle: .treeDown, borderStyle: .dashed, lineDash: .dashed,
                        children: [
                            Node(text: "Test iCloud Sync on two devices", task: TaskInfo(priority: .high, dueDate: day(3))),
                            Node(text: "Sign the Mac app with the team", task: TaskInfo(priority: .high, dueDate: day(7))),
                            Node(text: "Pencil & keyboard on a real iPad", task: TaskInfo(priority: .medium, dueDate: day(14))),
                            Node(text: "Export PNG / PDF", task: TaskInfo(priority: .low, dueDate: day(21))),
                                                        Node(text: "Search in a map", task: TaskInfo(isDone: true, completedAt: now)),
                            Node(text: "Copy / paste topics", task: TaskInfo(isDone: true, completedAt: now)),
                            Node(text: "Multi-line topics", task: TaskInfo(isDone: true, completedAt: now)),
                            Node(text: "Drag-reorder attachment icons", task: TaskInfo(isDone: true, completedAt: day(-1))),
                        ],
                        attachments: [note("Known gaps", """
                        # Known gaps / Roadmap

                        From REPORT.md. Open items are tasks — they appear in the Tasks panel.

                        - iCloud Sync, and Mac ↔ iPad lock keys, need the Mac app signed with the developer team (an Apple ID in Xcode) and a real test on two devices.
                        - Apple Pencil (Scribble, hover, squeeze, double-tap), hardware keyboard and trackpad are checked by hand on a device.
                        - Ideas for later: export to PNG / PDF, presentation mode.
                        """)])

        let find = Node(text: "Find", link: .topic(hkFind.id), children: [
            Node(text: "⌘F — find in topics and notes"),
            Node(text: "Only matches and their parents stay"),
            Node(text: "3 letters minimum"),
            Node(text: "⌘G / ⇧⌘G — next / previous"),
            Node(text: "Locked notes are never searched"),
        ], attachments: [note("Find", """
        # Find

        **⌘F** (Edit ▸ Find…, or the magnifier button on iPad) opens the find bar over the canvas.

        - Type at least **3 letters**; the phrase is matched in topic text and in Markdown notes, ignoring case and accents. **Locked notes are never searched.**
        - While the bar is open the canvas shows only the matching topics and their parents; clear or close it and the full map is back. The map itself is not changed.
        - The bar shows "n of m"; **⌘G** / **⇧⌘G** (or the arrows) step to the next / previous match, which is selected and scrolled into view. **Return** does the same, and opens the note when the match is in a note.
        - **Esc** (or the close button) closes the bar.
        """)])

        let root = Node(text: "MindMap", children: [
            editing, layouts, hotkeys, find,
            look, links, attachments, documents, tasks, gaps, structure,
        ], attachments: [note("About", """
        # MindMap

        A native mind-map app for Mac and iPad: XMind speed + Mindjet attachments.

        This map describes every feature and uses it: each main branch has a note like this one (click the ≡ icon).
        """)])

        var tip = FloatingTopic(node: Node(text: "Tip: double-click empty canvas", shape: .capsule,
                                           children: [Node(text: "…to add a floating topic")]),
                                position: CGPoint(x: 0, y: 330))
        let relationships = [
            Relationship(from: floatingDemo.id, to: tip.id, label: "like this one"),
            Relationship(from: markdownDemo.id, to: package.id, label: "saved as .md",
                         style: RelationshipStyle(path: .curved, dash: .dashed, endArrow: .filledArrow)),
            Relationship(from: tasks.id, to: gaps.id, label: "see open tasks",
                         fromControlOffset: CGVector(dx: 130, dy: 30), toControlOffset: CGVector(dx: 130, dy: -30),
                         style: RelationshipStyle(path: .curved, dash: .solid, startArrow: .dot, endArrow: .arrow,
                                                  width: 2, colorHex: "#8E62D9")),
        ]
        let boundaries = [
            Boundary(nodeID: shapes.id, label: "Format ▸ Shape"),
            Boundary(nodeID: hkEditing.id, label: "Most used", colorHex: "#3D8FE0"),
        ]
        var map = MindMap(root: root, relationships: relationships, boundaries: boundaries)
        // The tip floats centered below the laid-out map.
        let bounds = MapScene.build(map: map, measurer: NodeMeasurer(), editing: nil).layout.bounds
        tip.position = CGPoint(x: tipX, y: (bounds.maxY + 70).rounded())
        map.floatingTopics = [tip]
        return Package(map: map, files: files)
    }

    // MARK: - Roadmap map

    static func roadmap() -> (Package, next: UUID) {
        var files: [String: Data] = [:]
        let about = Attachment(kind: .markdown, title: "Roadmap", createdAt: created)
        files[about.fileName] = MarkdownNote.data("""
        # MindMap Roadmap

        A small second map. It is opened from "Links › MindMap Roadmap" in *MindMap Features* (a map link),
        and links back to it.
        """)
        let next = Node(text: "Next", children: [
            Node(text: "Export PNG / PDF"),
            Node(text: "Search in a map"),
        ])
        let root = Node(text: "MindMap Roadmap", layoutStyle: .rightMap, children: [
            Node(text: "Done", children: [
                Node(text: "Stage 1 — tree editor"),
                Node(text: "Stage 2 — attachments"),
                Node(text: "Links, tasks, map links"),
                Node(text: "Multi-select"),
                Node(text: "iCloud Sync, lock, read-only"),
                Node(text: "Copy / paste, multi-line topics"),
            ]),
            next,
            Node(text: "Later", children: [
                Node(text: "Presentation mode"),
                Node(text: "Templates"),
            ]),
            Node(text: "Back to MindMap Features",
                 link: .map(MapReference(relativePath: featuresFileName, displayName: "MindMap Features"))),
        ], attachments: [about])
        return (Package(map: MindMap(root: root), files: files), next.id)
    }

    // MARK: - Content helpers

    /// A hand-drawn-looking underline and an arrow pointing right.
    static func arrowDrawing() -> PKDrawing {
        let blue = NSColor(red: 0.18, green: 0.44, blue: 0.88, alpha: 1)
        let red = NSColor(red: 0.85, green: 0.27, blue: 0.23, alpha: 1)
        let wave = (0...60).map { CGPoint(x: 120 + CGFloat($0) * 10, y: 220 + 4 * sin(CGFloat($0) / 5)) }
        let shaft = (0...50).map { CGPoint(x: 160 + CGFloat($0) * 10, y: 360 - CGFloat($0) * 0.6) }
        let head1 = (0...12).map { CGPoint(x: 600 + CGFloat($0) * 5, y: 300 + CGFloat($0) * 2.5) }
        let head2 = (0...12).map { CGPoint(x: 600 + CGFloat($0) * 5, y: 420 - CGFloat($0) * 7.5) }
        return PKDrawing(strokes: [
            DebugDrawing.stroke(wave, color: blue, width: 4),
            DebugDrawing.stroke(shaft, color: red, width: 5),
            DebugDrawing.stroke(head1, color: red, width: 5),
            DebugDrawing.stroke(head2, color: red, width: 5),
        ])
    }

    /// The app icon (test host = the app) as a small PNG.
    static func iconPNG(side: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSApp.applicationIconImage.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - Writing

    static func write(_ package: Package, to url: URL) throws {
        var wrappers: [String: FileWrapper] = [:]
        for (name, data) in package.files {
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = name
            wrappers[name] = wrapper
        }
        let wrapper = try MindMapPackage.fileWrapper(for: package.map, attachments: wrappers)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try wrapper.write(to: url, options: [.atomic], originalContentsURL: nil)
    }

    static var outputFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Samples", isDirectory: true)
    }
}

@MainActor
struct SampleMapGeneratorTests {
    /// Writes both sample packages, reads them back from disk and checks them.
    @Test func generateAndRoundTripSamples() throws {
        let folder = FeaturesSample.outputFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (roadmap, next) = FeaturesSample.roadmap()
        let features = FeaturesSample.features(roadmapTarget: next)
        let featuresURL = folder.appendingPathComponent(FeaturesSample.featuresFileName)
        let roadmapURL = folder.appendingPathComponent(FeaturesSample.roadmapFileName)
        try FeaturesSample.write(features, to: featuresURL)
        try FeaturesSample.write(roadmap, to: roadmapURL)
        print("SAMPLES \(folder.path)")

        for (package, url) in [(features, featuresURL), (roadmap, roadmapURL)] {
            let wrapper = try FileWrapper(url: url, options: .immediate)
            let decoded = try MindMapPackage.read(wrapper)
            #expect(try MindMapPackage.encode(decoded) == MindMapPackage.encode(package.map))
            let store = AttachmentStore(package: wrapper, referenced: decoded.referencedAttachmentFileNames)
            #expect(decoded.referencedAttachmentFileNames == Set(package.files.keys))
            for (name, data) in package.files { #expect(store.data(for: name) == data) }
        }

        let map = try MindMapPackage.read(FileWrapper(url: featuresURL, options: .immediate))
        // Every feature is present.
        #expect(map.root.children.count == 11)
        #expect(map.allTasks.count == 8 && map.openTaskCount == 4)
        #expect(map.relationships.count == 3 && map.boundaries.count == 2 && map.floatingTopics.count == 1)
        let all = allNodes(map)
        #expect(Set(all.compactMap(\.layoutStyle)) == Set(LayoutStyle.allCases.filter { $0 != .balancedMap }))
        #expect(all.contains { $0.isCollapsed } && all.contains { $0.manualPosition != nil })
        let kinds = Set(all.flatMap(\.attachments).map(\.kind))
        #expect(kinds == Set(AttachmentKind.allCases))
        let drawing = try #require(all.flatMap(\.attachments).first { $0.kind == .drawing })
        let data = try #require(AttachmentStore(package: try FileWrapper(url: featuresURL, options: .immediate))
            .data(for: drawing.fileName))
        #expect(HandwrittenNote.drawing(data).strokes.count == 4)
        let links = all.compactMap(\.link)
        #expect(links.contains { $0.webURL != nil } && links.contains { $0.mapReference != nil })
        for link in links { if let id = link.topicID { #expect(map.node(withID: id) != nil) } }
        let mapLink = try #require(links.compactMap(\.mapReference).first)
        #expect(MapPaths.resolve(try #require(mapLink.relativePath), from: featuresURL)?.lastPathComponent
            == FeaturesSample.roadmapFileName)
        // Relationship / boundary ends exist.
        for relationship in map.relationships {
            #expect(map.node(withID: relationship.fromNodeID) != nil && map.node(withID: relationship.toNodeID) != nil)
        }
    }

    /// Whole-map reference render (`<tmp>/Samples/features-map.png`); no
    /// topic overlaps another topic or the Tasks panel.
    @Test func renderFeaturesSnapshot() throws {
        let (_, next) = FeaturesSample.roadmap()
        let editor = EditorController(model: MindMapModel(map: FeaturesSample.features(roadmapTarget: next).map))
        editor.updateViewSize(CGSize(width: 1000, height: 800))
        let bounds = editor.contentBoundsIncludingPanel.insetBy(dx: -40, dy: -40)
        let size = CGSize(width: bounds.width.rounded(.up), height: bounds.height.rounded(.up))
        editor.updateViewSize(size)
        editor.viewport = Viewport(scale: 1, offset: CGPoint(x: (-bounds.minX).rounded(), y: (-bounds.minY).rounded()))
        let frames = editor.scene.layout.frames
        #expect(TestTree.overlappingPairs(frames) == 0)
        if let panel = editor.taskPanel {
            for frame in frames.values { #expect(!frame.intersects(panel.frame)) }
        }
        print("SNAPSHOT SIZE \(size)")
        let view = CanvasView(editor: editor).frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: FeaturesSample.outputFolder, withIntermediateDirectories: true)
        let url = FeaturesSample.outputFolder.appendingPathComponent("features-map.png")
        try png.write(to: url)
        print("SNAPSHOT \(url.path)")
    }

    private func allNodes(_ map: MindMap) -> [Node] {
        var result: [Node] = []
        func visit(_ node: Node) {
            result.append(node)
            node.children.forEach(visit)
        }
        visit(map.root)
        map.floatingTopics.forEach { visit($0.node) }
        return result
    }
}
#endif
