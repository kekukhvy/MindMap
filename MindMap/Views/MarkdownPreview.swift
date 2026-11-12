import SwiftUI

/// Line-based Markdown blocks for a simple preview (headings, lists,
/// quotes, code fences, rules, paragraphs; inline styles via AttributedString).
/// Not a full CommonMark renderer.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(text: String, indent: Int)
    case numbered(marker: String, text: String, indent: Int)
    case task(done: Bool, text: String, indent: Int)
    case quote(String)
    case code(String)
    case rule
    case paragraph(String)
    case blank

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var codeLines: [String]?
        for raw in markdown.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = codeLines {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(raw)
                continue
            }
            let indent = (raw.prefix { $0 == " " || $0 == "\t" }.count) / 2
            if trimmed.isEmpty {
                blocks.append(.blank)
            } else if let heading = heading(trimmed) {
                blocks.append(heading)
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.rule)
            } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                blocks.append(.task(done: !trimmed.hasPrefix("- [ ]"), text: String(trimmed.dropFirst(6)), indent: indent))
            } else if let marker = ["- ", "* ", "+ "].first(where: trimmed.hasPrefix) {
                blocks.append(.bullet(text: String(trimmed.dropFirst(marker.count)), indent: indent))
            } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
                      trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                blocks.append(.numbered(marker: String(trimmed[...dot]),
                                        text: String(trimmed[trimmed.index(dot, offsetBy: 2)...]), indent: indent))
            } else if trimmed.hasPrefix(">") {
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        if let lines = codeLines { blocks.append(.code(lines.joined(separator: "\n"))) }
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
    }
}

struct MarkdownPreview: View {
    let text: String

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
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
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
        case let .quote(text):
            inline(text).foregroundStyle(.secondary).italic()
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case let .code(code):
            Text(code).font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
        case .rule:
            Divider().padding(.vertical, 4)
        case let .paragraph(text):
            inline(text)
        case .blank:
            Color.clear.frame(height: 4)
        }
    }

    private func listRow(marker: Text, text: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker.foregroundStyle(.secondary)
            inline(text)
        }
        .padding(.leading, CGFloat(indent) * 18 + 4)
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
