import Foundation
import Testing
@testable import CppIDECore

@Suite struct CLanguageTests {
    @Test func detectsTheProjectDialect() {
        #expect(SourceDialect.detect(paths: ["/p/main.c", "/p/util.c", "/p/util.h", "/p/README.md"]) == .c)
        #expect(SourceDialect.detect(paths: ["/p/main.cpp", "/p/a.hpp", "/p/b.h"]) == .cxx)
        #expect(SourceDialect.detect(paths: ["/p/main.c", "/p/a.cc"]) == .mixed)
        #expect(SourceDialect.detect(paths: ["/p/main.c", "/p/bridge.m"]) == .mixed)
        #expect(SourceDialect.detect(paths: ["/p/notes.txt"]) == .mixed)
    }

    @Test func headersAreCOnlyInCProjects() {
        let header = URL(fileURLWithPath: "/p/util.h")
        #expect(SourceKind.languageID(for: header, dialect: .c) == "c")
        #expect(SourceKind.languageID(for: header, dialect: .cxx) == "cpp")
        #expect(SourceKind.languageID(for: header) == "cpp")
        #expect(SourceKind.languageID(for: URL(fileURLWithPath: "/p/a.c"), dialect: .cxx) == "c")
        #expect(SourceKind.languageID(for: URL(fileURLWithPath: "/p/a.hpp"), dialect: .c) == "c")
        #expect(SourceKind.languageID(for: URL(fileURLWithPath: "/p/a.cpp"), dialect: .c) == "cpp")
    }

    @Test func clangdFallbackFlagsFollowTheDialect() {
        let standards = LanguageStandards(c: "c99", cxx: "c++17")
        #expect(ClangdSettings.initializationOptions(dialect: .c, standards: standards)["fallbackFlags"] == ["-xc", "-std=c99"])
        #expect(ClangdSettings.initializationOptions(dialect: .cxx, standards: standards)["fallbackFlags"] == ["-std=c++17"])
        #expect(ClangdSettings.initializationOptions(dialect: .mixed, standards: standards)["fallbackFlags"] == nil)
    }

