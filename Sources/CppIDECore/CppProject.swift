import Foundation

/// One process to run as part of a build/run pipeline.
public struct Command: Sendable, Hashable {
    public var executable: URL
    public var arguments: [String]
    public var directory: URL
    public var environment: [String: String]

    public init(executable: URL, arguments: [String], directory: URL, environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
    }

    /// Shell-style echo for the Output panel.
    public var display: String {
        ([executable.lastPathComponent] + arguments).map { word in
            word.isEmpty || word.contains(where: { $0 == " " || $0 == "\"" }) ? "\"\(word)\"" : word
        }.joined(separator: " ")
    }
}

/// How a project folder is built.
public enum BuildSystem: String, Sendable, Hashable {
    case cmake, make, plain

    public static func detect(at root: URL) -> BuildSystem {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("CMakeLists.txt").path) { return .cmake }
        for name in ["Makefile", "makefile", "GNUmakefile"]
        where fm.fileExists(atPath: root.appendingPathComponent(name).path) {
            return .make
        }
        return .plain
    }

    public var displayName: String {
        switch self {
        case .cmake: "CMake"
        case .make: "Make"
        case .plain: "Single files"
        }
    }
}

/// Build/run knowledge for a C/C++ project folder: targets, build directory and commands.
public struct CppProject: Sendable {
    public let root: URL
    public let buildSystem: BuildSystem

    /// CMake's binary dir. clangd looks for `build/compile_commands.json` on its own.
    public var buildDirectory: URL { root.appendingPathComponent("build") }

    public init(root: URL, buildSystem: BuildSystem? = nil) {
        self.root = root
        self.buildSystem = buildSystem ?? .detect(at: root)
    }

    // MARK: Targets

    /// Things that can be run: CMake executable targets, else source files that define `main`.
    public func runnableTargets() -> [String] {
        switch buildSystem {
        case .cmake: Self.cmakeExecutables(under: root)
        case .make, .plain: Self.mainSources(under: root)
        }
    }

    private static let addExecutable = try! NSRegularExpression(
        pattern: #"(?i)\badd_executable\s*\(\s*([A-Za-z0-9_.+\-]+)"#)

    /// Names from `add_executable(name …)` in every CMakeLists.txt (skips IMPORTED / ALIAS targets).
    public static func cmakeExecutables(under root: URL) -> [String] {
        var names: [String] = []
        for path in ProjectSearch.files(under: root) where (path as NSString).lastPathComponent == "CMakeLists.txt" {
            guard !isInBuildTree(path, root: root),
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let stripped = stripCMakeComments(text)
            let ns = stripped as NSString
            for match in addExecutable.matches(in: stripped, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1))
                let rest = ns.substring(from: NSMaxRange(match.range)).prefix(40)
                if rest.contains("IMPORTED") || rest.contains("ALIAS") || name.hasPrefix("$") { continue }
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    private static func stripCMakeComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let hash = line.firstIndex(of: "#") else { return line }
            return line[..<hash]
        }.joined(separator: "\n")
    }

