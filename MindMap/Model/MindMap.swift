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

    init(
        root: Node = Node(text: "Central Topic"),
        theme: ColorTheme = .rainbow,
        floatingTopics: [FloatingTopic] = [],
        relationships: [Relationship] = [],
        boundaries: [Boundary] = [],
        taskPanel: TaskPanelState? = nil
    ) {
        self.formatVersion = MindMap.currentFormatVersion
        self.root = root
        self.theme = theme
        self.floatingTopics = floatingTopics
        self.relationships = relationships
        self.boundaries = boundaries
        self.taskPanel = taskPanel
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, root, theme, floatingTopics, relationships, boundaries, taskPanel
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
    }
}
