import Foundation
import Testing
@testable import CppIDECore

@Suite struct ReferencesTests {
    @Test func groupsLocationsWithPreviews() {
        func loc(_ uri: String, _ line: Int, _ c1: Int, _ c2: Int) -> Location {
            Location(uri: uri, start: TextPosition(line: line, character: c1), end: TextPosition(line: line, character: c2))
        }
        let files = [
            "/p/a.cpp": "// a\n\nvoid Foo() {}\n",
            "/p/b.cpp": "// b\n\nvoid bar() {\n\tFoo()\n\tFoo()\n}\n",
        ]
        let results = ProjectSearch.results(
            for: [loc("file:///p/b.cpp", 4, 1, 4), loc("file:///p/a.cpp", 2, 5, 8), loc("file:///p/b.cpp", 3, 1, 4)],
            text: { files[$0] })
        #expect(results.map(\.path) == ["/p/a.cpp", "/p/b.cpp"])
        #expect(results[1].matches.map(\.line) == [3, 4])
        #expect(results[1].matches[0].preview == "Foo()")
        #expect(results[1].matches[0].previewRange == NSRange(location: 0, length: 3))
    }

    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func clangdFindsReferences() async throws {
        let session = try ClangdSession(files: [
            "helper.h": "#pragma once\nint helper();\n",
            "helper.cpp": "#include \"helper.h\"\n\nint helper() { return 1; }\n",
            "main.cpp": "#include \"helper.h\"\n\nint main() {\n    return helper() + helper();\n}\n",
        ])
        try await session.start()
        try session.open("main.cpp")
        let params: JSONValue = [
            "textDocument": ["uri": session.uri("main.cpp")],
            "position": TextPosition(line: 3, character: 12).json,
            "context": ["includeDeclaration": true],
        ]
        // The other translation unit's uses arrive once the background index has it.
        let result = try await session.poll("textDocument/references", params) {
            Location.parseAll($0).contains { $0.uri.hasSuffix("/helper.cpp") }
        }
        let locations = Location.parseAll(result)
        #expect(locations.filter { $0.uri.hasSuffix("/main.cpp") }.count == 2)
        #expect(locations.contains { $0.uri.hasSuffix("/helper.h") && $0.start.line == 1 })
        #expect(locations.contains { $0.uri.hasSuffix("/helper.cpp") && $0.start.line == 2 })
        await session.shutdown()
    }
}
