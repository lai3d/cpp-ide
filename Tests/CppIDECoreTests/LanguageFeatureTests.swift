import Foundation
import Testing
@testable import CppIDECore

@Suite struct CompletionParsingTests {
    @Test func parsesCompletionListSortedBySortText() {
        let result: JSONValue = ["isIncomplete": false, "items": [
            ["label": "Printf", "kind": 3, "sortText": "00001", "detail": "func(format string, a ...any)"],
            ["label": "Println", "kind": 3, "sortText": "00000",
             "textEdit": ["range": ["start": ["line": 8, "character": 5], "end": ["line": 8, "character": 8]],
                          "newText": "Println"],
             "documentation": ["kind": "markdown", "value": "Println formats…"]],
        ]]
        let items = CompletionItem.parseList(result)
        #expect(items.map(\.label) == ["Println", "Printf"])
        #expect(items[0].kind == .function)
        #expect(items[0].documentation == "Println formats…")
        #expect(items[1].detail == "func(format string, a ...any)")
    }

    @Test func parsesBareArrayAndAdditionalEdits() {
        let result: JSONValue = [[
            "label": "strings", "kind": 9, "insertText": "strings",
            "additionalTextEdits": [["range": ["start": ["line": 2, "character": 0], "end": ["line": 2, "character": 0]],
                                     "newText": "import \"strings\"\n"]],
        ]]
        let item = try! #require(CompletionItem.parseList(result).first)
        #expect(item.kind == .module)
        #expect(item.additionalEdits == [TextEdit(start: TextPosition(line: 2, character: 0),
                                                  end: TextPosition(line: 2, character: 0),
                                                  newText: "import \"strings\"\n")])
    }

    @Test func stripsSnippets() {
        #expect(CompletionItem.stripSnippet("Foo(${1:a}, ${2:b})$0") == "Foo(a, b)")
        let item = CompletionItem.parse(["label": "x", "insertText": "x($1)", "insertTextFormat": 2])
        #expect(item?.insertText == "x()" && item?.snippet == "x($1)")
    }

    @Test func fuzzyMatches() {
        #expect(FuzzyMatch.matches("", "anything"))
        #expect(FuzzyMatch.matches("prl", "Println"))
        #expect(FuzzyMatch.matches("Pri", "Printf"))
        #expect(!FuzzyMatch.matches("ln", "Println"))  // first letter must match
        #expect(!FuzzyMatch.matches("Pz", "Println"))
    }
}

@Suite struct HoverAndLocationTests {
    @Test func parsesMarkupHover() {
        let result: JSONValue = ["contents": ["kind": "markdown", "value": "```go\nfunc Println(a ...any)\n```\n\nPrintln formats."]]
        let markdown = HoverContent.parse(result)
        #expect(markdown?.hasPrefix("```go") == true)
        let blocks = MarkdownBlock.parse(markdown!)
        #expect(blocks == [MarkdownBlock(kind: .code, text: "func Println(a ...any)"),
                           MarkdownBlock(kind: .text, text: "Println formats.")])
    }

    @Test func treatsHorizontalRulesAsSeparators() {
        let blocks = MarkdownBlock.parse("```go\nfunc F()\n```\n\n---\n\nDocs here.\n\n---\n\n[link](https://pkg.go.dev)")
        #expect(blocks.map(\.text) == ["func F()", "Docs here.", "[link](https://pkg.go.dev)"])
    }

    @Test func parsesMarkedStringArrays() {
        let result: JSONValue = ["contents": [["language": "go", "value": "var x int"], "doc"]]
        #expect(HoverContent.parse(result) == "```go\nvar x int\n```\n\ndoc")
        #expect(HoverContent.parse(["contents": ""]) == nil)
    }

    @Test func parsesLocationsAndLinks() {
        let range: JSONValue = ["start": ["line": 4, "character": 5], "end": ["line": 4, "character": 11]]
        #expect(Location.parseAll(["uri": "file:///a.go", "range": range]).map(\.uri) == ["file:///a.go"])
        let links = Location.parseAll([["targetUri": "file:///b.go", "targetRange": range, "targetSelectionRange": range]])
        #expect(links == [Location(uri: "file:///b.go", start: TextPosition(line: 4, character: 5),
                                   end: TextPosition(line: 4, character: 11))])
        #expect(Location.parseAll(.null).isEmpty)
    }
}

