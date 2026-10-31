import Foundation
import Testing
@testable import CppIDECore

let hasClangd = ToolLocator.find("clangd") != nil

/// A throwaway C++ project with a running clangd, for integration tests.
/// Sources get a `compile_commands.json` so clangd has real flags right away and its
/// background index covers files that aren't open (cross-file references, workspace symbols).
final class ClangdSession: @unchecked Sendable {
    let dir: URL
    let client = LSPClient()
    private(set) var initializeResult: JSONValue = .null
    private let base: URL

    init(files: [String: String], compilationDatabase: Bool = true) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cppide-clangd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.canonicalFileURL
        for (name, text) in files {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        if compilationDatabase { try writeCompilationDatabase(in: dir, files: Array(files.keys)) }
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
    func uri(_ name: String) -> JSONValue { .string(url(name).absoluteString) }

    /// Starts clangd and sends initialize/initialized.
    func start(capabilities: JSONValue = [:], initializationOptions: JSONValue = ClangdSettings.default,
               onNotification: LSPClient.NotificationHandler? = nil) async throws {
        client.onNotification = onNotification
        try client.start(executable: try #require(ToolLocator.find("clangd")), arguments: ClangdSettings.arguments,
                         environment: ToolLocator.environment(), currentDirectory: dir)
        initializeResult = try await client.request("initialize", params: [
            "processId": .int(Int(getpid())),
            "rootUri": .string(dir.absoluteString),
            "capabilities": capabilities,
            "initializationOptions": initializationOptions,
        ])
        try client.notify("initialized", params: [:])
    }

    func open(_ name: String, dialect: SourceDialect = .mixed) throws {
        let text = try String(contentsOf: url(name), encoding: .utf8)
        try client.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": uri(name), "languageId": .string(SourceKind.languageID(for: url(name), dialect: dialect)),
                             "version": 1, "text": .string(text)],
        ])
    }

    func at(_ name: String, _ line: Int, _ character: Int) -> JSONValue {
        ["textDocument": ["uri": uri(name)], "position": TextPosition(line: line, character: character).json]
    }

    /// Retries a request until `accept` passes (clangd builds ASTs / indexes asynchronously).
    func poll(_ method: String, _ params: JSONValue, attempts: Int = 40,
              until accept: (JSONValue) -> Bool) async throws -> JSONValue {
        var last: JSONValue = .null
        for _ in 0..<attempts {
            last = try await client.request(method, params: params)
            if accept(last) { return last }
            try await Task.sleep(for: .milliseconds(250))
        }
        return last
    }

    func shutdown() async { await client.shutdown() }
}

/// A compile_commands.json listing every source file (headers are inferred by clangd).
func writeCompilationDatabase(in dir: URL, files: [String]) throws {
    let entries: [JSONValue] = files.filter { SourceKind.sourceExtensions.contains(($0 as NSString).pathExtension) }.sorted().map { name in
        let path = dir.appendingPathComponent(name).path
        return ["directory": .string(dir.path), "file": .string(path),
                "arguments": ["clang++", "-std=c++20", "-c", .string(path)]]
    }
    try JSONEncoder().encode(JSONValue.array(entries)).write(to: dir.appendingPathComponent("compile_commands.json"))
}
