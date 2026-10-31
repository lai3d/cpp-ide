import Foundation
import Testing
@testable import CppIDECore

/// Compiles `source` with debug info into a temp dir; returns (dir, source file, program).
private func compileDebuggee(_ source: String) throws -> (URL, URL, URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("cppide-dap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let dir = base.canonicalFileURL
    let file = dir.appendingPathComponent("main.cpp"), program = dir.appendingPathComponent("main")
    try source.write(to: file, atomically: true, encoding: .utf8)
    let clang = Process()
    clang.executableURL = try #require(ToolLocator.find("clang++"))
    clang.arguments = ["-std=c++20", "-g", "-O0", file.path, "-o", program.path]
    clang.environment = ToolLocator.environment()
    try clang.run()
    clang.waitUntilExit()
    try #require(clang.terminationStatus == 0)
    return (dir, file, program)
}

private let hasLLDBDAP = ToolLocator.find("lldb-dap") != nil && ToolLocator.find("clang++") != nil

/// Starts lldb-dap, launches `program` with `breakpoints`, and returns the first stopped thread.
private func launch(_ client: DAPClient, events: AsyncStream<(String, JSONValue)>, dir: URL, file: URL, program: URL,
                    breakpoints: JSONValue) async throws -> Int {
    try client.start(adapter: try #require(ToolLocator.find("lldb-dap")), directory: dir,
                     environment: ToolLocator.environment())
    _ = try await client.request("initialize", arguments: [
        "clientID": "cppide", "adapterID": "lldb-dap", "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
    ])
    _ = try await client.request("launch", arguments: [
        "program": .string(program.path), "cwd": .string(dir.path), "stopOnEntry": false,
    ])
    await client.waitForEvent("initialized")
    let set = try await client.request("setBreakpoints", arguments: [
        "source": ["path": .string(file.path)], "breakpoints": breakpoints,
    ])
    #expect(set["breakpoints"]?[0]?["verified"]?.boolValue == true)
    _ = try await client.request("configurationDone")
    for await (event, body) in events where event == "stopped" {
        return try #require(body["threadId"]?.intValue)
    }
    throw DAPClient.DAPError.notConnected
}

@Suite struct DAPTests {
    @Test(.enabled(if: hasLLDBDAP), .timeLimit(.minutes(2)))
    func launchesBreaksInspectsAndContinues() async throws {
        let (dir, file, program) = try compileDebuggee("""
            #include <cstdio>

            struct Point { int x; int y; };

            int main() {
                Point p{3, 4};
                int total = p.x + p.y;
                std::printf("total %d\\n", total);
                return 0;
            }

            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = DAPClient()
        let (events, continuation) = AsyncStream<(String, JSONValue)>.makeStream()
        client.onEvent = { continuation.yield(($0, $1)) }
        let thread = try await launch(client, events: events, dir: dir, file: file, program: program,
                                      breakpoints: [["line": 7]])

        let frames = StackFrame.parseAll(try await client.request("stackTrace", arguments: ["threadId": .int(thread), "levels": 20]))
        #expect(frames.first?.name.contains("main") == true && frames.first?.line == 7)
        #expect(frames.first?.path == file.path)

        let scopes = DebugVariable.parseScopes(try await client.request("scopes", arguments: ["frameId": .int(frames[0].id)]))
        let locals = try #require(scopes.first { $0.name == "Locals" })
        let variables = DebugVariable.parseVariables(try await client.request("variables", arguments: [
            "variablesReference": .int(locals.variablesReference),
        ]))
        let p = try #require(variables.first { $0.name == "p" })
        #expect(p.type == "Point" && p.variablesReference > 0)
        let fields = DebugVariable.parseVariables(try await client.request("variables", arguments: [
            "variablesReference": .int(p.variablesReference),
        ]))
        #expect(fields.map(\.name) == ["x", "y"])
        #expect(fields.map(\.value) == ["3", "4"])

        _ = try await client.request("next", arguments: ["threadId": .int(thread)])
        for await (event, _) in events where event == "stopped" { break }
        let afterStep = StackFrame.parseAll(try await client.request("stackTrace", arguments: ["threadId": .int(thread), "levels": 1]))
        #expect(afterStep.first?.line == 8)

        _ = try await client.request("continue", arguments: ["threadId": .int(thread)])
        var sawOutput = false, exitCode: Int?
        for await (event, body) in events {
            if event == "output", body["output"]?.stringValue?.contains("total 7") == true { sawOutput = true }
            if event == "exited" { exitCode = body["exitCode"]?.intValue }
            if event == "terminated" { break }
        }
        #expect(sawOutput)
        #expect(exitCode == 0)
        await client.shutdown()
    }

    @Test(.enabled(if: hasLLDBDAP), .timeLimit(.minutes(2)))
    func conditionalBreakpointAndEvaluate() async throws {
        let (dir, file, program) = try compileDebuggee("""
            int main() {
                int total = 0;
                for (int i = 0; i < 10; ++i) {
                    total += i;
                }
                return total == 45 ? 0 : 1;
            }

            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = DAPClient()
        let (events, continuation) = AsyncStream<(String, JSONValue)>.makeStream()
        client.onEvent = { continuation.yield(($0, $1)) }
        let thread = try await launch(client, events: events, dir: dir, file: file, program: program,
                                      breakpoints: [["line": 4, "condition": "i == 7"]])
        let frames = StackFrame.parseAll(try await client.request("stackTrace", arguments: ["threadId": .int(thread), "levels": 1]))
        let frame = try #require(frames.first).id
        func evaluate(_ expression: String, context: String = "hover") async throws -> String? {
            try await client.request("evaluate", arguments: [
                "expression": .string(expression), "frameId": .int(frame), "context": .string(context),
            ])["result"]?.stringValue
        }
        #expect(try await evaluate("i") == "7")              // stopped only when the condition held
        #expect(try await evaluate("total") == "21")         // 0+1+…+6
        // Hover uses lldb's frame-variable syntax (no arithmetic); watches run real expressions.
        #expect(try await evaluate("total * 2 + i", context: "watch") == "49")
        await client.shutdown()
    }
}
