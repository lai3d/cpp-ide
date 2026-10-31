import Foundation

/// A node in the project file tree.
public struct FileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    /// `nil` for files, so outline views show no disclosure triangle.
    public var children: [FileNode]?

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public static let ignoredNames: Set<String> = [".git", ".build", ".idea", ".vscode", "node_modules", "CMakeFiles"]

    /// Top-level CMake binary dirs (`build`, `cmake-build-debug`, `out`): shown in the tree,
    /// but skipped when searching and scanning for targets.
    public static func isBuildOutput(_ url: URL, root: URL) -> Bool {
        guard url.deletingLastPathComponent().canonicalFileURL.path == root.canonicalFileURL.path else { return false }
        let name = url.lastPathComponent
        return name == "build" || name == "out" || name.hasPrefix("cmake-build-")
    }

    public init(url: URL, isDirectory: Bool, children: [FileNode]?) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
    }

    public static func loadTree(at root: URL, maxDepth: Int = 12) -> [FileNode] {
        loadChildren(of: root, depth: 0, maxDepth: maxDepth)
    }

    private static func loadChildren(of directory: URL, depth: Int, maxDepth: Int) -> [FileNode] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        return items
            .filter { !ignoredNames.contains($0.lastPathComponent) }
            .map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let children = isDir ? (depth < maxDepth ? loadChildren(of: url, depth: depth + 1, maxDepth: maxDepth) : []) : nil
                return FileNode(url: url, isDirectory: isDir, children: children)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
}
