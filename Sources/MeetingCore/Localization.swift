import Foundation

/// Interface language is an application preference, never a meeting/content setting.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system, chinese = "zh-Hans", english = "en", japanese = "ja"

    public static let preferenceKey = "interfaceLanguage"
    public var title: String {
        switch self {
        case .system: L10n.tr("跟随系统")
        case .chinese: "简体中文"
        case .english: "English"
        case .japanese: "日本語"
        }
    }
    public func title(locale: Locale) -> String {
        self == .system ? L10n.tr("跟随系统", locale: locale) : title
    }
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            switch identifier.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first {
            case "zh": return .chinese
            case "en": return .english
            case "ja": return .japanese
            default: continue
            }
        }
        return .english
    }
}

/// Interpolation stays separate from translation keys. User text is never translated or interpreted as a format.
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let key: String
    public let arguments: [String]
    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount)
        }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"; arguments.append(String(describing: value))
        }
    }
}

public enum L10n {
    public static var selection: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "") ?? .system
    }
    public static var language: AppLanguage { selection.resolved() }
    public static var locale: Locale { Locale(identifier: language.rawValue) }

    static let catalog: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "Localization", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            assertionFailure("Localization catalog missing or invalid")
            return [:]
        }
        return values
    }()
    private static let placeholder = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)

    public static func tr(_ message: LocalizedMessage, language: AppLanguage? = nil) -> String {
        render(text(message.key, language: language), arguments: message.arguments)
    }
    public static func tr(_ message: LocalizedMessage, locale: Locale) -> String {
        tr(message, language: AppLanguage.system.resolved(preferredLanguages: [locale.identifier]))
    }
    public static func text(_ key: String, locale: Locale) -> String {
        text(key, language: AppLanguage.system.resolved(preferredLanguages: [locale.identifier]))
    }
    public static func message(_ value: String, locale: Locale) -> String {
        message(value, language: AppLanguage.system.resolved(preferredLanguages: [locale.identifier]))
    }
    /// Exact lookup for application-owned labels. Do not pass transcript text, names, or user templates.
    public static func text(_ key: String, language: AppLanguage? = nil) -> String {
        let target = (language ?? self.language).resolved()
        return target == .chinese ? key : catalog[key]?[target.rawValue] ?? key
    }
    private static func render(_ format: String, arguments: [String]) -> String {
        let source = format as NSString
        var output = "", cursor = 0
        for match in placeholder.matches(in: format, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let index = Int(source.substring(with: match.range(at: 1)))!
            output += arguments.indices.contains(index) ? arguments[index] : source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        return output + source.substring(from: cursor)
    }

    // Historical diagnostics were persisted as Chinese strings. Translate only at diagnostic display sites,
    // keeping stored messages and all meeting data unchanged. Most-specific patterns take precedence.
    private static let diagnosticPatterns: [(String, NSRegularExpression)] = catalog.keys
        .filter { $0.contains("{0}") && $0.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count >= 1 }
        .sorted { lhs, rhs in lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count }
        .compactMap { key in
            let source = key as NSString
            var pattern = "^", cursor = 0
            for match in placeholder.matches(in: key, range: NSRange(location: 0, length: source.length)) {
                pattern += NSRegularExpression.escapedPattern(for: source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                pattern += "([\\s\\S]*?)"; cursor = NSMaxRange(match.range)
            }
            pattern += NSRegularExpression.escapedPattern(for: source.substring(from: cursor)) + "$"
            return (try? NSRegularExpression(pattern: pattern)).map { (key, $0) }
        }
    private static let diagnosticPrefixes = catalog.keys
        .filter { !$0.contains("{") && $0.hasSuffix("。") }
        .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }

    public static func message(_ value: String, language: AppLanguage? = nil) -> String {
        diagnostic(value, language: (language ?? self.language).resolved(), depth: 0)
    }
    private static func diagnostic(_ value: String, language: AppLanguage, depth: Int) -> String {
        guard language != .chinese, depth < 4 else { return value }
        if let translated = catalog[value]?[language.rawValue] { return translated }
        let range = NSRange(value.startIndex..., in: value)
        for (key, regex) in diagnosticPatterns {
            guard let match = regex.firstMatch(in: value, range: range) else { continue }
            let arguments = (1..<match.numberOfRanges).map { index in
                diagnostic((value as NSString).substring(with: match.range(at: index)), language: language, depth: depth + 1)
            }
            return render(text(key, language: language), arguments: arguments)
        }
        if value.contains("\n") {
            return value.components(separatedBy: "\n").map { diagnostic($0, language: language, depth: depth + 1) }.joined(separator: "\n")
        }
        if let prefix = diagnosticPrefixes.first(where: value.hasPrefix) {
            return text(prefix, language: language)
                + diagnostic(String(value.dropFirst(prefix.count)), language: language, depth: depth + 1)
        }
        return value
    }
}
