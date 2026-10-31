import Foundation

/// How to run/debug a program: which target, with what arguments and environment.
public struct RunConfiguration: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    /// What to run: a CMake executable target name, a source file with `main` (relative to the
    /// project root, compiled on its own), or a path to a program the build produces.
    public var target: String
    /// Program arguments, shell-style (quotes group words).
    public var arguments: String
    /// Extra environment, one `KEY=value` per line.
    public var environment: String

    public init(name: String, target: String, arguments: String = "", environment: String = "") {
        self.name = name
        self.target = target
        self.arguments = arguments
        self.environment = environment
    }

    public var argumentList: [String] { ShellWords.split(arguments) }

    public var environmentVariables: [String: String] {
        var result: [String: String] = [:]
        for line in environment.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            result[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...])
        }
        return result
    }
}

public enum ShellWords {
    /// Splits like a shell: whitespace separates words; '…' and "…" group; backslash escapes.
    public static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for c in line {
            if escaped {
                current.append(c)
                escaped = false
            } else if c == "\\" && quote != "'" {
                escaped = true
                inWord = true
            } else if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
                inWord = true
            } else if c.isWhitespace {
                if inWord { words.append(current); current = ""; inWord = false }
            } else {
                current.append(c)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}

