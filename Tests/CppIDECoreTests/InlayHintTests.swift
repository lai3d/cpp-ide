import Foundation
import Testing
@testable import CppIDECore

@Suite struct InlayHintTests {
    @Test func parsesStringAndPartLabels() {
        let hints = InlayHint.parseAll([
            ["position": ["line": 3, "character": 9], "label": "name:", "kind": 2, "paddingRight": true],
            ["position": ["line": 4, "character": 2], "label": [["value": "int"]], "kind": 1, "paddingLeft": true],
        ])
        #expect(hints.map(\.label) == ["name:", "int"])
        #expect(hints[0].kind == .parameter && hints[0].paddingRight)
        #expect(hints[1].kind == .type && hints[1].paddingLeft)
    }

    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func clangdReturnsParameterAndTypeHints() async throws {
        let source = "void greet(const char *name, int times) {}\n\nint main() {\n    auto n = 3;\n    greet(\"x\", n);\n}\n"
        let session = try ClangdSession(files: ["main.cpp": source])
        try await session.start(capabilities: ["textDocument": ["inlayHint": [:]]])
        try session.open("main.cpp")
        let raw = try await session.poll("textDocument/inlayHint", [
            "textDocument": ["uri": session.uri("main.cpp")],
            "range": ["start": ["line": 0, "character": 0], "end": ["line": 6, "character": 0]],
        ]) { !InlayHint.parseAll($0).isEmpty }
        let hints = InlayHint.parseAll(raw)
        #expect(hints.contains { $0.label.contains("name") && $0.position.line == 4 && $0.kind == .parameter })
        #expect(hints.contains { $0.label.contains("times") && $0.position.line == 4 })
        #expect(hints.contains { $0.label.contains("int") && $0.position.line == 3 && $0.kind == .type })
        await session.shutdown()
    }
}
