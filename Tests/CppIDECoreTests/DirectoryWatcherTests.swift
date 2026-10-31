import Foundation
import Testing
@testable import CppIDECore

@Suite struct DirectoryWatcherTests {
    @Test(.timeLimit(.minutes(1)))
    func reportsCreatedFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cppide-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (stream, continuation) = AsyncStream<[String]>.makeStream()
        let watcher = try #require(DirectoryWatcher(url: dir.canonicalFileURL) { continuation.yield($0) })
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))  // let the stream start
        try "int x;\n".write(to: dir.appendingPathComponent("new.cpp"), atomically: true, encoding: .utf8)

        for await paths in stream where paths.contains(where: { $0.hasSuffix("/new.cpp") }) {
            return  // success
        }
    }
}
