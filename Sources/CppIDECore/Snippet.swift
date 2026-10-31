import Foundation

/// An expanded LSP snippet: plain text plus tab stops (`$1`, `${2:default}`, … then `$0`).
public struct Snippet: Sendable, Hashable {
    public let text: String
    /// UTF-16 ranges in `text`, in visiting order; the last is `$0` (or the end of the text).
    public let stops: [NSRange]

    public init(text: String, stops: [NSRange]) {
        self.text = text
        self.stops = stops
    }

    /// Parses LSP snippet syntax: `$n`, `${n}`, `${n:placeholder}` (nestable), `${n|a,b|}`
    /// (first choice), `$0`, and `\` escapes. Only the first occurrence of a stop is kept.
    public static func parse(_ snippet: String) -> Snippet {
        let chars = Array(snippet)
        var output = ""
        var length = 0  // UTF-16 length of output
        var stops: [Int: NSRange] = [:]
        var i = 0

        func append(_ c: Character) {
            output.append(c)
            length += c.utf16.count
        }

        func readNumber() -> Int? {
            var digits = ""
            while i < chars.count, chars[i].isNumber { digits.append(chars[i]); i += 1 }
            return Int(digits)
        }

        /// Parses until an unescaped "}" at this nesting level (consumed), or the end.
        func parseBody(untilBrace: Bool) {
            while i < chars.count {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count, "$}\\,|".contains(chars[i + 1]) {
                    // Only these are escapable; any other backslash is literal (e.g. "\n" in C strings).
                    append(chars[i + 1])
                    i += 2
                } else if untilBrace, c == "}" {
                    i += 1
                    return
                } else if c == "$", i + 1 < chars.count, chars[i + 1].isNumber {
                    i += 1
                    if let n = readNumber() {
                        if let first = stops[n] {
                            // A repeated stop mirrors the first one's text (`for (int i = 0; i < n; ++i)`).
                            (output as NSString).substring(with: first).forEach(append)
                        } else {
                            stops[n] = NSRange(location: length, length: 0)
                        }
                    }
                } else if c == "$", i + 1 < chars.count, chars[i + 1] == "{" {
                    i += 2
                    guard let n = readNumber() else { append("$"); continue }
                    let start = length
                    if i < chars.count, chars[i] == ":" {
                        i += 1
                        parseBody(untilBrace: true)
                    } else if i < chars.count, chars[i] == "|" {
                        // Choices: keep the first one.
                        i += 1
                        var choice = ""
                        while i < chars.count, chars[i] != "," && chars[i] != "|" { choice.append(chars[i]); i += 1 }
                        while i < chars.count, chars[i] != "}" { i += 1 }
                        i += 1
                        choice.forEach(append)
                    } else if i < chars.count, chars[i] == "}" {
                        i += 1
                    }
                    if stops[n] == nil { stops[n] = NSRange(location: start, length: length - start) }
                } else {
                    append(c)
                    i += 1
                }
            }
        }

        parseBody(untilBrace: false)
        var ordered = stops.filter { $0.key != 0 }.sorted { $0.key < $1.key }.map(\.value)
        ordered.append(stops[0] ?? NSRange(location: length, length: 0))
        return Snippet(text: output, stops: ordered)
    }

    /// Indents every line after the first (for insertion at an indented caret).
    public func indented(_ indent: String) -> Snippet {
        guard !indent.isEmpty, text.contains("\n") else { return self }
        let ns = text as NSString
        let extra = (indent as NSString).length
        var newlines: [Int] = []
        for i in 0..<ns.length where ns.character(at: i) == 0x0A { newlines.append(i) }
        let shifted = stops.map { stop -> NSRange in
            let before = newlines.filter { $0 < stop.location }.count
            let inside = newlines.filter { $0 >= stop.location && $0 < NSMaxRange(stop) }.count
            return NSRange(location: stop.location + before * extra, length: stop.length + inside * extra)
        }
        return Snippet(text: text.replacingOccurrences(of: "\n", with: "\n" + indent), stops: shifted)
    }
}

/// Built-in C/C++ snippets, offered in completion by trigger word.
public enum CppSnippets {
    /// Which files a snippet is offered in.
    public enum Language: Sendable { case both, c, cxx }

