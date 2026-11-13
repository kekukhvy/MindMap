import Foundation

// mindmap-mcp: MCP server over stdio (newline-delimited JSON-RPC 2.0).
// stdout carries protocol messages only; logs go to stderr.

setvbuf(stdout, nil, _IOLBF, 0)
let server = McpServer(tools: ToolHandlers(library: MapLibrary()))
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    if let reply = server.handle(line: line) {
        print(reply)
    }
}