    private static let mainDeclaration = try! NSRegularExpression(
        pattern: #"^\s*(?:int|auto|void)\s+main\s*\("#, options: .anchorsMatchLines)

    /// Project-relative source files declaring `main` (sorted, shallow paths first).
    public static func mainSources(under root: URL) -> [String] {
        let rootPath = root.canonicalFileURL.path
        var found: [String] = []
        for path in ProjectSearch.files(under: root) {
            let url = URL(fileURLWithPath: path)
            guard SourceKind.sourceExtensions.contains(url.pathExtension.lowercased()), !isInBuildTree(path, root: root),
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let ns = text as NSString
            guard mainDeclaration.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil else { continue }
            found.append(path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path)
        }
        return found.sorted {
            let (a, b) = ($0.split(separator: "/").count, $1.split(separator: "/").count)
            return a != b ? a < b : $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private static func isInBuildTree(_ path: String, root: URL) -> Bool {
        let relative = path.dropFirst(root.canonicalFileURL.path.count + 1)
        let first = relative.split(separator: "/").first.map(String.init) ?? ""
        return first == "build" || first.hasPrefix("cmake-build-") || first == "out" || first == ".cache"
    }

    // MARK: Commands

    /// Whether clangd will find real compile flags (otherwise it guesses).
    public var hasCompilationDatabase: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: buildDirectory.appendingPathComponent("compile_commands.json").path)
            || fm.fileExists(atPath: root.appendingPathComponent("compile_commands.json").path)
            || fm.fileExists(atPath: root.appendingPathComponent("compile_flags.txt").path)
    }

    public var isConfigured: Bool {
        FileManager.default.fileExists(atPath: buildDirectory.appendingPathComponent("CMakeCache.txt").path)
    }

    /// `cmake -S . -B build` with a Debug build and compile_commands.json for clangd.
    public func configureCommand(cmake: URL, ninja: URL?) -> Command {
        var args = ["-S", ".", "-B", "build", "-DCMAKE_BUILD_TYPE=Debug", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"]
        if let ninja { args += ["-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=\(ninja.path)"] }
        return Command(executable: cmake, arguments: args, directory: root)
    }

    /// `cmake --build build [--target t]`, or `make -jN`.
    public func buildCommand(tool: URL, target: String? = nil) -> Command {
        switch buildSystem {
        case .cmake:
            var args = ["--build", "build", "--parallel"]
            if let target { args += ["--target", target] }
            return Command(executable: tool, arguments: args, directory: root)
        case .make, .plain:
            return Command(executable: tool, arguments: ["-j\(ProcessInfo.processInfo.activeProcessorCount)"], directory: root)
        }
    }

    /// Compiles one source file (plus nothing else) into `build/<name>` with debug info.
    /// Uses the C/C++ standard from `standards`, unless the project's `compile_flags.txt` (which clangd
    /// also reads) sets one; its other flags (include dirs, defines, …) are passed along too.
    public func compileSingleFileCommand(source: String, cCompiler: URL, cxxCompiler: URL,
                                         standards: LanguageStandards = .default) -> (command: Command, output: URL) {
        let url = (source.hasPrefix("/") ? URL(fileURLWithPath: source) : root.appendingPathComponent(source)).standardizedFileURL
        let ext = url.pathExtension.lowercased()
        let output = buildDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
        let isC = ext == "c"
        let extra = compileFlags()
        var args: [String] = []
        if !extra.contains(where: { $0.hasPrefix("-std=") }), ext != "m" {
            args.append("-std=" + (isC ? standards.c : standards.cxx))
        }
        args += ["-g", "-O0", "-Wall", "-Wextra", "-fno-color-diagnostics"] + extra
        if ext == "m" || ext == "mm" { args += ["-fobjc-arc", "-framework", "Foundation"] }
        // Relative paths keep compiler messages short (`main.cpp:3:5: error: …`) and clickable.
        let rootPath = root.canonicalFileURL.path + "/"
        let sourcePath = url.canonicalFileURL.path
        args += [sourcePath.hasPrefix(rootPath) ? String(sourcePath.dropFirst(rootPath.count)) : sourcePath,
                 "-o", "build/" + output.lastPathComponent]
        let compiler = isC || ext == "m" ? cCompiler : cxxCompiler
        return (Command(executable: compiler, arguments: args, directory: root), output)
    }

    /// Flags from `compile_flags.txt` at the project root, one per line (as clangd reads them).
    public func compileFlags() -> [String] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("compile_flags.txt"), encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// The program a run configuration launches, once built.
    public func executable(for target: String) -> URL? {
        let fm = FileManager.default
        switch buildSystem {
        case .cmake:
            // Prefer the CMake file API's answer; fall back to searching the build tree by name.
            if let path = CMakeFileAPI.artifact(named: target, buildDirectory: buildDirectory) { return path }
            return Self.findExecutable(named: target, under: buildDirectory)
        case .make, .plain:
            if SourceKind.sourceExtensions.contains((target as NSString).pathExtension.lowercased()) {
                let name = ((target as NSString).lastPathComponent as NSString).deletingPathExtension
                return buildDirectory.appendingPathComponent(name)
            }
            let expanded = (target as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                : root.appendingPathComponent(expanded).standardizedFileURL
            return fm.isExecutableFile(atPath: url.path) ? url : nil
        }
    }

    /// For `.make`/`.plain` run configurations that name a source file: compile it standalone.
    public func isSingleFileTarget(_ target: String) -> Bool {
        buildSystem != .cmake && SourceKind.sourceExtensions.contains((target as NSString).pathExtension.lowercased())
    }

    static func findExecutable(named name: String, under dir: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "CMakeFiles" { enumerator.skipDescendants(); continue }
            if url.lastPathComponent == name, fm.isExecutableFile(atPath: url.path),
               (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return url
            }
        }
        return nil
    }
}

/// Reads CMake's file-based API replies (`build/.cmake/api/v1/reply`) for target artifacts.
public enum CMakeFileAPI {
    /// Writes the query so the next configure produces a codemodel reply.
    public static func writeQuery(buildDirectory: URL) {
        let query = buildDirectory.appendingPathComponent(".cmake/api/v1/query/codemodel-v2")
        try? FileManager.default.createDirectory(at: query.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: query.path) {
            FileManager.default.createFile(atPath: query.path, contents: Data())
        }
    }

    /// Executable targets that compile `source`, as their artifact paths.
    public static func executables(withSource source: URL, root: URL, buildDirectory: URL) -> [URL] {
        let reply = buildDirectory.appendingPathComponent(".cmake/api/v1/reply")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: reply.path) else { return [] }
        let wanted = source.canonicalFileURL.path
        let rootURL = root.canonicalFileURL
        var found: [URL] = []
        for file in files where file.hasPrefix("target-") && file.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: reply.appendingPathComponent(file)),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                  json["type"]?.stringValue == "EXECUTABLE",
                  let path = json["artifacts"]?[0]?["path"]?.stringValue,
                  let sources = json["sources"]?.arrayValue else { continue }
            // Source paths are relative to the top-level source directory (or absolute).
            let matches = sources.contains { entry in
                guard let p = entry["path"]?.stringValue else { return false }
                let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : rootURL.appendingPathComponent(p)
                return url.canonicalFileURL.path == wanted
            }
            if matches {
                found.append(path.hasPrefix("/") ? URL(fileURLWithPath: path) : buildDirectory.appendingPathComponent(path))
            }
        }
        return found
    }

    public static func artifact(named name: String, buildDirectory: URL) -> URL? {
        let reply = buildDirectory.appendingPathComponent(".cmake/api/v1/reply")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: reply.path) else { return nil }
        for file in files where file.hasPrefix("target-\(name)-") && file.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: reply.appendingPathComponent(file)),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                  json["type"]?.stringValue == "EXECUTABLE", json["name"]?.stringValue == name,
                  let path = json["artifacts"]?[0]?["path"]?.stringValue else { continue }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : buildDirectory.appendingPathComponent(path)
            return url
        }
        return nil
    }
}
