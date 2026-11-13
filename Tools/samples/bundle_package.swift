// Writes one .mindmap package folder as a single JSON resource for the app
// (format = `SamplePackageArchive` in MindMap/Document/SampleMaps.swift):
// {"files": {"<path in package>": "<base64>"}, "name": "<package name>"}.
// Usage: xcrun swift Tools/samples/bundle_package.swift <package.mindmap> <out.json>
import Foundation

struct Archive: Codable {
    var name: String
    var files: [String: Data]
}

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: bundle_package.swift <package.mindmap> <out.json>\n".data(using: .utf8)!)
    exit(2)
}
let package = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
let base = package.path + "/"
var files: [String: Data] = [:]
let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey])
while let item = enumerator?.nextObject() as? URL {
    guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
          item.lastPathComponent != ".DS_Store" else { continue }
    let path = item.standardizedFileURL.resolvingSymlinksInPath().path
    guard path.hasPrefix(base) else { continue }
    files[String(path.dropFirst(base.count))] = try Data(contentsOf: item)
}
guard files["map.json"] != nil else { fatalError("no map.json in \(package.path)") }
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let name = package.deletingPathExtension().lastPathComponent
try encoder.encode(Archive(name: name, files: files)).write(to: URL(fileURLWithPath: args[2]))
print("\(args[2]): \(name), \(files.count) files")
