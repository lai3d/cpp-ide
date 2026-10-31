import Foundation
import Testing
@testable import CppIDECore

@Suite struct RunConfigurationTests {
    @Test func splitsShellWords() {
        #expect(ShellWords.split(#"-port 8080 --name "my app" 'a b' c\ d"#) == ["-port", "8080", "--name", "my app", "a b", "c d"])
        #expect(ShellWords.split("   ").isEmpty)
        #expect(ShellWords.split(#"--flag="" x"#) == ["--flag=", "x"])
    }

    @Test func parsesEnvironment() {
        let config = RunConfiguration(name: "server", target: "server", arguments: "-v",
                                      environment: "PORT=8080\n# comment\nDSN=postgres://u@h/db?x=1\n\n")
        #expect(config.environmentVariables == ["PORT": "8080", "DSN": "postgres://u@h/db?x=1"])
        #expect(config.argumentList == ["-v"])
    }
}

@Suite struct CppProjectTests {
    private func makeProject(_ files: [String: String]) throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cppide-proj-\(UUID().uuidString)")
        for (name, text) in files {
            let url = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return base.canonicalFileURL
    }

    @Test func detectsBuildSystems() throws {
        let cmake = try makeProject(["CMakeLists.txt": "", "Makefile": ""])
        let make = try makeProject(["Makefile": "all:\n"])
        let plain = try makeProject(["main.c": "int main(void) { return 0; }\n"])
        defer { [cmake, make, plain].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(BuildSystem.detect(at: cmake) == .cmake)
        #expect(BuildSystem.detect(at: make) == .make)
        #expect(BuildSystem.detect(at: plain) == .plain)
    }

    @Test func findsCMakeExecutables() throws {
        let root = try makeProject([
            "CMakeLists.txt": """
                project(demo)
                add_executable(app src/main.cpp)
                # add_executable(commented_out x.cpp)
                add_library(core STATIC src/core.cpp)
                ADD_EXECUTABLE( tool tools/tool.cpp )
                add_executable(protoc IMPORTED)
                add_executable(app_alias ALIAS app)
                add_subdirectory(sub)
                """,
            "sub/CMakeLists.txt": "add_executable(sub-bench bench.cpp)\n",
            "build/CMakeLists.txt": "add_executable(generated x.cpp)\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Set(CppProject.cmakeExecutables(under: root)) == ["app", "tool", "sub-bench"])
        #expect(CppProject(root: root).runnableTargets().contains("app"))
    }

    @Test func findsMainSources() throws {
        let root = try makeProject([
            "main.cpp": "int main(int argc, char **argv) {}\n",
            "tools/gen.c": "#include <stdio.h>\nint main(void) {}\n",
            "lib/util.cpp": "int helper() { return 1; }\n",
            "lib/util.h": "int main();\n",
            "build/junk.cpp": "int main() {}\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CppProject.mainSources(under: root) == ["main.cpp", "tools/gen.c"])
    }

    @Test func compilesSingleFiles() throws {
        let root = try makeProject(["fizz.c": "", "app.cpp": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = CppProject(root: root)
        let cc = URL(fileURLWithPath: "/usr/bin/clang"), cxx = URL(fileURLWithPath: "/usr/bin/clang++")
        let c = project.compileSingleFileCommand(source: "fizz.c", cCompiler: cc, cxxCompiler: cxx)
        #expect(c.command.executable == cc && c.command.arguments.contains("-std=c17") && c.command.arguments.contains("-g"))
        #expect(c.output == root.appendingPathComponent("build/fizz"))
        let cpp = project.compileSingleFileCommand(source: "app.cpp", cCompiler: cc, cxxCompiler: cxx)
        #expect(cpp.command.executable == cxx && cpp.command.arguments.contains("-std=c++20"))
        #expect(cpp.command.arguments.suffix(3) == ["app.cpp", "-o", "build/app"])  // relative: short, clickable messages
        #expect(cpp.command.directory == root)
        #expect(project.isSingleFileTarget("app.cpp") && !project.isSingleFileTarget("build/app"))
        #expect(project.executable(for: "app.cpp") == root.appendingPathComponent("build/app"))
    }

    @Test func buildsCommandsAndFindsArtifacts() throws {
        let root = try makeProject(["CMakeLists.txt": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = CppProject(root: root)
        let cmake = URL(fileURLWithPath: "/opt/homebrew/bin/cmake")
        let configure = project.configureCommand(cmake: cmake, ninja: nil)
        #expect(configure.arguments.contains("-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"))
        #expect(!configure.arguments.contains("Ninja"))
        #expect(project.configureCommand(cmake: cmake, ninja: URL(fileURLWithPath: "/n/ninja")).arguments.contains("Ninja"))
        #expect(project.buildCommand(tool: cmake, target: "app").arguments == ["--build", "build", "--parallel", "--target", "app"])
        #expect(!project.isConfigured && !project.hasCompilationDatabase)

        // File API reply → exact artifact path.
        let reply = project.buildDirectory.appendingPathComponent(".cmake/api/v1/reply")
        try FileManager.default.createDirectory(at: reply, withIntermediateDirectories: true)
        try #"{"name":"app","type":"EXECUTABLE","artifacts":[{"path":"bin/app"}]}"#
            .write(to: reply.appendingPathComponent("target-app-Debug-abc.json"), atomically: true, encoding: .utf8)
        #expect(project.executable(for: "app") == project.buildDirectory.appendingPathComponent("bin/app"))

        // No reply: fall back to an executable with the target's name in the build tree.
        let tool = project.buildDirectory.appendingPathComponent("tools/tool")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tool.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        #expect(project.executable(for: "tool")?.lastPathComponent == "tool")
        #expect(project.executable(for: "missing") == nil)

        CMakeFileAPI.writeQuery(buildDirectory: project.buildDirectory)
        #expect(FileManager.default.fileExists(atPath: project.buildDirectory.appendingPathComponent(".cmake/api/v1/query/codemodel-v2").path))
        #expect(Command(executable: cmake, arguments: ["-S", ".", "a b"], directory: root).display == #"cmake -S . "a b""#)
    }
}
