import Foundation

/// The persisted document content (`map.json`): one central root topic plus
/// map-level items. All fields except `root` are optional in the file.
struct MindMap: Equatable, Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var root: Node
    var theme: ColorTheme
    var floatingTopics: [FloatingTopic]
    var relationships: [Relationship]
    var boundaries: [Boundary]
    /// Position / collapse of the virtual Tasks panel (nil = defaults).
    var taskPanel: TaskPanelState?
    /// Name of a library map (WP14b; files are named by their file name).
    /// nil = not set: listings fall back to the central topic text.
    var title: String?
    /// "Lock Editing" (WP15): the map opens read-only until unlocked.
    /// Stored as `"isReadOnly": true`, omitted when off (older files and
    /// builds unaffected). Not the WP12 biometric lock.
    var isReadOnly: Bool {
        get { readOnlyFlag == true }
        set { readOnlyFlag = newValue ? true : nil }
    }
    private var readOnlyFlag: Bool?

    init(
        root: Node = Node(text: "Central Topic"),
        theme: ColorTheme = .rainbow,
        floatingTopics: [FloatingTopic] = [],
        relationships: [Relationship] = [],
        boundaries: [Boundary] = [],
        taskPanel: TaskPanelState? = nil,
        title: String? = nil,
        isReadOnly: Bool = false
    ) {
        self.formatVersion = MindMap.currentFormatVersion
        self.root = root
        self.theme = theme
        self.floatingTopics = floatingTopics
        self.relationships = relationships
        self.boundaries = boundaries
        self.taskPanel = taskPanel
        self.title = title
        self.isReadOnly = isReadOnly
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, root, theme, floatingTopics, relationships, boundaries, taskPanel, title
        case readOnlyFlag = "isReadOnly"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? MindMap.currentFormatVersion
        root = try c.decode(Node.self, forKey: .root)
        theme = (try? c.decodeIfPresent(ColorTheme.self, forKey: .theme)) ?? .rainbow
        floatingTopics = try c.decodeIfPresent([FloatingTopic].self, forKey: .floatingTopics) ?? []
        relationships = try c.decodeIfPresent([Relationship].self, forKey: .relationships) ?? []
        boundaries = try c.decodeIfPresent([Boundary].self, forKey: .boundaries) ?? []
        taskPanel = (try? c.decodeIfPresent(TaskPanelState.self, forKey: .taskPanel)) ?? nil
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        readOnlyFlag = (try? c.decodeIfPresent(Bool.self, forKey: .readOnlyFlag)) == true ? true : nil
    }
}
