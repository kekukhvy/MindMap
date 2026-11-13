import Foundation

/// Pure rules of the inline topic editor's multi-line input: Return commits,
/// Shift+Return / Option+Return insert a line break (the topic wraps and
/// keeps up to `NodeMeasurer.maxLines` lines on the canvas).
enum TopicTextInput {
    enum ReturnAction: Equatable {
        case commit
        case newline
    }

    /// What a Return key press does in the topic editor.
    static func returnAction(shift: Bool, option: Bool) -> ReturnAction {
        shift || option ? .newline : .commit
    }

    enum Change: Equatable {
        /// Normal edit: take the new text.
        case text(String)
        /// A bare Return reached the multi-line field (iPad software keyboard,
        /// or a key press the handler did not see) and inserted "\n" (maybe
        /// over a selection): commit the text as it was before.
        case returnPressed
    }

    /// Classifies a text field update from `old` to `new`. Exactly one
    /// inserted line break (nothing else typed) is a Return press unless
    /// `expectsNewline` (Shift/Option+Return asked the field for one).
    static func classify(old: String, new: String, expectsNewline: Bool) -> Change {
        guard !expectsNewline, insertedText(old: old, new: new) == "\n" else { return .text(new) }
        return .returnPressed
    }

    /// The text that replaced a (possibly empty) range of `old` in `new`.
    static func insertedText(old: String, new: String) -> String {
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return String(b[prefix..<(b.count - suffix)])
    }

    /// Text stored on commit: line breaks at the start / end are dropped
    /// (a stray Shift+Return), inner ones kept; "\r\n" / "\r" become "\n".
    static func committed(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var scalars = Substring(unified)
        while scalars.first == "\n" { scalars.removeFirst() }
        while scalars.last == "\n" { scalars.removeLast() }
        return String(scalars)
    }

    /// One-line form for places that show a topic in a single line
    /// (menus, breadcrumbs, lists, file names, Markdown bullets).
    static func singleLine(_ text: String) -> String {
        committed(text).split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }
}
