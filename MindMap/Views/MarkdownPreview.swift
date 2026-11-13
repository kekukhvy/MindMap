import SwiftUI

/// Line-based Markdown blocks for the note preview: ATX and setext
/// headings, bullet / numbered / task lists (nested by indent), nested
/// quotes, fenced code (``` or ~~~), rules, GitHub / Obsidian pipe tables,
/// paragraphs; inline styles (bold, italic, ~~strike~~, `code`, links) via
/// AttributedString, images shown by their alt text. Not a full CommonMark
/// renderer, but what Obsidian-style notes use.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(text: String, indent: Int)
    case numbered(marker: String, text: String, indent: Int)
    case task(done: Bool, text: String, indent: Int)
    case quote(String, level: Int)
    case code(String)
    case rule
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    case paragraph(String)
    /// A line that is only `![alt](attachments/<file>)`.
    case image(alt: String, fileName: String)
    case blank

    enum TableAlignment: Equatable {
        case leading, center, trailing
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var code: (fence: String, lines: [String])?
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let open = code {
                if trimmed.hasPrefix(open.fence) {
                    blocks.append(.code(open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code?.lines.append(raw)
                }
                continue
            }
            if let fence = ["```", "~~~"].first(where: trimmed.hasPrefix) {
                code = (fence, [])
                continue
            }
            let indent = indentLevel(raw)
            if trimmed.isEmpty {
                blocks.append(.blank)
            } else if let table = table(at: index - 1, in: lines) {
                blocks.append(table.block)
                index = table.next
            } else if case let .paragraph(text)? = blocks.last, isSetextUnderline(trimmed, "=") {
                blocks[blocks.count - 1] = .heading(level: 1, text: text)
            } else if case let .paragraph(text)? = blocks.last, isSetextUnderline(trimmed, "-") {
                blocks[blocks.count - 1] = .heading(level: 2, text: text)
            } else if let heading = heading(trimmed) {
                blocks.append(heading)
            } else if isRule(trimmed) {
                blocks.append(.rule)
            } else if let task = task(trimmed) {
                blocks.append(.task(done: task.done, text: task.text, indent: indent))
            } else if let marker = ["- ", "* ", "+ "].first(where: trimmed.hasPrefix) {
                blocks.append(.bullet(text: String(trimmed.dropFirst(marker.count)), indent: indent))
            } else if let numbered = numbered(trimmed) {
                blocks.append(.numbered(marker: numbered.marker, text: numbered.text, indent: indent))
            } else if trimmed.hasPrefix(">") {
                var level = 0
                var rest = Substring(trimmed)
                while rest.hasPrefix(">") {
                    level += 1
                    rest = rest.dropFirst().drop(while: { $0 == " " })
                }
                blocks.append(.quote(String(rest), level: level))
            } else if let image = image(trimmed) {
                blocks.append(image)
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        if let open = code { blocks.append(.code(open.lines.joined(separator: "\n"))) }
        return blocks
    }

    private static func image(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("!["), line.hasSuffix(")"), let close = line.range(of: "]("),
              !line[close.upperBound...].dropLast().contains(")"),
              let fileName = NoteImage.fileName(fromLinkTarget: String(line[close.upperBound...].dropLast())) else {
            return nil
        }
        return .image(alt: String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound]), fileName: fileName)
    }

    /// Two spaces or one tab per nesting level.
    private static func indentLevel(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 2 } else { break }
        }
        return width / 2
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") || line.count == hashes else { return nil }
        var text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        // Closing hashes: "## Title ##".
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isSetextUnderline(_ line: String, _ mark: Character) -> Bool {
        line.count >= 2 && line.allSatisfy { $0 == mark }
    }

    private static func task(_ line: String) -> (done: Bool, text: String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet + "[") {
            let rest = line.dropFirst(bullet.count)
            guard rest.count >= 3, rest.dropFirst(2).hasPrefix("]") else { continue }
            let mark = rest[rest.index(after: rest.startIndex)]
            guard mark == " " || mark == "x" || mark == "X" else { continue }
            return (mark != " ", String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func numbered(_ line: String) -> (marker: String, text: String)? {
        guard let end = line.firstIndex(where: { $0 == "." || $0 == ")" }), end > line.startIndex,
              line[..<end].allSatisfy(\.isNumber), line[line.index(after: end)...].hasPrefix(" ") else { return nil }
        return (String(line[...end]), String(line[line.index(end, offsetBy: 2)...]))
    }

    /// A pipe table starting at `start`: header row, delimiter row
    /// (`|---|:---:|`), then rows until a line without a pipe.
    private static func table(at start: Int, in lines: [String]) -> (block: MarkdownBlock, next: Int)? {
        guard start + 1 < lines.count, lines[start].contains("|") else { return nil }
        let header = cells(lines[start])
        let delimiter = cells(lines[start + 1])
        guard header.count >= 1, delimiter.count == header.count,
              delimiter.allSatisfy({ cell in
                  let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                  return core.count >= 1 && core.allSatisfy { $0 == "-" }
              }) else { return nil }
        let alignments: [TableAlignment] = delimiter.map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .trailing
            default: return .leading
            }
        }
        var rows: [[String]] = []
        var next = start + 2
        while next < lines.count, lines[next].contains("|"),
              !lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
            var row = cells(lines[next])
            row = Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count))
            rows.append(row)
            next += 1
        }
        return (.table(header: header, alignments: alignments, rows: rows), next)
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        return text.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Inline Markdown with images shown as "🖼 alt" (no image loading).
    static func inlineSource(_ text: String) -> String {
        guard text.contains("![") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "!["), let close = rest[open.upperBound...].range(of: "]("),
              let end = rest[close.upperBound...].firstIndex(of: ")") {
            result += rest[..<open.lowerBound]
            let alt = rest[open.upperBound..<close.lowerBound]
            result += "🖼 " + (alt.isEmpty ? "image" : alt)
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }
}

