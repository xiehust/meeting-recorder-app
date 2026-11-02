import AppKit
import SwiftUI
import MarkdownUI
import Highlightr

struct ChatCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    let dark: Bool
    func highlightCode(_ code: String, language: String?) -> Text {
        let highlighted = ChatSyntaxHighlighting.shared.highlight(code, language: language, dark: dark)
        return Text(ChatSyntaxHighlighting.displayText(highlighted))
    }
}

/// Highlightr owns a JavaScriptCore context. Serialize access and bound both work and cache size.
final class ChatSyntaxHighlighting: @unchecked Sendable {
    static let shared = ChatSyntaxHighlighting()
    static let maximumHighlightedBytes = 64_000
    private let lock = NSLock()
    private var engine: Highlightr?
    private var languages: Set<String> = []
    private var theme: String?
    private let cache = NSCache<NSString, NSAttributedString>()

    init() {
        cache.countLimit = 80
        cache.totalCostLimit = 4_000_000
    }

    static func languageName(_ fence: String?) -> String? {
        guard let name = fence?.split(whereSeparator: \.isWhitespace).first?.lowercased(), !name.isEmpty else { return nil }
        let aliases = ["js": "javascript", "jsx": "javascript", "ts": "typescript", "tsx": "typescript",
                       "py": "python", "sh": "bash", "shell": "bash", "zsh": "bash", "yml": "yaml",
                       "html": "xml", "htm": "xml", "c++": "cpp", "c#": "csharp", "objc": "objectivec",
                       "text": "plaintext", "txt": "plaintext"]
        return aliases[name] ?? name
    }

    /// AppKit color/font attributes do not automatically become SwiftUI attributes on macOS.
    /// Translate the runs explicitly while retaining their literal text.
    static func displayText(_ source: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            var run = AttributedString((source.string as NSString).substring(with: range))
            if let color = attributes[.foregroundColor] as? NSColor { run.foregroundColor = Color(nsColor: color) }
            var font = Font.system(size: 13, design: .monospaced)
            if let nativeFont = attributes[.font] as? NSFont {
                if nativeFont.fontDescriptor.symbolicTraits.contains(.bold) { font = font.bold() }
                if nativeFont.fontDescriptor.symbolicTraits.contains(.italic) { font = font.italic() }
            }
            run.font = font
            result.append(run)
        }
        return result
    }

    func highlight(_ code: String, language: String?, dark: Bool) -> NSAttributedString {
        let plain = NSAttributedString(string: code, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        // Unknown/unlabelled or very large blocks remain intact without costly language detection.
        guard !code.isEmpty, code.utf8.count <= Self.maximumHighlightedBytes,
              let language = Self.languageName(language), language != "plaintext" else { return plain }
        lock.lock()
        defer { lock.unlock() }
        let requestedTheme = dark ? "atom-one-dark" : "atom-one-light"
        let key = "\(requestedTheme)\u{0}\(language)\u{0}\(code)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if engine == nil {
            engine = Highlightr()
            engine?.ignoreIllegals = true
            languages = Set(engine?.supportedLanguages() ?? [])
        }
        guard languages.contains(language), let engine else { return plain }
        if theme != requestedTheme {
            guard engine.setTheme(to: requestedTheme) else { return plain }
            engine.theme.setCodeFont(NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
            theme = requestedTheme
        }
        guard let result = engine.highlight(code, as: language, fastRender: true),
              result.string.utf8.elementsEqual(code.utf8) else { return plain }
        let immutable = NSAttributedString(attributedString: result)
        cache.setObject(immutable, forKey: key, cost: code.utf8.count * 8)
        return immutable
    }
}
