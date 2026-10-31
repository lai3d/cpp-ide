import Foundation
import Testing
@testable import CppIDECore

@Suite struct GitTests {
    @Test func parsesPorcelainStatus() {
        let porcelain = " M a.cpp\0A  b.cpp\0?? new.cpp\0R  newname.cpp\0oldname.cpp\0 D gone.cpp\0UU c.cpp\0"
        let statuses = Git.parseStatus(porcelain, root: "/r")
        #expect(statuses == ["/r/a.cpp": .modified, "/r/b.cpp": .added, "/r/new.cpp": .untracked,
                             "/r/newname.cpp": .renamed, "/r/gone.cpp": .deleted, "/r/c.cpp": .conflicted])
    }

    @Test func classifiesLineChanges() {
        let base = "a\nb\nc\nd\ne\n"
        let current = "a\nB\nc\nnew1\nnew2\nd\n"  // b->B modified; 2 added after c; e deleted
        let changes = LineChanges.compute(base: base, current: current)
        #expect(changes.lines == [1: .modified, 3: .added, 4: .added])
        #expect(changes.deletions == [6])
        #expect(LineChanges.compute(base: base, current: base).isEmpty)
    }

    @Test(.enabled(if: ToolLocator.find("git") != nil))
    func readsRealRepository() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cppide-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        Git.run(["init", "-q", "-b", "trunk"], in: dir)
        try "int main();\n".write(to: dir.appendingPathComponent("main.cpp"), atomically: true, encoding: .utf8)
        Git.run(["add", "."], in: dir)
        Git.run(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"], in: dir)
        try "int main();\n\nint main() { return 0; }\n".write(to: dir.appendingPathComponent("main.cpp"), atomically: true, encoding: .utf8)
        try "int main();\n".write(to: dir.appendingPathComponent("extra.cpp"), atomically: true, encoding: .utf8)

        #expect(Git.topLevel(of: dir)?.path == dir.path)
        #expect(Git.currentBranch(in: dir) == "trunk")
        let statuses = Git.status(in: dir)
        #expect(statuses[dir.appendingPathComponent("main.cpp").path] == .modified)
        #expect(statuses[dir.appendingPathComponent("extra.cpp").path] == .untracked)
        #expect(Git.headContents(of: dir.appendingPathComponent("main.cpp"), topLevel: dir) == "int main();\n")
        #expect(Git.headContents(of: dir.appendingPathComponent("extra.cpp"), topLevel: dir) == nil)

        // Blame the buffer: line 0 is committed, line 2 is new (uncommitted).
        let buffer = "int main();\n\nint main() { return 0; }\n"
        let committed = try #require(Git.blame(file: dir.appendingPathComponent("main.cpp"), line: 0, contents: buffer, topLevel: dir))
        #expect(committed.author == "t" && committed.summary == "init" && !committed.isUncommitted)
        let fresh = try #require(Git.blame(file: dir.appendingPathComponent("main.cpp"), line: 2, contents: buffer, topLevel: dir))
        #expect(fresh.isUncommitted)
    }
}

@Suite struct SideBySideDiffTests {
    @Test func alignsAndFoldsUnchangedLines() {
        let base = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...20).map { "line \($0)" }
        lines[9] = "line 10 changed"          // changed
        lines.insert("inserted", at: 15)      // added after line 15
        lines.remove(at: 19)                  // line 19 removed (index shifted by the insert)
        let rows = SideBySideDiff.rows(base: base, current: lines.joined(separator: "\n") + "\n", context: 1)
        let kinds = rows.map(\.kind)
        #expect(kinds.first == .gap(8))
        #expect(rows.contains { $0.kind == .changed && $0.left?.text == "line 10" && $0.right?.text == "line 10 changed" })
        #expect(rows.contains { $0.kind == .added && $0.right?.text == "inserted" && $0.left == nil })
        #expect(rows.contains { $0.kind == .removed && $0.left?.number == 19 && $0.right == nil })
        #expect(SideBySideDiff.rows(base: base, current: base) == [DiffRow(id: 0, kind: .gap(20), left: nil, right: nil)])
    }
}

@Suite struct GitChangeTests {
    @Test func parsesIndexAndWorkTreeColumns() {
        let changes = GitChange.parse("MM a.cpp\0A  b.cpp\0 M c.cpp\0?? d.cpp\0", root: "/r")
        #expect(changes.map(\.path) == ["/r/a.cpp", "/r/b.cpp", "/r/c.cpp", "/r/d.cpp"])
        #expect(changes.map(\.isStaged) == [true, true, false, false])
        #expect(changes.map(\.hasUnstagedChanges) == [true, false, true, true])
        #expect(changes[3].isUntracked)
    }

    @Test(.enabled(if: ToolLocator.find("git") != nil))
    func stagesUnstagesDiscardsAndCommits() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cppide-scm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        Git.run(["init", "-q", "-b", "main"], in: dir)
        Git.run(["config", "user.name", "Tester"], in: dir)
        Git.run(["config", "user.email", "t@example.com"], in: dir)
        let a = dir.appendingPathComponent("a.cpp"), b = dir.appendingPathComponent("b.cpp")
        try "package a\n".write(to: a, atomically: true, encoding: .utf8)
        try "package b\n".write(to: b, atomically: true, encoding: .utf8)
        #expect(Git.stage([a.path, b.path], in: dir) == nil)
        #expect(Git.commit(message: "first", in: dir) == nil)

        try "package a // edit\n".write(to: a, atomically: true, encoding: .utf8)
        try "package b // edit\n".write(to: b, atomically: true, encoding: .utf8)
        #expect(Git.stage([a.path], in: dir) == nil)
        var changes = Git.changes(in: dir)
        #expect(changes.first { $0.path == a.path }?.isStaged == true)
        #expect(changes.first { $0.path == b.path }?.isStaged == false)

        #expect(Git.unstage([a.path], in: dir) == nil)
        #expect(Git.changes(in: dir).allSatisfy { !$0.isStaged })
        #expect(Git.discard([b.path], in: dir) == nil)
        #expect(try String(contentsOf: b, encoding: .utf8) == "package b\n")

        #expect(Git.stage([a.path], in: dir) == nil)
        #expect(Git.commit(message: "Edit a\n\nWith a body.", in: dir) == nil)
        changes = Git.changes(in: dir)
        #expect(changes.isEmpty)
        #expect(Git.run(["log", "-1", "--format=%s"], in: dir).output.trimmingCharacters(in: .whitespacesAndNewlines) == "Edit a")
        #expect(Git.commit(message: "nothing", in: dir) != nil)  // nothing to commit: error text
    }
}