@Suite struct IdentifierTests {
    @Test func findsCallStart() {
        let text = "\tfmt.Printf(\"%d\", len(xs), " as NSString
        #expect(Identifier.callStart(in: text, before: text.length) == 1)  // fmt.Printf, skipping len(xs)
        let inner = "x := strings.ToUpper(s.Trim(" as NSString
        #expect(Identifier.callStart(in: inner, before: inner.length) == 21)  // s.Trim
        #expect(Identifier.callStart(in: "a + b" as NSString, before: 5) == nil)
    }

    @Test func findsPrefixAndWords() {
        let text = "\tfmt.Prin x1 42" as NSString
        #expect(Identifier.prefixStart(in: text, before: 9) == 5)  // "Prin"
        #expect(Identifier.prefixStart(in: text, before: 5) == 5)  // right after "."
        #expect(Identifier.wordRange(in: text, at: 2) == NSRange(location: 1, length: 3))  // "fmt"
        #expect(Identifier.wordRange(in: text, at: 4) == nil)  // "."
        #expect(Identifier.wordRange(in: text, at: 11) == NSRange(location: 10, length: 2))  // "x1"
        #expect(Identifier.wordRange(in: text, at: 13) == nil)  // number literal
    }
}

/// End-to-end checks against a real clangd (skipped when clangd isn't installed).
@Suite struct ClangdLanguageFeatureTests {
    static let source = """
        #include <string>

        int helper() { return 1; }

        int main() {
            std::string name = "x";
            name.append("y");
            name.app
            return helper();
        }

        """

    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func completionHoverAndDefinition() async throws {
        let session = try ClangdSession(files: ["main.cpp": Self.source])
        try await session.start(capabilities: ["textDocument": [
            "hover": ["contentFormat": ["markdown"]],
            "completion": ["completionItem": ["snippetSupport": true]],
        ]])
        try session.open("main.cpp")

        // `    name.app|` on line 7
        let completion = try await session.poll("textDocument/completion", session.at("main.cpp", 7, 12)) {
            // Until the preamble is built clangd answers with plain identifiers (kind text).
            CompletionItem.parseList($0).contains { $0.filterText == "append" && $0.kind == .method }
        }
        let items = CompletionItem.parseList(completion)
        #expect(items.contains { $0.filterText == "append" && $0.kind == .method && $0.insertText.hasPrefix("append") })
        #expect(items.allSatisfy { FuzzyMatch.matches("app", $0.filterText) })

        // Hover on `helper` in `return helper();` (line 8)
        let hover = HoverContent.parse(try await session.poll("textDocument/hover", session.at("main.cpp", 8, 12)) {
            HoverContent.parse($0) != nil
        })
        #expect(hover?.contains("helper") == true && hover?.contains("int") == true, "hover was: \(hover ?? "nil")")

        // Definition of `helper` -> line 2
        let locations = Location.parseAll(try await session.client.request("textDocument/definition",
                                                                           params: session.at("main.cpp", 8, 12)))
        #expect(locations.first?.uri.hasSuffix("/main.cpp") == true)
        #expect(locations.first?.start.line == 2)

        // Definition of `std::string` -> a standard library header outside the project
        let stdlib = Location.parseAll(try await session.client.request("textDocument/definition",
                                                                        params: session.at("main.cpp", 5, 10)))
        let header = try #require(stdlib.first?.uri)
        #expect(!header.contains(session.dir.path) && header.contains("include"), "\(header)")
        await session.shutdown()
    }

    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func switchesBetweenHeaderAndSource() async throws {
        let session = try ClangdSession(files: [
            "greeter.h": "#pragma once\nint greet();\n",
            "greeter.cpp": "#include \"greeter.h\"\nint greet() { return 1; }\n",
        ])
        try await session.start()
        try session.open("greeter.cpp")
        let header = try await session.client.request("textDocument/switchSourceHeader", params: ["uri": session.uri("greeter.cpp")])
        #expect(header.stringValue?.hasSuffix("/greeter.h") == true)
        let source = try await session.client.request("textDocument/switchSourceHeader", params: ["uri": session.uri("greeter.h")])
        #expect(source.stringValue?.hasSuffix("/greeter.cpp") == true)
        await session.shutdown()
    }
}

@Suite struct ExpressionRangeTests {
    @Test func findsSelectorChains() {
        let text = "x := order.Items[0] + o.p.q" as NSString
        func expr(_ at: Int) -> String? { Identifier.expressionRange(in: text, at: at).map { text.substring(with: $0) } }
        #expect(expr(12) == "order.Items")   // on "Items"
        #expect(expr(6) == "order")          // on "order"
        #expect(expr(26) == "o.p.q")
        #expect(expr(3) == nil)              // ":="
    }
}