    public static let all: [(trigger: String, detail: String, body: String, language: Language)] = [
        ("main", "int main(int argc, char *argv[]) { … }", "int main(int argc, char *argv[]) {\n\t$0\n\treturn 0;\n}", .both),
        ("fori", "for (int i = 0; i < n; ++i) { … }", "for (${1:int} ${2:i} = 0; $2 < ${3:n}; ++$2) {\n\t$0\n}", .both),
        ("forr", "for (auto &x : range) { … }", "for (${1:const auto} &${2:item} : ${3:items}) {\n\t$0\n}", .cxx),
        ("while", "while (…) { … }", "while (${1:condition}) {\n\t$0\n}", .both),
        ("dowhile", "do { … } while (…);", "do {\n\t$0\n} while (${1:condition});", .both),
        ("ifel", "if (…) { … } else { … }", "if (${1:condition}) {\n\t$2\n} else {\n\t$0\n}", .both),
        ("sw", "switch (…) { case …: }", "switch (${1:value}) {\ncase ${2:0}:\n\t$0\n\tbreak;\ndefault:\n\tbreak;\n}", .both),
        ("class", "class Name { … };", "class ${1:Name} {\npublic:\n\t$1();\n\t~$1();\n\nprivate:\n\t$0\n};", .cxx),
        ("struct", "struct Name { … };", "struct ${1:Name} {\n\t$0\n};", .both),
        ("tstruct", "typedef struct { … } Name;", "typedef struct ${1:Name} {\n\t$0\n} $1;", .c),
        ("enum", "enum Name { … };", "enum ${1:Name} {\n\t$0\n};", .c),
        ("enumc", "enum class Name { … };", "enum class ${1:Name} {\n\t$0\n};", .cxx),
        ("ns", "namespace name { … }", "namespace ${1:name} {\n\n$0\n\n} // namespace $1", .cxx),
        ("tmpl", "template <typename T>", "template <typename ${1:T}>\n$0", .cxx),
        ("try", "try { … } catch (…) { … }", "try {\n\t$1\n} catch (const ${2:std::exception} &${3:e}) {\n\t$0\n}", .cxx),
        ("lambda", "[&](…) { … }", "[${1:&}](${2}) {\n\t$0\n}", .cxx),
        ("inc", "#include <…>", "#include <${1:vector}>$0", .cxx),
        ("inc", "#include <…>", "#include <${1:stdio.h}>$0", .c),
        ("incq", "#include \"…\"", "#include \"${1:header.h}\"$0", .both),
        ("once", "#pragma once", "#pragma once\n$0", .both),
        ("guard", "#ifndef … #define … #endif", "#ifndef ${1:HEADER_H}\n#define $1\n\n$0\n\n#endif // $1", .both),
        ("ifdef", "#ifdef … #endif", "#ifdef ${1:MACRO}\n$0\n#endif", .both),
        ("cout", "std::cout << … << '\\n';", "std::cout << ${1:value} << '\\n';$0", .cxx),
        ("cerr", "std::cerr << … << '\\n';", "std::cerr << ${1:value} << '\\n';$0", .cxx),
        ("printf", "printf(\"…\\n\", …);", "printf(\"${1:%d}\\n\", ${2:value});$0", .both),
        ("fprintf", "fprintf(stderr, \"…\\n\", …);", "fprintf(${1:stderr}, \"${2:%s}\\n\", ${3:value});$0", .c),
        ("malloc", "T *p = malloc(n * sizeof *p);",
         "${1:int} *${2:p} = malloc(${3:n} * sizeof *$2);\nif (!$2) {\n\t${4:return -1};\n}\n$0", .c),
        ("uptr", "std::make_unique<T>(…)", "std::make_unique<${1:T}>(${2})$0", .cxx),
        ("sptr", "std::make_shared<T>(…)", "std::make_shared<${1:T}>(${2})$0", .cxx),
        ("test", "TEST(Suite, Name) { … }", "TEST(${1:Suite}, ${2:Name}) {\n\t$0\n}", .cxx),
        ("testf", "TEST_F(Fixture, Name) { … }", "TEST_F(${1:Fixture}, ${2:Name}) {\n\t$0\n}", .cxx),
        ("tcase", "TEST_CASE(\"…\") { … }", "TEST_CASE(\"${1:name}\") {\n\t$0\n}", .cxx),
        ("utest", "Unity: void test_name(void) { … }",
         "void test_${1:name}(void) {\n\tTEST_ASSERT_EQUAL_INT(${2:expected}, ${3:actual});$0\n}", .c),
        ("cmtest", "CMocka: static void test_name(void **state) { … }",
         "static void test_${1:name}(void **state) {\n\t(void)state;\n\tassert_int_equal(${2:expected}, ${3:actual});$0\n}", .c),
    ]

    /// Completion items for snippets whose trigger matches `prefix` (fuzzy, needs ≥ 2 chars),
    /// limited to C or C++ ones by `isC`.
    public static func completions(matching prefix: String, isC: Bool = false) -> [CompletionItem] {
        guard prefix.count >= 2 else { return [] }
        return all.filter { $0.language == .both || ($0.language == .c) == isC }
            .filter { FuzzyMatch.matches(prefix, $0.trigger) }.map {
                CompletionItem(label: $0.trigger, kind: .snippet, detail: $0.detail,
                               insertText: Snippet.parse($0.body).text, sortText: "~" + $0.trigger, snippet: $0.body)
            }
    }
}
