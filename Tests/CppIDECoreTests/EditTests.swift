import Foundation
import Testing
@testable import CppIDECore

@Suite struct EditTests {
    private func edit(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int, _ text: String) -> TextEdit {
        TextEdit(start: TextPosition(line: l1, character: c1), end: TextPosition(line: l2, character: c2), newText: text)
    }

    @Test func appliesEditsBackToFront() {
        let text = "// c\nvoid  main(){\n}\n"
        let result = TextEdit.apply([
            edit(1, 4, 1, 6, " "),       // "void  main" -> "void main"
            edit(1, 12, 1, 12, " "),     // "(){" -> "() {"
            edit(0, 0, 0, 0, "// x\n"),  // insert at top
        ], to: text)
        #expect(result == "// x\n// c\nvoid main() {\n}\n")
    }

    @Test func parsesWorkspaceEditForms() {
        let range: JSONValue = ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 3]]
        let changes = WorkspaceEdit.parse(["changes": ["file:///a.cpp": [["range": range, "newText": "x"]]]])
        #expect(changes.changes["file:///a.cpp"]?.first?.newText == "x")
        let documentChanges = WorkspaceEdit.parse(["documentChanges": [
            ["textDocument": ["uri": "file:///b.cpp", "version": 3], "edits": [["range": range, "newText": "y"]]],
            ["kind": "create", "uri": "file:///c.cpp"],
        ]])
        #expect(documentChanges.changes.keys.sorted() == ["file:///b.cpp"])
        #expect(documentChanges.creates == ["file:///c.cpp"])
    }

    @Test func parsesCodeActionsAndCommands() {
        let actions = CodeAction.parseAll([
            ["title": "insert ';'", "kind": "quickfix",
             "edit": ["changes": ["file:///a.cpp": []]]],
            ["title": "Apply fix", "command": "clangd.applyFix", "arguments": []],
        ])
        #expect(actions.map(\.title) == ["insert ';'", "Apply fix"])
        #expect(actions[0].edit != nil && actions[0].command == nil)
        #expect(actions[1].command?["command"]?.stringValue == "clangd.applyFix")
    }

    @Test func computesMinimalReplacement() {
        let r = TextDiff.replacement(from: "void  main() {}", to: "void main() {}")
        #expect(r?.range == NSRange(location: 5, length: 1) && r?.text == "")
        #expect(TextDiff.replacement(from: "same", to: "same") == nil)
        let tail = TextDiff.replacement(from: "a", to: "ab")
        #expect(tail?.range == NSRange(location: 1, length: 0) && tail?.text == "b")
        let emoji = TextDiff.replacement(from: "x😀", to: "x😃")
        #expect(emoji?.range == NSRange(location: 1, length: 2))
    }
}

@Suite struct ClangdFormattingTests {
    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func formatsAndOffersFixIts() async throws {
        let source = "int main(){\nint x=1\nreturn x;}\n"
        let session = try ClangdSession(files: ["main.cpp": source])
        let (stream, continuation) = AsyncStream<JSONValue>.makeStream()
        try await session.start(capabilities: ["textDocument": [
            "publishDiagnostics": ["codeActionsInline": true],
            "codeAction": ["codeActionLiteralSupport": ["codeActionKind": ["valueSet": ["quickfix"]]]],
        ]]) { method, params in
            if method == "textDocument/publishDiagnostics", !(params["diagnostics"]?.arrayValue ?? []).isEmpty {
                continuation.yield(params)
            }
        }
        try session.open("main.cpp")
        let uri = session.uri("main.cpp")

        // Missing ';' after `int x=1`: clangd offers the fix-it as a quick fix.
        var iterator = stream.makeAsyncIterator()
        let published = try #require(await iterator.next())
        let actions = CodeAction.parseAll(try await session.client.request("textDocument/codeAction", params: [
            "textDocument": ["uri": uri],
            "range": ["start": ["line": 1, "character": 0], "end": ["line": 1, "character": 8]],
            "context": ["diagnostics": published["diagnostics"] ?? [], "only": ["quickfix"]],
        ]))
        let fix = try #require(actions.first { $0.title.contains(";") })
        let fixed = TextEdit.apply(fix.edit?.changes[session.url("main.cpp").absoluteString] ?? [], to: source)
        #expect(fixed.contains("int x=1;"))

        try session.client.notify("textDocument/didChange", params: [
            "textDocument": ["uri": uri, "version": 2], "contentChanges": [["text": .string(fixed)]],
        ])
        let formatEdits = (try await session.client.request("textDocument/formatting", params: [
            "textDocument": ["uri": uri], "options": ["tabSize": 4, "insertSpaces": true],
        ])).arrayValue?.compactMap(TextEdit.parse) ?? []
        let formatted = TextEdit.apply(formatEdits, to: fixed)
        #expect(formatted.contains("int main() {\n  int x = 1;\n  return x;\n}"))  // LLVM style (no .clang-format)
        await session.shutdown()
    }
}
