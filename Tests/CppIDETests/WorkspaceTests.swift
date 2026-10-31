import Foundation
import Testing
@testable import CppIDE
import CppIDECore

private let hasClangd = CppIDECore.ToolLocator.find("clangd") != nil
private let hasCMake = CppIDECore.ToolLocator.find("cmake") != nil && CppIDECore.ToolLocator.find("clang++") != nil

/// A temp project folder (real path, as clangd and FSEvents report it) with a compile_commands.json
/// (so clangd's background index covers files that aren't open).
private func makeProject(_ files: [String: String], flags: Bool = true) throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("cppide-ws-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let dir = base.canonicalFileURL
    for (name, text) in files {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    if flags {
        let entries: [JSONValue] = files.keys.filter { $0.hasSuffix(".cpp") }.sorted().map { name in
            let path = dir.appendingPathComponent(name).path
            return ["directory": .string(dir.path), "file": .string(path),
                    "arguments": ["clang++", "-std=c++20", "-c", .string(path)]]
        }
        try JSONEncoder().encode(JSONValue.array(entries)).write(to: dir.appendingPathComponent("compile_commands.json"))
    }
    return dir
}

/// Polls `condition` (clangd answers some requests only once its index catches up).
@MainActor
private func eventually(_ attempts: Int = 60, every: Duration = .milliseconds(250),
                        _ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(for: every)
    }
    return await condition()
}

@MainActor
@Suite struct WorkspaceTabTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cppide-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["a.cpp", "b.cpp", "c.h"] {
            try "int x;\n".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    @Test func openingTheSameFileReusesItsTab() {
        let workspace = Workspace()
        let first = workspace.openFile(url("a.cpp"))
        workspace.openFile(url("b.cpp"))
        let again = workspace.openFile(url("a.cpp"))
        #expect(first === again)
        #expect(workspace.documents.map(\.name) == ["a.cpp", "b.cpp"])
        #expect(workspace.activeDocument === first)
        #expect(first?.isSource == true)
    }

    @Test func newTabsOpenNextToTheActiveOne() {
        let workspace = Workspace()
        let a = workspace.openFile(url("a.cpp"))!
        workspace.openFile(url("b.cpp"))
        workspace.activate(a)
        workspace.openFile(url("c.h"))
        #expect(workspace.documents.map(\.name) == ["a.cpp", "c.h", "b.cpp"])
    }

    @Test func closingTheActiveTabSelectsItsNeighbour() {
        let workspace = Workspace()
        workspace.openFile(url("a.cpp"))
        let b = workspace.openFile(url("b.cpp"))!
        workspace.openFile(url("c.h"))
        workspace.activate(b)
        workspace.closeDocument(b)
        #expect(workspace.documents.map(\.name) == ["a.cpp", "c.h"])
        #expect(workspace.activeDocument?.name == "c.h")
        workspace.closeAllDocuments()
        #expect(workspace.documents.isEmpty && workspace.activeDocument == nil)
    }

    @Test func cyclesTabs() {
        let workspace = Workspace()
        workspace.openFile(url("a.cpp"))
        workspace.openFile(url("b.cpp"))
        workspace.selectAdjacentTab(1)
        #expect(workspace.activeDocument?.name == "a.cpp")
        workspace.selectAdjacentTab(-1)
        #expect(workspace.activeDocument?.name == "b.cpp")
    }

    @Test func editsMarkDirtyAndSaveWritesToDisk() throws {
        let workspace = Workspace()
        let a = workspace.openFile(url("a.cpp"))!
        workspace.updateText(of: a, to: "int x;\n\nvoid f() {}\n")
        #expect(a.isDirty)
        workspace.save(a)
        #expect(!a.isDirty)
        #expect(try String(contentsOf: url("a.cpp"), encoding: .utf8).contains("void f()"))
    }
}

