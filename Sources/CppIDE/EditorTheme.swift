import AppKit
import CppIDECore

/// User-adjustable editor settings (stored in UserDefaults, edited in Settings).
struct EditorSettings: Equatable {
    static let fontSizeKey = "editorFontSize"
    static let tabWidthKey = "editorTabWidth"

    var fontSize: Double = 13
    var tabWidth: Int = 4
}

@MainActor
enum EditorTheme {
    static func font(_ settings: EditorSettings) -> NSFont {
        .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
    }

    static func paragraphStyle(_ settings: EditorSettings) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font(settings)]).width
        style.tabStops = []
        style.defaultTabInterval = spaceWidth * CGFloat(settings.tabWidth)
        return style
    }

    static func baseAttributes(_ settings: EditorSettings) -> [NSAttributedString.Key: Any] {
        [.font: font(settings), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle(settings)]
    }

    /// Colors for what only clangd knows (the regex lexer handles keywords, strings, …).
    static func color(forSemantic type: String, modifiers: Set<String>) -> NSColor? {
        switch type {
        case "namespace": .secondaryLabelColor  // std::vector
        case "type", "typeParameter", "struct", "interface", "class", "enum", "concept": .systemTeal
        case "macro": .systemBrown
        case "parameter": .systemBrown
        case "function", "method": .systemBlue
        case "property" where !modifiers.contains("static"): .systemCyan  // data members
        case "variable" where modifiers.contains("readonly"), "enumMember": .systemIndigo  // constants
        case "comment": .tertiaryLabelColor  // inactive #if regions
        default: nil
        }
    }

    // System colors adapt to light and dark mode automatically.
    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .type: .systemTeal
        case .builtin: .systemPurple
        case .function: .systemBlue
        case .string: .systemOrange
        case .number: .systemIndigo
        case .comment: .systemGreen
        case .preprocessor: .systemBrown
        }
    }
}
