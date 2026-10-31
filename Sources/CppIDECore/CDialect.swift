import Foundation

/// Which languages a project's sources are written in. Decides how `.h` files are treated
/// (C or C++) and which snippets are offered.
public enum SourceDialect: Sendable, Hashable {
    /// Only C sources (`.c`): headers are C.
    case c
    /// Only C++ sources: headers are C++.
    case cxx
    /// Both, Objective-C / CUDA, or no sources: leave headers to clangd's own guess.
    case mixed

    /// Scans the project's sources (skipping build output and VCS/vendor folders).
    public static func detect(root: URL) -> SourceDialect {
        detect(paths: ProjectSearch.files(under: root))
    }

    public static func detect(paths: [String]) -> SourceDialect {
        var hasC = false, hasCxx = false
        for path in paths {
            let ext = (path as NSString).pathExtension.lowercased()
            switch ext {
            case "c": hasC = true
            case "cc", "cpp", "cxx", "c++": hasCxx = true
            // Objective-C(++) / CUDA: a C or C++ -std in the fallback flags would break them.
            case "m", "mm", "cu": return .mixed
            default: continue
            }
            if hasC && hasCxx { return .mixed }
        }
        return hasC ? .c : hasCxx ? .cxx : .mixed
    }

    /// Whether `url` should be edited as C: `.c` files always, headers only in C projects.
    public func isC(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "c" { return true }
        return self == .c && SourceKind.headerExtensions.contains(ext)
    }
}

/// The `-std=` used for single-file builds and for clangd's fallback flags (Settings ▸ Toolchain).
public struct LanguageStandards: Sendable, Hashable {
    public var c: String
    public var cxx: String

    public static let cKey = "cStandard"
    public static let cxxKey = "cxxStandard"
    public static let `default` = LanguageStandards(c: "c17", cxx: "c++20")
    public static let cChoices = ["c89", "c99", "c11", "c17", "c23", "gnu99", "gnu11", "gnu17", "gnu23"]
    public static let cxxChoices = ["c++11", "c++14", "c++17", "c++20", "c++23", "c++26", "gnu++17", "gnu++20", "gnu++23"]

    public init(c: String, cxx: String) {
        self.c = c
        self.cxx = cxx
    }

    /// The user's choice, from UserDefaults.
    public static var current: LanguageStandards {
        let defaults = UserDefaults.standard
        return LanguageStandards(c: defaults.string(forKey: cKey).flatMap { $0.isEmpty ? nil : $0 } ?? Self.default.c,
                                 cxx: defaults.string(forKey: cxxKey).flatMap { $0.isEmpty ? nil : $0 } ?? Self.default.cxx)
    }
}

/// Maps a test source file to the CTest tests that run its executable, so a Unity / CMocka test
/// function (which ctest doesn't know by name) can run just the tests built from its file.
public enum CTestIndex {
    /// Names of the ctest tests whose command runs an executable built from `source`.
    /// Empty when the project isn't configured or the CMake file API has no reply yet.
    public static func tests(forSource source: URL, root: URL, buildDirectory: URL, ctest: URL) -> [String] {
        let artifacts = Set(CMakeFileAPI.executables(withSource: source, root: root, buildDirectory: buildDirectory)
            .map(\.canonicalFileURL.path))
        guard !artifacts.isEmpty else { return [] }
        return listTests(buildDirectory: buildDirectory, ctest: ctest)
            .filter { artifacts.contains(URL(fileURLWithPath: $0.executable).canonicalFileURL.path) }
            .map(\.name)
    }

    /// `ctest --show-only=json-v1`: every test with the program it runs.
    public static func listTests(buildDirectory: URL, ctest: URL) -> [(name: String, executable: String)] {
        let process = Process()
        process.executableURL = ctest
        process.arguments = ["--test-dir", buildDirectory.path, "--show-only=json-v1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseTestList(data)
    }

    public static func parseTestList(_ data: Data) -> [(name: String, executable: String)] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let tests = json["tests"]?.arrayValue else { return [] }
        return tests.compactMap { test in
            guard let name = test["name"]?.stringValue,
                  let program = test["command"]?[0]?.stringValue else { return nil }
            return (name, program)
        }
    }

    /// An anchored ctest `-R` regex matching exactly these names.
    public static func filter(_ names: [String]) -> String {
        "^(" + names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")$"
    }
}
