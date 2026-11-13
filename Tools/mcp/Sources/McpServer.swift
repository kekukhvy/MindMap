import Foundation

/// JSON-RPC 2.0 / MCP dispatch: initialize, notifications, tools/list,
/// tools/call and ping. One message in, at most one reply out.
final class McpServer {
    static let defaultProtocolVersion = "2025-06-18"
    static let serverName = "mindmap-mcp"
    static let serverVersion = "1.0.0"

    private enum ErrorCode {
        static let parse = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
    }

    private let tools: ToolHandlers

    init(tools: ToolHandlers) {
        self.tools = tools
    }

    func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return failure(id: NSNull(), code: ErrorCode.parse, message: "Parse error")
        }
        guard let message = object as? [String: Any], let method = message["method"] as? String else {
            return failure(id: NSNull(), code: ErrorCode.invalidRequest, message: "Invalid request")
        }
        // No id = notification: never answered.
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return success(id: id, result: initializeResult(params))
        case "ping":
            return success(id: id, result: [:])
        case "tools/list":
            return success(id: id, result: ["tools": ToolCatalog.tools])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return failure(id: id, code: ErrorCode.invalidParams, message: "Missing tool name")
            }
            return success(id: id, result: callTool(name, params["arguments"] as? [String: Any] ?? [:]))
        default:
            return failure(id: id, code: ErrorCode.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func initializeResult(_ params: [String: Any]) -> [String: Any] {
        [
            "protocolVersion": params["protocolVersion"] as? String ?? McpServer.defaultProtocolVersion,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": McpServer.serverName, "version": McpServer.serverVersion],
        ]
    }

    private func callTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        do {
            return toolResult(try tools.call(name, arguments), isError: false)
        } catch let error as ToolError {
            return toolResult(error.message, isError: true)
        } catch {
            return toolResult("Unexpected error: \(error)", isError: true)
        }
    }

    private func toolResult(_ text: String, isError: Bool) -> [String: Any] {
        var result: [String: Any] = ["content": [["type": "text", "text": text]]]
        if isError { result["isError"] = true }
        return result
    }

    private func success(id: Any, result: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func failure(id: Any, code: Int, message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// A refusal or failure reported to the client as `isError: true`.
struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
