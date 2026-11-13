import Foundation

/// Drives the REAL built binary over stdio (newline-delimited JSON-RPC).
final class McpClient {
    struct Reply {
        let text: String
        let isError: Bool
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 1

    init(binary: URL, environment: [String: String]) throws {
        process.executableURL = binary
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    deinit {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    /// Sends a request and returns the whole JSON-RPC response object.
    func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        guard let reply = try readLine() as? [String: Any] else { throw TestFailure("reply is not an object") }
        return reply
    }

    func notify(_ method: String) throws {
        try send(["jsonrpc": "2.0", "method": method])
    }

    func call(_ tool: String, _ args: [String: Any] = [:]) throws -> Reply {
        let response = try request("tools/call", ["name": tool, "arguments": args])
        guard let result = response["result"] as? [String: Any],
              let content = (result["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String else { throw TestFailure("bad tools/call reply: \(response)") }
        return Reply(text: text, isError: result["isError"] as? Bool ?? false)
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        input.fileHandleForWriting.write(data)
    }

    private func readLine() throws -> Any {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return try JSONSerialization.jsonObject(with: line)
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw TestFailure("server closed stdout") }
            buffer.append(chunk)
        }
    }
}

struct TestFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw TestFailure(message()) }
}

/// Temp library holding COPIES of the Samples (never the real library).
final class Fixture {
    static let roadmapID = "11111111-0000-0000-0000-000000000001"
    static let featuresID = "11111111-0000-0000-0000-000000000002"
    static let repo = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    static let binary = URL(fileURLWithPath: CommandLine.arguments[2])

    let root: URL
    var maps: URL { root.appendingPathComponent("Maps") }
    var backups: URL { root.appendingPathComponent("backups") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mindmap-mcp-test-" + UUID().uuidString)
        for (id, name) in [(Fixture.roadmapID, "MindMap Roadmap"), (Fixture.featuresID, "MindMap Features")] {
            let folder = maps.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Fixture.repo.appendingPathComponent("Samples/\(name).mindmap"),
                                             to: folder.appendingPathComponent("\(name).mindmap"))
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func package(_ id: String) -> URL {
        let folder = maps.appendingPathComponent(id)
        let name = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.first { $0.hasSuffix(".mindmap") } ?? ""
        return folder.appendingPathComponent(name)
    }

    func mapURL(_ id: String) -> URL { package(id).appendingPathComponent("map.json") }
    func mapData(_ id: String) throws -> Data { try Data(contentsOf: mapURL(id)) }
    /// map.json decoded with the app's own decoder.
    func map(_ id: String) throws -> MindMap { try MindMapPackage.decode(try mapData(id)) }
    func save(_ map: MindMap, _ id: String) throws { try MindMapPackage.encode(map).write(to: mapURL(id)) }

    func client() throws -> McpClient {
        try McpClient(binary: Fixture.binary, environment: [
            "MINDMAP_LIBRARY": maps.path, "MINDMAP_MCP_BACKUPS": backups.path,
        ])
    }

    func backupNames(_ id: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backups.appendingPathComponent(id).path)) ?? []).sorted()
    }
}

extension MindMap {
    func topic(_ text: String) -> Node? {
        trees.lazy.flatMap { $0.nodesWithDepth() }.first { $0.0.text == text }?.0
    }
}