struct MarkdownPreview: View {
    let text: String
    /// Bytes of a file in `attachments/` (nil = unknown): images are drawn
    /// from it, anything else stays its alt text.
    var imageData: (String) -> Data? = { _ in nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .textSelection(.enabled)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let source = MarkdownBlock.inlineSource(text)
        return Text((try? AttributedString(markdown: source, options: options)) ?? AttributedString(source))
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text).font(headingFont(level)).padding(.top, level <= 2 ? 6 : 2)
        case let .bullet(text, indent):
            listRow(marker: Text("•"), text: text, indent: indent)
        case let .numbered(marker, text, indent):
            listRow(marker: Text(marker).monospacedDigit(), text: text, indent: indent)
        case let .task(done, text, indent):
            listRow(marker: Text(Image(systemName: done ? "checkmark.square" : "square")), text: text, indent: indent)
        case let .quote(text, level):
            inline(text).foregroundStyle(.secondary).italic()
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
                .padding(.leading, CGFloat(level - 1) * 13)
        case let .table(header, alignments, rows):
            tableView(header: header, alignments: alignments, rows: rows)
        case let .code(code):
            Text(code).font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
        case .rule:
            Divider().padding(.vertical, 4)
        case let .paragraph(text):
            inline(text)
        case let .image(alt, fileName):
            if let (image, size) = imageData(fileName).flatMap(Self.image(from:)) {
                // Natural size, shrunk to the pane width.
                image.resizable().scaledToFit().frame(maxWidth: size.width).accessibilityLabel(alt)
            } else {
                inline("![\(alt)](\(NoteImage.linkFolder)\(fileName))")
            }
        case .blank:
            Color.clear.frame(height: 4)
        }
    }

    static func image(from data: Data) -> (Image, CGSize)? {
        #if os(macOS)
        NSImage(data: data).map { (Image(nsImage: $0), $0.size) }
        #else
        UIImage(data: data).map { (Image(uiImage: $0), $0.size) }
        #endif
    }

    private func listRow(marker: Text, text: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker.foregroundStyle(.secondary)
            inline(text)
        }
        .padding(.leading, CGFloat(indent) * 18 + 4)
    }

    /// Pipe table: bold header, hairline grid, columns aligned as declared;
    /// scrolls sideways when wider than the note.
    private func tableView(header: [String], alignments: [MarkdownBlock.TableAlignment], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        tableCell(cell, alignment: alignments[column]).bold()
                            .background(Color.secondary.opacity(0.08))
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            tableCell(cell, alignment: alignments[column])
                        }
                    }
                }
            }
            .overlay(Rectangle().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
        }
        .padding(.vertical, 4)
    }

    private func tableCell(_ text: String, alignment: MarkdownBlock.TableAlignment) -> some View {
        let frameAlignment: Alignment
        switch alignment {
        case .leading: frameAlignment = .leading
        case .center: frameAlignment = .center
        case .trailing: frameAlignment = .trailing
        }
        return inline(text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minWidth: 60, maxWidth: .infinity, alignment: frameAlignment)
            .overlay(Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.weight(.semibold)
        default: return .headline
        }
    }
}
