import Foundation
import Testing
@testable import CppIDECore

@Suite struct SymbolTests {
    @Test func parsesHierarchicalAndFlatSymbols() {
        let range: JSONValue = ["start": ["line": 4, "character": 5], "end": ["line": 4, "character": 9]]
        let tree = SymbolNode.parseAll([[
            "name": "Server", "kind": 23, "detail": "struct", "range": range, "selectionRange": range,
            "children": [["name": "Addr", "kind": 8, "range": range, "selectionRange": range]],
        ]])
        #expect(tree.first?.children?.first?.name == "Addr")
        let full: JSONValue = ["start": ["line": 4, "character": 0], "end": ["line": 9, "character": 1]]
        let nested = SymbolNode.parseAll([[
            "name": "Server", "kind": 23, "range": full, "selectionRange": range,
            "children": [["name": "Addr", "kind": 8, "range": ["start": ["line": 6, "character": 1], "end": ["line": 6, "character": 12]], "selectionRange": range]],
        ]])
        #expect(SymbolNode.path(in: nested, at: TextPosition(line: 6, character: 4)).map(\.name) == ["Server", "Addr"])
        #expect(SymbolNode.path(in: nested, at: TextPosition(line: 8, character: 0)).map(\.name) == ["Server"])
        #expect(SymbolNode.path(in: nested, at: TextPosition(line: 12, character: 0)).isEmpty)
        #expect(tree.first?.position == TextPosition(line: 4, character: 5))

        let flat = SymbolNode.parseAll([["name": "Run", "kind": 12, "containerName": "main",
                                         "location": ["uri": "file:///a.cpp", "range": range]]])
        #expect(flat.first?.uri == "file:///a.cpp" && flat.first?.detail == "main" && flat.first?.children == nil)
    }

    @Test func fuzzyScoresPreferWordStartsAndFileNames() throws {
        #expect(FuzzyMatch.score("xyz", "greet.cpp") == nil)
        let camel = try #require(FuzzyMatch.score("hs", "HTTPServer"))
        let middle = try #require(FuzzyMatch.score("hs", "pushes"))
        #expect(camel > middle)
        let paths = ["src/progress/report.cpp", "greet.cpp", "tools/agreement.cpp"]
        let ranked = paths.compactMap { p in FuzzyMatch.scorePath("gre", p).map { (p, $0) } }.sorted { $0.1 > $1.1 }
        #expect(ranked.first?.0 == "greet.cpp")
    }

    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func clangdDocumentAndWorkspaceSymbols() async throws {
        let source = "struct Server {\n    int addr;\n    void start();\n};\n\nvoid Server::start() {}\n\nint main() { return 0; }\n"
        let session = try ClangdSession(files: ["main.cpp": source])
        try await session.start(capabilities: ["textDocument": ["documentSymbol": ["hierarchicalDocumentSymbolSupport": true]]])
        try session.open("main.cpp")
        let outlineRaw = try await session.poll("textDocument/documentSymbol", ["textDocument": ["uri": session.uri("main.cpp")]]) {
            !SymbolNode.parseAll($0).isEmpty
        }
        let outline = SymbolNode.parseAll(outlineRaw)
        #expect(outline.map(\.name).contains("Server"))
        #expect(outline.first { $0.name == "Server" }?.children?.map(\.name) == ["addr", "start"])

        let symbols = SymbolNode.parseAll(try await session.poll("workspace/symbol", ["query": "start"]) {
            !SymbolNode.parseAll($0).isEmpty
        })
        #expect(symbols.contains { $0.name.contains("start") && $0.uri?.hasSuffix("/main.cpp") == true })
        await session.shutdown()
    }
}
