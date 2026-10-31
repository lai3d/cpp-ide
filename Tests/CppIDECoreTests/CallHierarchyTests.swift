import Foundation
import Testing
@testable import CppIDECore

@Suite struct CallHierarchyTests {
    @Test(.enabled(if: hasClangd), .timeLimit(.minutes(1)))
    func clangdIncomingAndOutgoingCalls() async throws {
        let source = "void leaf() {}\n\nvoid middle() {\n    leaf();\n    leaf();\n}\n\nint main() {\n    middle();\n}\n"
        let session = try ClangdSession(files: ["main.cpp": source])
        try await session.start()
        try session.open("main.cpp")
        let prepared = try await session.poll("textDocument/prepareCallHierarchy", session.at("main.cpp", 2, 6)) {
            !CallHierarchyItem.parseAll($0).isEmpty
        }
        let middle = try #require(CallHierarchyItem.parseAll(prepared).first)
        #expect(middle.name == "middle" && middle.position.line == 2)

        // Incoming calls come from the index: wait for it.
        let incomingRaw = try await session.poll("callHierarchy/incomingCalls", ["item": middle.raw]) {
            !CallHierarchyCall.parseAll($0).isEmpty
        }
        let incoming = CallHierarchyCall.parseAll(incomingRaw)
        #expect(incoming.map(\.item.name) == ["main"])
        #expect(incoming.first?.callSites == [TextPosition(line: 8, character: 4)])

        // Outgoing calls arrived in clangd 20; older Xcode clangds (e.g. on CI) answer "method not found".
        do {
            let outgoingRaw = try await session.poll("callHierarchy/outgoingCalls", ["item": middle.raw]) {
                !CallHierarchyCall.parseAll($0).isEmpty
            }
            let outgoing = CallHierarchyCall.parseAll(outgoingRaw)
            #expect(outgoing.map(\.item.name) == ["leaf"])
            #expect(outgoing.first?.callSites.count == 2)
        } catch LSPClient.ClientError.server(code: -32601, message: _) {
            // Unsupported by this clangd.
        }
        await session.shutdown()
    }
}
