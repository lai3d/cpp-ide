import Foundation

/// Finds the C/C++ toolchain. GUI apps launched from Finder get a minimal PATH, so we also
/// look in Homebrew (including keg-only LLVM) and ask `xcrun` for Xcode's tools (lldb-dap).
public enum ToolLocator {
    public static func searchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                 "/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin",
                 "/Applications/CMake.app/Contents/bin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// UserDefaults key for a user-chosen tool path (set in Settings).
    public static func overrideKey(for name: String) -> String { "toolPath.\(name)" }

    public static func find(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let custom = UserDefaults.standard.string(forKey: overrideKey(for: name))?
            .trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            let path = (custom as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for dir in searchDirectories(environment: environment) {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return xcrunFind(name)
    }

    private static let xcrunCache = XcrunCache()

    /// `xcrun -f name` (Xcode / Command Line Tools), cached per name.
    public static func xcrunFind(_ name: String) -> URL? {
        if let cached = xcrunCache.get(name) { return cached }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["-f", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL? = process.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: path)
            ? URL(fileURLWithPath: path) : nil
        xcrunCache.set(name, url)
        return url
    }

    /// The current environment with PATH widened to every search directory,
    /// so child processes (clangd, cmake, the compilers) can find each other.
    public static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        env["PATH"] = searchDirectories(environment: base).joined(separator: ":")
        return env
    }
}

private final class XcrunCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: URL?] = [:]
    func get(_ name: String) -> URL? { lock.withLock { values[name] ?? nil } }
    func set(_ name: String, _ url: URL?) { lock.withLock { values[name] = url } }
}

public extension URL {
    /// The canonical file URL as the OS (and clangd) sees it: symlinks resolved and
    /// `/tmp` → `/private/tmp`. Unlike `resolvingSymlinksInPath()`, keeps `/private`.
    var canonicalFileURL: URL {
        guard isFileURL, let resolved = realpath(path, nil) else { return standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: hasDirectoryPath)
    }
}