@MainActor
@Suite struct WorkspaceFormattingTests {
    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func formatsWithClangFormat() async throws {
        let dir = try makeProject([
            "main.cpp": "int main(){\nint x=1;\nreturn x;}\n",
            ".clang-format": "BasedOnStyle: LLVM\nIndentWidth: 4\n",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        await workspace.openFolder(dir)
        let document = try #require(workspace.activeDocument)
        #expect(workspace.lspStatus == "clangd: ready")

        await workspace.format(document)
        #expect(document.isDirty)  // formatted in memory, not yet saved
        #expect(document.text == "int main() {\n    int x = 1;\n    return x;\n}\n")
        workspace.save(document)
        #expect(try String(contentsOf: dir.appendingPathComponent("main.cpp"), encoding: .utf8) == document.text)
        await workspace.shutdown()
    }

    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func switchesHeaderAndSource() async throws {
        let dir = try makeProject([
            "main.cpp": "#include \"greeter.h\"\nint main() { return greet(); }\n",
            "greeter.h": "#pragma once\nint greet();\n",
            "greeter.cpp": "#include \"greeter.h\"\nint greet() { return 0; }\n",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        await workspace.openFolder(dir, openDefaultFile: false)
        workspace.openFile(dir.appendingPathComponent("greeter.cpp"))
        await workspace.switchSourceHeader()
        #expect(workspace.activeDocument?.name == "greeter.h")
        await workspace.switchSourceHeader()
        #expect(workspace.activeDocument?.name == "greeter.cpp")
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceFileSystemTests {
    let dir: URL

    init() throws {
        dir = try makeProject([
            "main.cpp": "int main() { return 0; }\n",
            "src/widget.h": "#pragma once\n",
            "src/a.cpp": "int a;\n",
        ], flags: false)
    }

    private func url(_ path: String) -> URL { dir.appendingPathComponent(path) }

    @Test func reloadsCleanDocumentsAndFlagsDirtyOnes() async throws {
        let workspace = Workspace()
        await workspace.openFolder(dir)
        let main = try #require(workspace.activeDocument)
        #expect(main.name == "main.cpp")
        let other = try #require(workspace.openFile(url("src/a.cpp")))
        workspace.updateText(of: other, to: "int a; // edited\n")

        try "int main() { return 1; }\n".write(to: url("main.cpp"), atomically: true, encoding: .utf8)
        try "int a; // external\n".write(to: url("src/a.cpp"), atomically: true, encoding: .utf8)
        workspace.handleFileSystemChanges([url("main.cpp").path, url("src/a.cpp").path])

        #expect(main.text.contains("return 1") && !main.isDirty)
        #expect(other.text.contains("edited") && other.hasExternalChange)
        workspace.reloadFromDisk(other)
        #expect(other.text.contains("external") && !other.isDirty && !other.hasExternalChange)
        await workspace.shutdown()
    }

    @Test func createsRenamesAndTrashes() async throws {
        let workspace = Workspace()
        await workspace.openFolder(dir)

        let created = try workspace.createFile(named: "widget.cpp", in: url("src"))
        #expect(try String(contentsOf: created, encoding: .utf8) == "#include \"widget.h\"\n\n")
        #expect(workspace.activeDocument?.name == "widget.cpp")
        #expect(throws: FileOperationError.self) { try workspace.createFile(named: "widget.cpp", in: url("src")) }

        let renamed = try workspace.renameItem(at: url("src"), to: "lib")
        #expect(workspace.activeDocument?.url.path == renamed.appendingPathComponent("widget.cpp").path)
        #expect(workspace.fileTree.contains { $0.name == "lib" })

        try workspace.trashItem(at: renamed)
        #expect(!workspace.documents.contains { $0.name == "widget.cpp" })
        #expect(!FileManager.default.fileExists(atPath: renamed.path))
        await workspace.shutdown()
    }

    @Test func newFileTemplates() throws {
        #expect(Workspace.template(for: url("src/thing.hpp")) == "#pragma once\n\n")
        #expect(Workspace.template(for: url("src/widget.cpp")) == "#include \"widget.h\"\n\n")
        #expect(Workspace.template(for: url("src/lonely.cpp")) == "")
        #expect(Workspace.template(for: url("notes.md")) == "")
    }
}

@MainActor
@Suite struct WorkspaceSearchTests {
    @Test func searchesProjectIncludingUnsavedBuffers() async throws {
        let dir = try makeProject([
            "main.cpp": "void greet();\nint main() { greet(); }\n",
            "greet.cpp": "void greet() {}\n",
            "build/generated.cpp": "void greet();\n",  // build output: not searched
        ], flags: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let workspace = Workspace()
        await workspace.openFolder(dir)
        workspace.searchQuery = "greet"
        await workspace.performSearch()
        #expect(workspace.searchMatchCount == 3)

        // Edit greet.cpp without saving: the search sees the buffer.
        let greet = try #require(workspace.openFile(dir.appendingPathComponent("greet.cpp")))
        workspace.updateText(of: greet, to: "void greet() {}\nvoid greetAgain() {}\n")
        await workspace.performSearch()
        #expect(workspace.searchMatchCount == 4)

        let file = try #require(workspace.searchResults.first { $0.path.hasSuffix("main.cpp") })
        workspace.open(file.matches[1], in: file)
        #expect(workspace.activeDocument?.name == "main.cpp")
        #expect(workspace.activeDocument?.revealTarget?.position == TextPosition(line: 1, character: 13))
        #expect(workspace.activeDocument?.revealTarget?.length == 5)

        workspace.searchOptions.regex = true
        workspace.searchQuery = "("
        await workspace.performSearch()
        #expect(workspace.searchError != nil && workspace.searchResults.isEmpty)
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceReferencesTests {
    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func findsReferencesAcrossFiles() async throws {
        let dir = try makeProject([
            "main.cpp": "#include \"greet.h\"\nint main() { greet(); greet(); }\n",
            "greet.h": "#pragma once\nvoid greet();\n",
            "greet.cpp": "#include \"greet.h\"\nvoid greet() {}\n",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        await workspace.openFolder(dir)
        let main = try #require(workspace.openFile(dir.appendingPathComponent("main.cpp")))
        let offset = ("#include \"greet.h\"\nint main() { " as NSString).length + 1
        // greet.cpp's definition shows up once the background index has it.
        let indexed = await eventually {
            await workspace.findReferences(in: main, at: offset)
            return workspace.referenceResults.contains { $0.path.hasSuffix("greet.cpp") }
        }
        #expect(indexed)
        #expect(workspace.bottomTab == .references)
        #expect(workspace.referenceTitle == "4 references to ‘greet’")
        #expect(workspace.referenceResults.map { ($0.path as NSString).lastPathComponent } == ["greet.cpp", "greet.h", "main.cpp"])
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceRenameTests {
    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func renamesAcrossOpenAndClosedFiles() async throws {
        let dir = try makeProject([
            "main.cpp": "#include \"greet.h\"\nint main() { greet(); }\n",
            "greet.h": "#pragma once\nvoid greet();\n",
            "greet.cpp": "#include \"greet.h\"\nvoid greet() {}\n",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        await workspace.openFolder(dir)
        let main = try #require(workspace.openFile(dir.appendingPathComponent("main.cpp")))
        let offset = ("#include \"greet.h\"\nint main() { " as NSString).length + 2

        #expect(await eventually { await workspace.prepareRename(in: main, at: offset) == "greet" })
        #expect(await workspace.prepareRename(in: main, at: ("#include \"greet.h\"\ni" as NSString).length) == nil)  // `int`

        // Cross-file rename needs the index to know about greet.cpp.
        let greetFile = dir.appendingPathComponent("greet.cpp")
        let indexed = await eventually {
            await workspace.findReferences(in: main, at: offset)
            return workspace.referenceResults.contains { $0.path.hasSuffix("greet.cpp") }
        }
        #expect(indexed)
        let error = await workspace.renameSymbol(in: main, at: offset, to: "salute")
        #expect(error == nil)
        #expect(main.text == "#include \"greet.h\"\nint main() { salute(); }\n" && main.isDirty)  // open: buffer
        #expect(try String(contentsOf: greetFile, encoding: .utf8) == "#include \"greet.h\"\nvoid salute() {}\n")  // closed: disk
        #expect(try String(contentsOf: dir.appendingPathComponent("greet.h"), encoding: .utf8).contains("void salute();"))
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceCodeActionTests {
    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func appliesQuickFixesAndTweaks() async throws {
        let source = "int main() {\n    int value = 1\n    auto copy = value;\n    return value + copy;\n}\n"
        let dir = try makeProject(["main.cpp": source])
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        await workspace.openFolder(dir)
        let main = try #require(workspace.activeDocument)
        // Wait for clangd to publish the missing-';' diagnostic.
        #expect(await eventually { !workspace.diagnostics(for: main).isEmpty })
        let ns = main.text as NSString

        // A quick fix with an edit (clang's fix-it): insert the missing ';'.
        // clang reports it at the next token (`auto` on line 2), so ask there.
        let actions = await workspace.codeActions(in: main, at: ns.range(of: "auto").location + 1)
        let fix = try #require(actions.first { $0.title.contains(";") },
                               "\(actions.map(\.title)) \(workspace.diagnostics(for: main).map(\.message))")
        await workspace.perform(fix)
        #expect(main.text.contains("int value = 1;"))

        // A tweak: a command that clangd answers with workspace/applyEdit.
        #expect(await eventually { workspace.diagnostics(for: main).isEmpty })
        let autoOffset = (main.text as NSString).range(of: "auto").location + 1
        let tweaks = await workspace.codeActions(in: main, at: autoOffset)
        let expand = try #require(tweaks.first { $0.title.lowercased().contains("deduced type") }, "actions: \(tweaks.map(\.title))")
        await workspace.perform(expand)
        #expect(await eventually { main.text.contains("int copy = value;") })
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceNavigationTests {
    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func quickOpenFindsFilesAndSymbolsAndOutlineLoads() async throws {
        let dir = try makeProject([
            "main.cpp": "#include \"greeter.h\"\nint main() { Greeter g; g.hello(); }\n",
            "greeter.h": "#pragma once\n\nclass Greeter {\npublic:\n    void hello() {}\n};\n",
            "src/progress/report.cpp": "int report;\n",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        await workspace.openFolder(dir)
        #expect(workspace.activeDocument?.name == "main.cpp")
        workspace.showQuickOpen()
        #expect(workspace.quickOpenItems.map(\.title) == ["main.cpp"])  // empty query: open tabs

        workspace.quickOpenQuery = "gre"
        workspace.updateQuickOpen()
        #expect(workspace.quickOpenItems.first?.title == "greeter.h")
        // Workspace symbols come from the background index: re-ask, as typing would.
        for _ in 0..<12 where !workspace.quickOpenItems.contains(where: { $0.position != nil }) {
            try await Task.sleep(for: .milliseconds(1500))
            if !workspace.quickOpenItems.contains(where: { $0.position != nil }) { workspace.updateQuickOpen() }
        }
        let symbol = try #require(workspace.quickOpenItems.first { $0.title == "Greeter" })
        workspace.open(symbol)
        #expect(!workspace.isQuickOpenVisible)
        #expect(workspace.activeDocument?.name == "greeter.h")
        #expect(workspace.activeDocument?.revealTarget?.position == TextPosition(line: 2, character: 6))

        await workspace.refreshOutline()
        #expect(workspace.outline.map(\.name).contains("Greeter"))
        await workspace.shutdown()
    }

    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func findsImplementationsAndTypeDefinitions() async throws {
        let source = """
            struct Shape {
                virtual double area() const = 0;
            };

            struct Square : Shape {
                double s = 2;
                double area() const override { return s * s; }
            };

            struct Circle : Shape {
                double r = 1;
                double area() const override { return 3 * r * r; }
            };

            int main() {
                auto sq = Square{};
                return static_cast<int>(sq.area());
            }

            """
        let dir = try makeProject(["main.cpp": source])
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        await workspace.openFolder(dir)
        let main = try #require(workspace.activeDocument)
        let ns = main.text as NSString

        // A pure virtual with two overrides: listed (overrides come from the index).
        let listed = await eventually {
            await workspace.jumpToImplementation(from: main, at: ns.range(of: "area").location + 1)
            return workspace.referenceTitle == "2 implementations of ‘area’"
        }
        #expect(listed, "title: \(workspace.referenceTitle)")

        // Variable → its type: jumps (one location).
        await workspace.jumpToTypeDefinition(from: main, at: ns.range(of: "sq.area").location)
        #expect(main.revealTarget?.position.line == 4)  // struct Square
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceBuildTests {
    @Test func detectsRunTargetsForPlainProjects() async throws {
        let dir = try makeProject([
            "fizz.c": "#include <stdio.h>\nint main(void) { puts(\"fizz\"); return 0; }\n",
            "util.c": "int util(void) { return 1; }\n",
        ], flags: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        await workspace.openFolder(dir)
        #expect(workspace.buildSystem == .plain)
        #expect(workspace.runTargets == ["fizz.c"])
        #expect(workspace.runConfigurations.map(\.name) == ["fizz"])
        #expect(workspace.runConfigurations.first?.target == "fizz.c")
        await workspace.shutdown()
    }

    @Test(.enabled(if: CppIDECore.ToolLocator.find("clang") != nil), .timeLimit(.minutes(1)))
    func compilesAndRunsASingleFile() async throws {
        let dir = try makeProject([
            "fizz.c": "#include <stdio.h>\n#include <stdlib.h>\nint main(int argc, char **argv) {\n"
                + "  printf(\"args=%d env=%s\\n\", argc - 1, getenv(\"FIZZ\"));\n  return 3;\n}\n",
        ], flags: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        await workspace.openFolder(dir)
        workspace.run(RunConfiguration(name: "fizz", target: "fizz.c", arguments: "a \"b c\"", environment: "FIZZ=buzz"))
        #expect(await eventually(120) { !workspace.isRunning })
        #expect(workspace.output.contains("clang"), "\(workspace.output)")
        #expect(workspace.output.contains("args=2 env=buzz"), "\(workspace.output)")
        #expect(workspace.output.contains("[process exited with status 3]"))
        #expect(FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("build/fizz").path))
        await workspace.shutdown()
    }

    @Test(.enabled(if: CppIDECore.ToolLocator.find("clang") != nil), .timeLimit(.minutes(1)))
    func compileErrorsStopThePipeline() async throws {
        let dir = try makeProject(["bad.c": "int main(void) { return missing; }\n"], flags: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        await workspace.openFolder(dir)
        workspace.run(RunConfiguration(name: "bad", target: "bad.c"))
        #expect(await eventually(120) { !workspace.isRunning })
        #expect(workspace.output.contains("bad.c:1:"), "\(workspace.output)")
        #expect(workspace.output.contains("[compile failed with status"))
        #expect(!workspace.output.contains("[process exited"))
        await workspace.shutdown()
    }

    @Test(.enabled(if: hasCMake), .timeLimit(.minutes(3)))
    func configuresBuildsRunsAndTestsACMakeProject() async throws {
        let dir = try makeProject([
            "CMakeLists.txt": """
                cmake_minimum_required(VERSION 3.20)
                project(demo LANGUAGES CXX)
                add_executable(app main.cpp)
                enable_testing()
                add_test(NAME passes COMMAND app ok)
                add_test(NAME fails COMMAND app fail)
                """,
            "main.cpp": """
                #include <cstdio>
                #include <cstring>
                int main(int argc, char **argv) {
                    std::printf("hello from app\\n");
                    return argc > 1 && std::strcmp(argv[1], "fail") == 0 ? 1 : 0;
                }

                """,
        ], flags: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        await workspace.openFolder(dir)
        #expect(workspace.buildSystem == .cmake)
        #expect(workspace.runConfigurations.map(\.target) == ["app"])

        workspace.build()
        #expect(await eventually(600) { !workspace.isRunning })
        #expect(workspace.output.contains("[build succeeded]"), "\(workspace.output)")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("build/compile_commands.json").path))
        #expect(workspace.project?.executable(for: "app") != nil)

        workspace.runSelectedConfiguration()
        #expect(await eventually(240) { !workspace.isRunning })
        #expect(workspace.output.contains("hello from app"), "\(workspace.output)")
        #expect(workspace.output.contains("[process exited with status 0]"))

        workspace.runTests(.all)
        #expect(await eventually(240) { !workspace.isRunning })
        #expect(workspace.testReport.tests.map(\.name) == ["passes", "fails"], "\(workspace.output)")
        #expect(workspace.testReport.passed == 1 && workspace.testReport.failed == 1)
        #expect(workspace.selectedTestID == workspace.testReport.tests.last?.id)

        workspace.runTests(.test("passes", in: dir))
        #expect(await eventually(240) { !workspace.isRunning })
        #expect(workspace.testReport.tests.map(\.name) == ["passes"])
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceCTests {
    /// Just enough of Unity's API and output format (`file:line:test:PASS|FAIL: msg`).
    static let unityHeader = """
        #include <stdio.h>
        static const char *unity_test;
        static int unity_failed, unity_failures;
        #define UNITY_BEGIN() (unity_failures = 0)
        #define UNITY_END() (unity_failures)
        #define RUN_TEST(fn) do { unity_test = #fn; unity_failed = 0; fn(); \\
            if (!unity_failed) printf("%s:%d:%s:PASS\\n", __FILE__, __LINE__, #fn); } while (0)
        #define TEST_ASSERT_EQUAL_INT(e, a) do { if ((e) != (a)) { \\
            printf("%s:%d:%s:FAIL: Expected %d Was %d\\n", __FILE__, __LINE__, unity_test, (int)(e), (int)(a)); \\
            unity_failed = 1; unity_failures++; return; } } while (0)

        """

    @Test(.enabled(if: hasCMake), .timeLimit(.minutes(3)))
    func runsUnityTestsFromTheirFileAndMarksEachFunction() async throws {
        let dir = try makeProject([
            "CMakeLists.txt": """
                cmake_minimum_required(VERSION 3.20)
                project(cdemo LANGUAGES C)
                add_executable(app src/main.c)
                add_executable(test_math tests/test_math.c)
                target_include_directories(test_math PRIVATE tests)
                enable_testing()
                add_test(NAME app_runs COMMAND app)
                add_test(NAME math COMMAND test_math)
                """,
            "src/main.c": "#include <stdio.h>\nint main(void) {\n    puts(\"hi\");\n    return 0;\n}\n",
            "src/util.h": "struct node { struct node *new; int class; };\n",
            "tests/unity.h": Self.unityHeader,
            "tests/test_math.c": """
                #include "unity.h"

                void test_add(void) {
                    TEST_ASSERT_EQUAL_INT(3, 1 + 2);
                }

                void test_sub(void) {
                    TEST_ASSERT_EQUAL_INT(1, 2 - 2);
                }

                int main(void) {
                    UNITY_BEGIN();
                    RUN_TEST(test_add);
                    RUN_TEST(test_sub);
                    return UNITY_END();
                }

                """,
        ], flags: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = Workspace()
        await workspace.openFolder(dir)
        #expect(workspace.sourceDialect == .c)

        // C-only snippets in a C project's header.
        let header = try #require(workspace.openFile(dir.appendingPathComponent("src/util.h")))
        header.text = "tstr" + header.text
        let completions = await workspace.completions(in: header, at: 4).map(\.label)
        #expect(completions.contains("tstruct"), "\(completions)")

        workspace.build()
        #expect(await eventually(600) { !workspace.isRunning })
        #expect(workspace.output.contains("[build succeeded]"), "\(workspace.output)")

        // ▶ on test_add runs only the ctest test built from tests/test_math.c, not app_runs.
        let tests = try #require(workspace.openFile(dir.appendingPathComponent("tests/test_math.c")))
        workspace.runTest(named: "test_add", in: tests)
        #expect(await eventually(240) { !workspace.isRunning })
        #expect(workspace.testReport.tests.map(\.name) == ["math"], "\(workspace.output)")
        #expect(workspace.testReport.failed == 1)
        #expect(workspace.testStatuses["test_add"] == .passed)
        #expect(workspace.testStatuses["test_sub"] == .failed)
        #expect(workspace.testReport.tests.first?.output.contains("test_sub:FAIL: Expected 1 Was 0") == true)
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceGitTests {
    @Test(.enabled(if: CppIDECore.ToolLocator.find("git") != nil), .timeLimit(.minutes(1)))
    func tracksBranchStatusesAndBases() async throws {
        let dir = try makeProject(["main.cpp": "int main() { return 0; }\n"], flags: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        Git.run(["init", "-q", "-b", "feature"], in: dir)
        try "build/\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        Git.run(["add", "."], in: dir)
        Git.run(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"], in: dir)
        try "// changed\nint main() { return 0; }\n".write(to: dir.appendingPathComponent("main.cpp"), atomically: true, encoding: .utf8)
        try "int extra;\n".write(to: dir.appendingPathComponent("new.cpp"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        for _ in 0..<50 where workspace.gitBranch == nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(workspace.gitBranch == "feature")
        #expect(workspace.gitStatus(for: dir.appendingPathComponent("main.cpp")) == .modified)
        #expect(workspace.gitStatus(for: dir.appendingPathComponent("new.cpp")) == .untracked)
        #expect(workspace.gitStatus(for: dir.appendingPathComponent(".gitignore")) == nil)
        let main = try #require(workspace.activeDocument)
        #expect(workspace.gitBase(for: main) == "int main() { return 0; }\n")
        let changes = LineChanges.compute(base: workspace.gitBase(for: main)!, current: main.text)
        #expect(changes.lines == [0: .added])
        await workspace.shutdown()
    }
}

@MainActor
@Suite(.serialized) struct SessionRestoreTests {
    @Test func restoresTabsAndRecents() async throws {
        let suite = "cppide-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        SessionStore.defaults = defaults
        defer {
            SessionStore.defaults = .standard
            defaults.removePersistentDomain(forName: suite)
        }
        let dir = try makeProject(["main.cpp": "int main();\n", "a.cpp": "int a;\n", "b.h": "int b;\n"], flags: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = Workspace()
        await first.openFolder(dir)
        #expect(first.documents.map(\.name) == ["main.cpp"])  // nothing saved yet: default file
        first.openFile(dir.appendingPathComponent("a.cpp"))
        first.openFile(dir.appendingPathComponent("b.h"))
        first.activate(first.documents[1])  // a.cpp
        await first.shutdown()

        let second = Workspace()
        await second.openFolder(dir)
        #expect(second.documents.map(\.name) == ["main.cpp", "a.cpp", "b.h"])
        #expect(second.activeDocument?.name == "a.cpp")
        #expect(SessionStore.recentProjects.first?.path == dir.path)
        await second.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceReplaceTests {
    @Test func replacesInOpenBuffersAndOnDisk() async throws {
        let dir = try makeProject([
            "main.cpp": "int main() { getUser(); getName(); }\n",
            "other.cpp": "void getUser() {}\nvoid getName() {}\n",
        ], flags: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = dir.appendingPathComponent("other.cpp")

        let workspace = Workspace()
        await workspace.openFolder(dir)
        let main = try #require(workspace.activeDocument)
        #expect(main.name == "main.cpp")
        workspace.searchOptions = SearchOptions(regex: true)
        workspace.searchQuery = #"get(\w+)\("#
        workspace.replaceQuery = "fetch$1("
        await workspace.performSearch()
        #expect(workspace.searchMatchCount == 4)

        // One match first: the second call in main.cpp (still in the buffer).
        let mainResult = try #require(workspace.searchResults.first { $0.path.hasSuffix("main.cpp") })
        await workspace.replace(mainResult.matches[1], in: mainResult)
        #expect(main.text.contains("getUser(); fetchName()") && main.isDirty)

        #expect(await workspace.replaceAllInProject() == 3)
        #expect(main.text.contains("fetchUser(); fetchName()"))
        #expect(try String(contentsOf: other, encoding: .utf8) == "void fetchUser() {}\nvoid fetchName() {}\n")
        #expect(workspace.searchMatchCount == 0)
        await workspace.shutdown()
    }
}
