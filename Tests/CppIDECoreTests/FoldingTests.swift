import Foundation
import Testing
@testable import CppIDECore

@Suite struct FoldingTests {
    @Test func computesHiddenRanges() throws {
        let text = "void f() {\n\tint x = 1;\n}\n"
        let index = LineIndex(text)
        let withChars = FoldRegion(startLine: 0, startCharacter: 10, endLine: 2, endCharacter: 0)
        let hidden = try #require(withChars.hiddenRange(in: index))
        #expect((text as NSString).replacingCharacters(in: hidden, with: "⋯") == "void f() {⋯}\n")
        let linesOnly = FoldRegion(startLine: 0, endLine: 1)
        #expect((text as NSString).replacingCharacters(in: try #require(linesOnly.hiddenRange(in: index)), with: "⋯") == "void f() {⋯\n}\n")
        #expect(FoldRegion.parseAll([["startLine": 3, "endLine": 3]]).isEmpty)
    }

    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func clangdFoldingRanges() async throws {
        let source = "#include <cstdio>\n\nstruct Point {\n    int x;\n    int y;\n};\n\nint main() {\n    Point p{1, 2};\n    if (p.x > 0) {\n        std::printf(\"%d\\n\", p.y);\n    }\n}\n"
        let session = try ClangdSession(files: ["main.cpp": source])
        try await session.start(capabilities: ["textDocument": ["foldingRange": ["lineFoldingOnly": false]]])
        try session.open("main.cpp")
        let raw = try await session.poll("textDocument/foldingRange", ["textDocument": ["uri": session.uri("main.cpp")]]) {
            FoldRegion.parseAll($0).count >= 3
        }
        let regions = FoldRegion.parseAll(raw)
        let index = LineIndex(source)
        let folded = regions.compactMap { $0.hiddenRange(in: index) }.map { (source as NSString).replacingCharacters(in: $0, with: "⋯") }
        #expect(regions.contains { $0.startLine == 2 })  // struct body
        #expect(regions.contains { $0.startLine == 7 })  // function body
        #expect(regions.contains { $0.startLine == 9 })  // if block
        #expect(folded.contains { $0.contains("if (p.x > 0) {⋯}") })
        await session.shutdown()
    }
}
