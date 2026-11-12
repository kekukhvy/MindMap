import Foundation

/// Where a topic links to: a web URL, another topic of the same map (main
/// tree or floating) or another map file (WP10). JSON:
/// `{"kind":"web","url":"https://…"}` / `{"kind":"topic","topicID":"<UUID>"}`
/// / `{"kind":"map","path":"Other.mindmap","bookmark":"<base64>","name":"Other","topicID":"<UUID>"}`.
/// A link this version does not understand (newer kind, bad value) is kept
/// verbatim as `.unknown` — written back unchanged on save, but treated as
/// "no link" everywhere else (`MindMap.link(of:)`).
enum TopicLink: Equatable, Hashable, Codable {
    case web(URL)
    case topic(UUID)
    case map(MapReference)
    case unknown(JSONValue)

    private enum CodingKeys: String, CodingKey {
        case kind, url, topicID, path, bookmark, name
    }

    private enum Kind: String, Codable {
        case web, topic, map
    }

    init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        self = (try? Self.decodeKnown(from: decoder)) ?? .unknown(raw)
    }

    private static func decodeKnown(from decoder: Decoder) throws -> TopicLink {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .web:
            let string = try c.decode(String.self, forKey: .url)
            guard let url = URL(string: string) else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "Invalid URL")
            }
            return .web(url)
        case .topic:
            return .topic(try c.decode(UUID.self, forKey: .topicID))
        case .map:
            let reference = MapReference(relativePath: try c.decodeIfPresent(String.self, forKey: .path),
                                         bookmark: try c.decodeIfPresent(Data.self, forKey: .bookmark),
                                         displayName: try c.decodeIfPresent(String.self, forKey: .name),
                                         targetTopicID: try c.decodeIfPresent(UUID.self, forKey: .topicID))
            guard reference.isUsable else {
                throw DecodingError.dataCorruptedError(forKey: .path, in: c, debugDescription: "No path or bookmark")
            }
            return .map(reference)
        }
    }

    func encode(to encoder: Encoder) throws {
        if case let .unknown(raw) = self {
            try raw.encode(to: encoder)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .web(url):
            try c.encode(Kind.web, forKey: .kind)
            try c.encode(url.absoluteString, forKey: .url)
        case let .topic(id):
            try c.encode(Kind.topic, forKey: .kind)
            try c.encode(id, forKey: .topicID)
        case let .map(reference):
            try c.encode(Kind.map, forKey: .kind)
            try c.encodeIfPresent(reference.relativePath, forKey: .path)
            try c.encodeIfPresent(reference.bookmark, forKey: .bookmark)
            try c.encode(reference.displayName, forKey: .name)
            try c.encodeIfPresent(reference.targetTopicID, forKey: .topicID)
        case .unknown:
            break
        }
    }

    var webURL: URL? {
        if case let .web(url) = self { return url }
        return nil
    }

    var topicID: UUID? {
        if case let .topic(id) = self { return id }
        return nil
    }

    var mapReference: MapReference? {
        if case let .map(reference) = self { return reference }
        return nil
    }

    /// A kind this version understands (not `.unknown`).
    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

/// Turns what the user typed into a web link URL (pure, unit-tested).
enum LinkURL {
    /// Trims, adds "https://" when no scheme is given ("example.com/a" ->
    /// "https://example.com/a"; "localhost:8080" is host:port, not a scheme)
    /// and validates. Returns nil for empty or invalid input.
    static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let text = hasScheme(trimmed) ? trimmed : "https://" + trimmed.drop { $0 == "/" }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host(percentEncoded: false), isValidHost(host) else { return nil }
        } else if url.absoluteString.count <= scheme.count + 1 {
            return nil // "mailto:" without anything after it
        }
        return url
    }

    /// "scheme:" prefix per RFC 3986, but "host:port" (digits) is no scheme.
    static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else {
            return false
        }
        let rest = text[text.index(after: colon)...]
        if rest.hasPrefix("//") { return true }
        // "localhost:8080/x" / "example.com:443": a port, not a scheme.
        let port = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if !port.isEmpty, port.allSatisfy(\.isNumber) { return false }
        return !scheme.contains(".")
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { return false }
        if host == "localhost" || host.contains(".") || host.contains(":") { return true }
        return false
    }

    /// Short text for menus: host + path without the scheme ("example.com/a").
    static func displayString(_ url: URL) -> String {
        guard let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else {
            return url.absoluteString
        }
        var text = url.absoluteString
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
