import Foundation
import Testing
@testable import CppIDECore

@Suite struct SignatureHelpTests {
    @Test func parsesStringAndOffsetLabels() throws {
        let help = try #require(SignatureHelp.parse([
            "signatures": [[
                "label": "Printf(format string, a ...any) (n int, err error)",
                "documentation": ["kind": "markdown", "value": "Printf formats."],
                "parameters": [["label": "format string"], ["label": [22, 30]]],
            ]],
            "activeSignature": 0, "activeParameter": 1,
        ]))
        let label = help.active!.label as NSString
        #expect(label.substring(with: help.active!.parameters[0]) == "format string")
        #expect(label.substring(with: try #require(help.activeParameterRange)) == "a ...any")
        #expect(help.active?.documentation == "Printf formats.")
    }

    @Test func perSignatureActiveParameterWins() throws {
        let help = try #require(SignatureHelp.parse([
            "signatures": [["label": "f(a, b)", "parameters": [["label": "a"], ["label": "b"]], "activeParameter": 1]],
            "activeParameter": 0,
        ]))
        #expect(help.activeParameterRange == NSRange(location: 5, length: 1))
        #expect(SignatureHelp.parse(["signatures": []]) == nil)
    }

    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func clangdSignatureHelp() async throws {
        let source = "int scale(int value, double factor);\n\nint main() {\n    return scale(1, 2.0);\n}\n"
        let session = try ClangdSession(files: ["main.cpp": source])
        try await session.start(capabilities: ["textDocument": ["signatureHelp": ["signatureInformation": [
            "parameterInformation": ["labelOffsetSupport": true]]]]])
        try session.open("main.cpp")
        func help(_ character: Int) async throws -> SignatureHelp? {
            let raw = try await session.poll("textDocument/signatureHelp", session.at("main.cpp", 3, character)) {
                SignatureHelp.parse($0) != nil
            }
            return SignatureHelp.parse(raw)
        }
        // `    return scale(1|, 2.0|);`
        let first = try #require(try await help(18))
        #expect(first.active?.label.contains("int value") == true)
        let firstLabel = first.active!.label as NSString
        #expect(firstLabel.substring(with: try #require(first.activeParameterRange)) == "int value")
        let second = try #require(try await help(23))
        let secondLabel = second.active!.label as NSString
        #expect(secondLabel.substring(with: try #require(second.activeParameterRange)) == "double factor")
        await session.shutdown()
    }
}