    @Test func singleFileBuildsUseTheChosenStandardAndCompileFlags() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cppide-std-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = CppProject(root: dir)
        let cc = URL(fileURLWithPath: "/usr/bin/clang"), cxx = URL(fileURLWithPath: "/usr/bin/clang++")
        let standards = LanguageStandards(c: "c99", cxx: "c++17")
        #expect(project.compileSingleFileCommand(source: "a.c", cCompiler: cc, cxxCompiler: cxx, standards: standards)
            .command.arguments.first == "-std=c99")
        #expect(project.compileSingleFileCommand(source: "a.cpp", cCompiler: cc, cxxCompiler: cxx, standards: standards)
            .command.arguments.first == "-std=c++17")

        // compile_flags.txt (clangd's simple flags file) feeds the compile too, and its -std wins.
        try "# project flags\n-Iinclude\n-DDEBUG=1\n\n-std=gnu11\n".write(
            to: dir.appendingPathComponent("compile_flags.txt"), atomically: true, encoding: .utf8)
        let args = project.compileSingleFileCommand(source: "a.c", cCompiler: cc, cxxCompiler: cxx, standards: standards)
            .command.arguments
        #expect(!args.contains("-std=c99"))
        #expect(args.contains("-Iinclude") && args.contains("-DDEBUG=1") && args.contains("-std=gnu11"))
        #expect(!args.contains("# project flags"))
    }

    @Test func snippetsAreOfferedPerLanguage() {
        let c = CppSnippets.completions(matching: "tstruct", isC: true).map(\.label)
        #expect(c.contains("tstruct"))
        #expect(!CppSnippets.completions(matching: "tstruct", isC: false).map(\.label).contains("tstruct"))
        #expect(!CppSnippets.completions(matching: "class", isC: true).map(\.label).contains("class"))
        #expect(CppSnippets.completions(matching: "class", isC: false).map(\.label).contains("class"))
        #expect(!CppSnippets.completions(matching: "cout", isC: true).map(\.label).contains("cout"))
        #expect(CppSnippets.completions(matching: "printf", isC: true).map(\.label).contains("printf"))
        #expect(CppSnippets.completions(matching: "inc", isC: true).first { $0.label == "inc" }?.insertText == "#include <stdio.h>")
        #expect(CppSnippets.completions(matching: "inc", isC: false).first { $0.label == "inc" }?.insertText == "#include <vector>")
        // Exactly one "inc" per language.
        #expect(CppSnippets.completions(matching: "inc", isC: true).filter { $0.label == "inc" }.count == 1)
    }

    @Test func findsUnityTests() {
        let text = """
            #include "unity.h"
            #include "math.h"

            void setUp(void) {}
            void tearDown(void) {}

            void test_add(void) {
                TEST_ASSERT_EQUAL_INT(3, add(1, 2));
            }

            static void helper(void) {}

            void test_sub(void)
            {
                TEST_ASSERT_EQUAL_INT(1, sub(2, 1));
            }

            int main(void) {
                UNITY_BEGIN();
                RUN_TEST(test_add);
                RUN_TEST(test_sub);
                return UNITY_END();
            }
            """
        #expect(TestFinder.cFramework(in: text) == .unity)
        #expect(TestFinder.testFunctions(in: text).map(\.name) == ["test_add", "test_sub"])
        #expect(TestFinder.testFunctions(in: text).map(\.line) == [6, 12])
        #expect(TestFinder.enclosingTest(in: text, at: (text as NSString).range(of: "sub(2, 1)").location) == "test_sub")
        #expect(TestFinder.isTestFile(name: "checks.c", text: text))
        #expect(TestFinder.mightContainTests(text))
    }

    @Test func findsCMockaTests() {
        let text = """
            #include <stdarg.h>
            #include <stddef.h>
            #include <setjmp.h>
            #include <cmocka.h>

            static void adds(void **state) {
                (void)state;
                assert_int_equal(3, 1 + 2);
            }

            static void not_registered(void **state) {}

            int main(void) {
                const struct CMUnitTest tests[] = {
                    cmocka_unit_test(adds),
                };
                return cmocka_run_group_tests(tests, NULL, NULL);
            }
            """
        #expect(TestFinder.cFramework(in: text) == .cmocka)
        #expect(TestFinder.testFunctions(in: text).map(\.name) == ["adds"])
        #expect(TestFinder.cFramework(in: "#include <stdio.h>\nvoid test_x(void) {}\n") == nil)
        #expect(TestFinder.testFunctions(in: "#include <stdio.h>\nvoid test_x(void) {}\n").isEmpty)
    }

    @Test func parsesVerboseCTestOutputWithFunctionResults() {
        var report = TestReport()
        let lines = """
            UpdateCTestConfiguration  from :/p/build/DartConfiguration.tcl
            Test project /p/build
            Constructing a list of tests
            Done constructing a list of tests
            Updating test list for fixtures
            Added 0 tests to meet fixture requirements
            Checking test dependency graph...
            Checking test dependency graph end
            test 1
                Start 1: unity_math

            1: Test command: /p/build/test_math
            1: Working Directory: /p/build
            1: Test timeout computed to be: 1500
            1: tests/test_math.c:7:test_add:PASS
            1: tests/test_math.c:15:test_sub:FAIL: Expected 1 Was 2
            1:
            1: -----------------------
            1: 2 Tests 1 Failures 0 Ignored
            1: FAIL
            1/2 Test #1: unity_math .......................***Failed    0.01 sec
            test 2
                Start 2: cmocka_math

            2: Test command: /p/build/test_cm
            2: [==========] tests: Running 2 test(s).
            2: [ RUN      ] adds
            2: [       OK ] adds
            2: [ RUN      ] skipped_one
            2: [  SKIPPED ] skipped_one
            2: [==========] tests: 2 test(s) run.
            2: [  PASSED  ] 1 test(s).
            2/2 Test #2: cmocka_math ......................   Passed    0.00 sec

            50% tests passed, 1 tests failed out of 2

            Total Test time (real) =   0.02 sec

            The following tests FAILED:
            \t  1 - unity_math (Failed)
            """
        for line in lines.components(separatedBy: "\n") { report.consume(line: line) }
        #expect(report.tests.map(\.name) == ["unity_math", "cmocka_math"])
        #expect(report.tests.map(\.status) == [.failed, .passed])
        #expect(report.functionStatuses == ["test_add": .passed, "test_sub": .failed, "adds": .passed, "skipped_one": .skipped])
        // The failed test carries its output (clickable file:line), minus ctest's own chatter.
        let failed = report.tests[0].output
        #expect(failed.contains("tests/test_math.c:15:test_sub:FAIL: Expected 1 Was 2"))
        #expect(!failed.contains("Test command:") && !failed.contains("Working Directory"))
        #expect(report.tests[1].output.isEmpty)
        #expect(report.buildOutput.isEmpty, "\(report.buildOutput)")
    }

    @Test func ctestFilterAndTestListParsing() throws {
        #expect(CTestIndex.filter(["a.b", "c"]) == #"^(a\.b|c)$"#)
        let json = #"{"kind":"ctestInfo","tests":[{"name":"t1","command":["/b/x","--flag"]},{"name":"t2"}]}"#
        let parsed = CTestIndex.parseTestList(Data(json.utf8))
        #expect(parsed.map(\.name) == ["t1"] && parsed.map(\.executable) == ["/b/x"])
    }
}

/// clangd parses a header without a compile command as Objective-C++ unless told otherwise.
@Suite struct CHeaderClangdTests {
    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func cHeadersParseAsCWithFallbackFlags() async throws {
        // Valid C, invalid C++: `new` and `class` are identifiers.
        let header = "struct node { struct node *new; int class; };\nint count(struct node *class);\n"
        for dialect in [SourceDialect.c, .cxx] {
            let session = try ClangdSession(files: ["list.h": header, "main.c": "#include \"list.h\"\nint main(void) { return 0; }\n"],
                                            compilationDatabase: false)
            let (stream, continuation) = AsyncStream<[Diagnostic]>.makeStream()
            try await session.start(initializationOptions: ClangdSettings.initializationOptions(
                dialect: dialect, standards: .default)) { method, params in
                if method == "textDocument/publishDiagnostics", let published = Diagnostic.parsePublish(params),
                   published.uri.hasSuffix("list.h") {
                    continuation.yield(published.diagnostics)
                }
            }
            try session.open("list.h", dialect: dialect)
            var iterator = stream.makeAsyncIterator()
            let diagnostics = try #require(await iterator.next())
            let errors = diagnostics.filter { $0.severity == .error }
            if dialect == .c {
                #expect(errors.isEmpty, "\(errors.map(\.message))")
            } else {
                #expect(!errors.isEmpty)  // the C++ reading this guards against
            }
            await session.shutdown()
        }
    }
}
