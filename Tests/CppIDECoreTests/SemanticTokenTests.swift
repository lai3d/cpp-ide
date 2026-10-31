import Foundation
import Testing
@testable import CppIDECore

@Suite struct SemanticTokenTests {
    @Test func decodesRelativeEncoding() {
        let legend = SemanticTokenLegend(types: ["namespace", "type", "parameter"], modifiers: ["definition", "readonly"])
        // (0,8) len 3 namespace; same line +5 len 4 type [definition]; next line col 2 len 1 parameter [readonly]
        let tokens = legend.decode(["data": [0, 8, 3, 0, 0, 0, 5, 4, 1, 1, 1, 2, 1, 2, 2]])
        #expect(tokens == [
            SemanticToken(line: 0, start: 8, length: 3, type: "namespace"),
            SemanticToken(line: 0, start: 13, length: 4, type: "type", modifiers: ["definition"]),
            SemanticToken(line: 1, start: 2, length: 1, type: "parameter", modifiers: ["readonly"]),
        ])
    }

    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func clangdSemanticTokens() async throws {
        let source = "namespace shop {\nstruct Order { int id; };\n}\n\n#define MAX 3\nconstexpr int limit = 5;\n\nint show(shop::Order o) { return o.id + MAX + limit; }\n"
        let session = try ClangdSession(files: ["main.cpp": source])
        try await session.start(capabilities: ["textDocument": ["semanticTokens": [
            "requests": ["full": true], "formats": ["relative"],
            "tokenTypes": .array(SemanticTokenLegend.clientTypes.map(JSONValue.string)),
            "tokenModifiers": .array(SemanticTokenLegend.clientModifiers.map(JSONValue.string)),
        ]]])
        let legend = try #require(SemanticTokenLegend(initializeResult: session.initializeResult))
        try session.open("main.cpp")
        let raw = try await session.poll("textDocument/semanticTokens/full", ["textDocument": ["uri": session.uri("main.cpp")]]) {
            !legend.decode($0).isEmpty
        }
        let tokens = legend.decode(raw)
        let lines = source.components(separatedBy: "\n")
        func text(_ t: SemanticToken) -> String {
            (lines[t.line] as NSString).substring(with: NSRange(location: t.start, length: t.length))
        }
        let byText = Dictionary(tokens.map { (text($0) + "@\($0.line)", $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byText["shop@7"]?.type == "namespace")
        #expect(byText["Order@7"]?.type == "class" || byText["Order@7"]?.type == "struct")
        #expect(byText["o@7"]?.type == "parameter")
        #expect(byText["id@7"]?.type == "property")
        #expect(byText["MAX@7"]?.type == "macro")
        #expect(byText["limit@7"]?.modifiers.contains("readonly") == true)
        await session.shutdown()
    }
}
