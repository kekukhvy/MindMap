import Foundation

/// Names for new documents: "Untitled", "Untitled 2", "Untitled 3", ...
/// (first free one in the folder, compared case-insensitively because the
/// iOS/macOS file systems are case-insensitive by default).
enum UntitledName {
    static let base = "Untitled"

    /// File name (with extension) of the first free "Untitled[ n]" slot.
    static func next(existing fileNames: [String], pathExtension: String, base: String = base) -> String {
        let taken = Set(normalized(fileNames))
        var index = 1
        while true {
            let name = index == 1 ? base : "\(base) \(index)"
            let fileName = "\(name).\(pathExtension)"
            if !taken.contains(fileName.lowercased()) { return fileName }
            index += 1
        }
    }

    /// Lower-cased names; iCloud placeholders of items that are not
    /// downloaded yet (".Name.ext.icloud") count as the real name.
    static func normalized(_ fileNames: [String]) -> [String] {
        fileNames.map { name in
            var name = name
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
            }
            return name.lowercased()
        }
    }
}
