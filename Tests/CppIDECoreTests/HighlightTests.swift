import Foundation
import Testing
@testable import CppIDECore

@Suite struct DocumentHighlightTests {
    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func clangdHighlightsReadsAndWrites() async throws {
        let source = "int printf(const char *, ...);\n\nint main() {\n    int total = 1;\n    total = total + 2;\n    printf(\"%d\", total);\n}\n"
        let session = try ClangdSession(files: ["main.cpp": source])
        try await session.start()
        try session.open("main.cpp")
        let result = try await session.poll("textDocument/documentHighlight", session.at("main.cpp", 5, 18)) {
            !DocumentHighlight.parseAll($0).isEmpty
        }
        let highlights = DocumentHighlight.parseAll(result)
        #expect(highlights.count == 4)
        #expect(highlights.contains { $0.start.line == 4 && $0.start.character == 4 && $0.kind == .write })
        #expect(highlights.contains { $0.start.line == 5 && $0.kind == .read })
        await session.shutdown()
    }
}
