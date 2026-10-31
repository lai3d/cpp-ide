import Foundation
import Testing
@testable import CppIDECore

@Suite struct LSPFramerTests {
    @Test func roundTripsSingleMessage() {
        var framer = LSPFramer()
        let body = Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)
        #expect(framer.append(LSPFramer.frame(body)) == [body])
    }

    @Test func reassemblesSplitChunks() {
        var framer = LSPFramer()
        let body = Data(#"{"hello":"wörld"}"#.utf8)
        let framed = LSPFramer.frame(body)
        let mid = framed.count / 2
        #expect(framer.append(framed.prefix(mid)).isEmpty)
        #expect(framer.append(framed.suffix(from: mid)) == [body])
    }

    @Test func splitsMultipleMessagesInOneChunk() {
        var framer = LSPFramer()
        let a = Data("{}".utf8), b = Data("[1,2]".utf8)
        #expect(framer.append(LSPFramer.frame(a) + LSPFramer.frame(b)) == [a, b])
    }
}

@Suite struct JSONValueTests {
    @Test func roundTrips() throws {
        let value: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": 1.5]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(decoded["a"]?.intValue == 1)
        #expect(decoded["b"]?[2]?.stringValue == "x")
    }
}

@Suite struct LineIndexTests {
    @Test func convertsPositions() {
        let index = LineIndex("ab\ncdef\n\ng")
        #expect(index.lineCount == 4)
        #expect(index.offset(of: TextPosition(line: 1, character: 2)) == 5)
        #expect(index.offset(of: TextPosition(line: 1, character: 99)) == 7)  // clamped before newline
        #expect(index.position(of: 5) == TextPosition(line: 1, character: 2))
        #expect(index.position(of: 9) == TextPosition(line: 3, character: 0))
    }

    @Test func usesUTF16Units() {
        let index = LineIndex("x😀y")  // emoji is 2 UTF-16 units, like LSP's default encoding
        #expect(index.offset(of: TextPosition(line: 0, character: 3)) == 3)
        #expect(index.utf16Count == 4)
    }
}

@Suite struct CppHighlighterTests {
    private func kinds(_ source: String) -> [(String, TokenKind)] {
        let ns = source as NSString
        return CppHighlighter.tokenize(source).map { (ns.substring(with: $0.range), $0.kind) }
    }

    @Test func classifiesTokens() {
        let tokens = kinds(#"int main() { auto x = sizeof("hi // no") + 42; return x; } // done"#)
        #expect(tokens.map(\.0) == ["int", "main", "auto", "sizeof", #""hi // no""#, "42", "return", "// done"])
        #expect(tokens.map(\.1) == [.type, .function, .keyword, .keyword, .string, .number, .keyword, .comment])
    }

    @Test func handlesRawStringsAndCharLiterals() {
        let tokens = kinds("auto s = R\"x(a \"quoted\" )\" b)x\"; char c = '\\''; bool t = nullptr;")
        #expect(tokens.contains { $0.0 == "R\"x(a \"quoted\" )\" b)x\"" && $0.1 == .string })
        #expect(tokens.contains { $0.0 == "'\\''" && $0.1 == .string })
        #expect(tokens.contains { $0.0 == "nullptr" && $0.1 == .builtin })
        #expect(!tokens.contains { $0.0 == "quoted" })  // inside the raw string
    }

    @Test func highlightsPreprocessorAndIncludePaths() {
        let tokens = kinds("#include <vector>\n  #  define MAX 10\n#include \"greeter.h\"\nint v;")
        #expect(tokens.map(\.0) == ["#include", "<vector>", "  #  define", "10", "#include", "\"greeter.h\"", "int"])
        #expect(tokens.map(\.1) == [.preprocessor, .string, .preprocessor, .number, .preprocessor, .string, .type])
    }

    @Test func numbersWithSeparatorsAndSuffixes() {
        let tokens = kinds("x = 1'000'000ull + 0xFFu + 3.5f + 1e-3 + 0b1010;")
        #expect(tokens.filter { $0.1 == .number }.map(\.0) == ["1'000'000ull", "0xFFu", "3.5f", "1e-3", "0b1010"])
    }

    @Test func highlightsUnterminatedBlockComment() {
        #expect(kinds("x /* open").last?.1 == .comment)
    }

    @Test func classifiesSourceFiles() {
        #expect(SourceKind.isSource(URL(fileURLWithPath: "/p/a.cpp")))
        #expect(SourceKind.isSource(URL(fileURLWithPath: "/p/a.HPP")))
        #expect(SourceKind.isHeader(URL(fileURLWithPath: "/p/a.h")))
        #expect(!SourceKind.isSource(URL(fileURLWithPath: "/p/CMakeLists.txt")))
        #expect(SourceKind.languageID(for: URL(fileURLWithPath: "/p/a.c")) == "c")
        #expect(SourceKind.languageID(for: URL(fileURLWithPath: "/p/a.h")) == "cpp")
        #expect(SourceKind.languageID(for: URL(fileURLWithPath: "/p/a.mm")) == "objective-cpp")
        #expect(SourceKind.isBuildInput("/p/build/compile_commands.json"))
    }
}

@Suite struct DiagnosticTests {
    @Test func parsesPublishDiagnostics() throws {
        let params: JSONValue = [
            "uri": "file:///tmp/main.cpp",
            "diagnostics": [
                ["range": ["start": ["line": 3, "character": 1], "end": ["line": 3, "character": 5]],
                 "severity": 1, "message": "use of undeclared identifier 'foo'", "source": "compiler"],
                ["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]],
                 "severity": 2, "message": "warn"],
            ],
        ]
        let result = try #require(Diagnostic.parsePublish(params))
        #expect(result.uri == "file:///tmp/main.cpp")
        #expect(result.diagnostics.map(\.message) == ["warn", "use of undeclared identifier 'foo'"])  // sorted by position
        #expect(result.diagnostics[1].severity == .error)
        #expect(result.diagnostics[1].start == TextPosition(line: 3, character: 1))
    }
}

/// End-to-end check against a real clangd (skipped when clangd isn't installed).
@Suite struct ClangdIntegrationTests {
    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func publishesDiagnosticsForBrokenCode() async throws {
        let session = try ClangdSession(files: ["main.cpp": "int main() {\n    undefinedThing();\n}\n"])
        let (stream, continuation) = AsyncStream<[Diagnostic]>.makeStream()
        try await session.start { method, params in
            if method == "textDocument/publishDiagnostics",
               let published = Diagnostic.parsePublish(params), !published.diagnostics.isEmpty {
                continuation.yield(published.diagnostics)
            }
        }
        try session.open("main.cpp")
        var iterator = stream.makeAsyncIterator()
        let diagnostics = try #require(await iterator.next())
        #expect(diagnostics.contains { $0.message.contains("undefinedThing") && $0.start.line == 1 && $0.severity == .error })
        await session.shutdown()
    }
}
