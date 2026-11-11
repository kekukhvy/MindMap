import UniformTypeIdentifiers

extension UTType {
    /// `.mindmap` package (directory with `map.json` + `attachments/`).
    /// Declared in Config/Info.plist (UTExportedTypeDeclarations).
    static let mindMap = UTType(exportedAs: "com.kekukh.mindmap", conformingTo: .package)
}
