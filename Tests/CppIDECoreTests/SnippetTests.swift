import Foundation
import Testing
@testable import CppIDECore

@Suite struct SnippetTests {
    private func parts(_ s: Snippet) -> [String] {
        s.stops.map { (s.text as NSString).substring(with: $0) }
    }

    @Test func parsesStopsPlaceholdersAndChoices() {
        let s = Snippet.parse("for ${1:i} := 0; ${1} < ${2:n}; ${3|i++,i--|} {\n\t$0\n}")
        #expect(s.text == "for i := 0;  < n; i++ {\n\t\n}")
        #expect(parts(s) == ["i", "n", "i++", ""])
        #expect(s.stops.last == NSRange(location: 25, length: 0))
    }

    @Test func parsesNestingAndEscapes() {
        let s = Snippet.parse("Printf(${1:\"${2:%v}\\n\"}, ${3:a ...any}) \\$x \\}")
        #expect(s.text == "Printf(\"%v\\n\", a ...any) $x }")
        #expect(parts(s) == ["\"%v\\n\"", "%v", "a ...any", ""])
        #expect(Snippet.parse("plain").stops == [NSRange(location: 5, length: 0)])
    }

    @Test func indentsFollowingLines() {
        let s = Snippet.parse("if err != nil {\n\treturn ${1:err}\n}$0").indented("\t\t")
        #expect(s.text == "if err != nil {\n\t\t\treturn err\n\t\t}")
        #expect(parts(s) == ["err", ""])
        #expect(s.stops.last == NSRange(location: (s.text as NSString).length, length: 0))
    }

    @Test func repeatedStopsMirrorTheFirst() {
        let fori = Snippet.parse(CppSnippets.all.first { $0.trigger == "fori" }!.body)
        #expect(fori.text == "for (int i = 0; i < n; ++i) {\n\t\n}")
        let guardSnippet = Snippet.parse(CppSnippets.all.first { $0.trigger == "guard" }!.body)
        #expect(guardSnippet.text.hasPrefix("#ifndef HEADER_H\n#define HEADER_H\n"))
        #expect(guardSnippet.text.hasSuffix("#endif // HEADER_H"))
    }

    @Test func builtInSnippetsMatchTriggers() {
        #expect(CppSnippets.completions(matching: "fori").map(\.label) == ["fori"])
        #expect(CppSnippets.completions(matching: "fo").map(\.label).contains("forr"))
        #expect(CppSnippets.completions(matching: "x").isEmpty)
        #expect(CppSnippets.all.allSatisfy { !Snippet.parse($0.body).stops.isEmpty })
        // Unique triggers within each language (`inc` has a C and a C++ variant).
        for isC in [true, false] {
            let offered = CppSnippets.all.filter { $0.language == .both || ($0.language == .c) == isC }
            #expect(Set(offered.map(\.trigger)).count == offered.count)
        }
    }
}
