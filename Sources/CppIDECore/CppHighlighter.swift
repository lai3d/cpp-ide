import Foundation

public enum TokenKind: Sendable, Hashable {
    case keyword, type, builtin, function, string, comment, number, preprocessor
}

public struct SyntaxToken: Sendable, Hashable {
    public let range: NSRange
    public let kind: TokenKind

    public init(range: NSRange, kind: TokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// A fast, regex-based C / C++ / Objective-C lexer for syntax highlighting.
/// clangd's semantic tokens refine it (types, macros, members…) once the server is ready.
public enum CppHighlighter {
    public static let keywords: Set<String> = [
        // C
        "auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern",
        "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof", "static", "struct",
        "switch", "typedef", "union", "volatile", "while", "_Alignas", "_Alignof", "_Atomic", "_Generic",
        "_Noreturn", "_Static_assert", "_Thread_local",
        // C++
        "alignas", "alignof", "and", "and_eq", "asm", "bitand", "bitor", "catch", "class", "co_await",
        "co_return", "co_yield", "compl", "concept", "consteval", "constexpr", "constinit", "const_cast",
        "decltype", "delete", "dynamic_cast", "explicit", "export", "final", "friend", "import", "module",
        "mutable", "namespace", "new", "noexcept", "not", "not_eq", "operator", "or", "or_eq", "override",
        "private", "protected", "public", "reinterpret_cast", "requires", "static_assert", "static_cast",
        "template", "this", "thread_local", "throw", "try", "typeid", "typename", "using", "virtual",
        "xor", "xor_eq",
    ]

    public static let types: Set<String> = [
        "bool", "char", "char8_t", "char16_t", "char32_t", "double", "float", "int", "long", "short",
        "signed", "unsigned", "void", "wchar_t", "_Bool", "_Complex",
        "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t", "int8_t", "int16_t", "int32_t", "int64_t",
        "uint8_t", "uint16_t", "uint32_t", "uint64_t", "FILE", "std",
    ]

    public static let builtins: Set<String> = [
        "true", "false", "nullptr", "NULL", "TRUE", "FALSE", "nil", "YES", "NO", "self", "super",
        "__func__", "__FILE__", "__LINE__",
    ]

    // Alternation order matters: comments and strings win over anything inside them.
    private static let regex = try! NSRegularExpression(pattern: [
        #"(//[^\n]*|/\*[\s\S]*?(?:\*/|$(?![\s\S])))"#,                                 // 1: comment
        #"((?:u8|[uUL])?R"([^()\\\s]{0,16})\([\s\S]*?(?:\)\3"|$(?![\s\S])))"#,          // 2: raw string (3: delimiter)
        #"((?:u8|[uUL@])?"(?:\\.|[^"\\\n])*"?|(?:u8|[uUL])?'(?:\\.|[^'\\\n])*'?)"#,    // 4: string / char
        #"(^[ \t]*#[ \t]*[A-Za-z_]+)"#,                                                 // 5: preprocessor directive
        #"(\b(?:0[xX][0-9a-fA-F']+(?:\.[0-9a-fA-F']*)?(?:[pP][+-]?\d+)?|0[bB][01']+|(?:\d[\d']*\.?[\d']*|\.\d[\d']*)(?:[eE][+-]?\d+)?)[uUlLfFzZ]*\b)"#, // 6: number
        #"([\p{L}_][\p{L}\p{Nd}_]*)"#,                                                  // 7: identifier
    ].joined(separator: "|"), options: .anchorsMatchLines)

    public static func tokenize(_ text: String) -> [SyntaxToken] {
        let ns = text as NSString
        var tokens: [SyntaxToken] = []
        var includeLine = false  // after #include / #import the <path> is a string
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            if match.range(at: 1).location != NSNotFound {
                tokens.append(SyntaxToken(range: match.range, kind: .comment))
            } else if match.range(at: 2).location != NSNotFound || match.range(at: 4).location != NSNotFound {
                tokens.append(SyntaxToken(range: match.range, kind: .string))
            } else if match.range(at: 5).location != NSNotFound {
                tokens.append(SyntaxToken(range: match.range, kind: .preprocessor))
                let directive = ns.substring(with: match.range).filter { $0.isLetter }
                if directive == "include" || directive == "import" || directive == "include_next",
                   let path = angleIncludePath(ns, after: NSMaxRange(match.range)) {
                    tokens.append(SyntaxToken(range: path, kind: .string))
                    includeLine = true
                }
            } else if match.range(at: 6).location != NSNotFound {
                tokens.append(SyntaxToken(range: match.range, kind: .number))
            } else {
                if includeLine, let last = tokens.last, last.kind == .string,
                   NSLocationInRange(match.range.location, last.range) { return }  // inside <path>
                includeLine = false
                let word = ns.substring(with: match.range)
                if keywords.contains(word) {
                    tokens.append(SyntaxToken(range: match.range, kind: .keyword))
                } else if types.contains(word) {
                    tokens.append(SyntaxToken(range: match.range, kind: .type))
                } else if builtins.contains(word) {
                    tokens.append(SyntaxToken(range: match.range, kind: .builtin))
                } else if isFollowedByParen(ns, at: NSMaxRange(match.range)) {
                    tokens.append(SyntaxToken(range: match.range, kind: .function))
                }
            }
        }
        return tokens
    }

    /// `<stdio.h>` after an include directive, on the same line.
    private static func angleIncludePath(_ ns: NSString, after index: Int) -> NSRange? {
        var i = index
        while i < ns.length, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        guard i < ns.length, ns.character(at: i) == 0x3C else { return nil }  // <
        var j = i + 1
        while j < ns.length {
            let c = ns.character(at: j)
            if c == 0x0A { return nil }
            if c == 0x3E { return NSRange(location: i, length: j - i + 1) }  // >
            j += 1
        }
        return nil
    }

    private static func isFollowedByParen(_ ns: NSString, at index: Int) -> Bool {
        var i = index
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x28 { return true }             // (
            if c != 0x20 && c != 0x09 { return false } // space / tab
            i += 1
        }
        return false
    }
}

/// File types CppIDE treats as C-family source (sent to clangd).
public enum SourceKind {
    public static let sourceExtensions: Set<String> = ["c", "cc", "cpp", "cxx", "c++", "m", "mm", "cu"]
    public static let headerExtensions: Set<String> = ["h", "hh", "hpp", "hxx", "h++", "inl", "ipp", "tpp", "cuh"]

    public static func isSource(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return sourceExtensions.contains(ext) || headerExtensions.contains(ext)
    }

    public static func isHeader(_ url: URL) -> Bool { headerExtensions.contains(url.pathExtension.lowercased()) }

    /// LSP languageId: clangd mostly goes by the compile command, but uses this for fallbacks.
    /// The LSP `languageId`; headers are C in a C-only project (`dialect` `.c`), else C++.
    public static func languageID(for url: URL, dialect: SourceDialect = .mixed) -> String {
        if dialect.isC(url) { return "c" }
        return switch url.pathExtension.lowercased() {
        case "m": "objective-c"
        case "mm": "objective-cpp"
        case "cu", "cuh": "cuda-cpp"
        default: "cpp"
        }
    }

    /// Files whose change should make clangd re-read the compilation database.
    public static func isBuildInput(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "compile_commands.json" || name == "compile_flags.txt" || name == ".clangd"
    }
}
