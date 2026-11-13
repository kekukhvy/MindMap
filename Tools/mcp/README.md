# mindmap-mcp

A small local MCP server (stdio) that lets Claude Code or Claude Desktop on the Mac read and edit your MindMap maps: list maps, read an outline, add / rename / move / delete topics, read and write notes. Edits use the app's own model code, so relationships, boundaries and the file format stay as the app writes them. No third-party code. On the iPad the changes arrive through the app's iCloud library sync.

## Build

    Tools/mcp/build.sh        # -> Tools/mcp/.build/mindmap-mcp
    Tools/mcp/test.sh         # drives the built binary over stdio on COPIES of Samples/

The build compiles the app's model sources in place (list in `model-sources.sh`) plus `Tools/mcp/Sources/`. It needs Xcode at `/Applications/Xcode.app`.

## Register (you do this, nothing is registered automatically)

Claude Code:

    claude mcp add --scope user mindmap -- /ABSOLUTE/PATH/TO/MindMap/Tools/mcp/.build/mindmap-mcp

Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`):

    { "mcpServers": { "mindmap": { "command": "/ABSOLUTE/PATH/TO/MindMap/Tools/mcp/.build/mindmap-mcp" } } }

macOS may ask once whether the host app may access data of another app (the MindMap container). Allow it.

## Tools

`list_maps`, `read_map`, `add_topics`, `rename_topic`, `move_topic`, `delete_topic`, `read_note`, `write_note`. A map is addressed by its map id (the folder name, shown by `list_maps`) or its exact name. Topics are addressed by the ids `read_map` prints. `add_topics` takes indented text (2 spaces or a tab per level); `- [ ] ` makes a task, as pasting text in the app does.

## Environment

- `MINDMAP_LIBRARY`: the maps folder. Default: `~/Library/Containers/com.kekukh.MindMap/Data/Library/Application Support/MindMap/Library/Maps` (library mode). The `Sync/` folder next to it is never touched.
- `MINDMAP_MCP_BACKUPS`: backup folder. Default: `~/Library/Application Support/mindmap-mcp/backups`.

## What is refused

- Locked maps (`lock.json`) and locked notes: never read or written.
- Read-only maps (Lock Editing): no writes.
- A map whose `formatVersion` is newer than this build knows: no reads, no writes (rebuild the server).
- Moving a topic into its own subtree; deleting the central topic.
- A write when `map.json` changed since the server last read the map ("map changed, read it again").

## Backups

Before each write the old `map.json` is copied to `<backups>/<map id>/<timestamp>-map.json`, and the old note file (when a note is replaced) to `<timestamp>-note-<file>`. The last 20 of each kind per map are kept. Backups live outside the map package, so they never sync.

## Known risk

If the map is open in the Mac app WITH UNSAVED EDITS while Claude writes it, one side loses: the app may save its older copy over the change, or ask about the conflict. Close the map window, or let it save, before asking Claude to edit it. A clean open window reloads the new file by itself. The server does not signal the app; the app uploads the change on its next sync scan (when you switch to it).
