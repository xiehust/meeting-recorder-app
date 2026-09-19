import Foundation

public enum SpeechProvider: String, Codable, CaseIterable, Sendable {
    case transcribe, doubao
    public var title: String { self == .transcribe ? "AWS Transcribe" : "豆包流式语音识别 2.0" }
}

public enum DoubaoAudioMode: String, Codable, CaseIterable, Sendable {
    case mixed, separate
    public var title: String { self == .mixed ? "单路混音（省费用）" : "双路独立识别" }
}

/// No credentials: this value is safe to freeze in meeting/version snapshots.
public struct DoubaoSettings: Codable, Equatable, Sendable {
    public var audioMode: DoubaoAudioMode = .mixed
    public var pricePerHour: Double = 0.93
    public var hotwords: [String] = []
    public init() {}
}

public struct SpeechUsage: Codable, Sendable {
    public var submittedSeconds: Double = 0
    public let pricePerHour: Double
    public var estimatedCNY: Double { submittedSeconds / 3600 * pricePerHour }
    public func costDescription(locale: Locale) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: "CNY", locale: locale)
        return estimatedCNY > 0 && estimatedCNY < 0.01
            ? "< " + 0.01.formatted(style) : estimatedCNY.formatted(style)
    }
    public init(pricePerHour: Double = 0.93) { self.pricePerHour = pricePerHour }
}

public enum SpeechConfigurationError: LocalizedError {
    case unsupportedLanguage, missingKey, invalidKey, keychain(Int32), invalidPrice
    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage: "豆包实时二遍识别支持中英模式；日语或英日混合请使用 AWS Transcribe。"
        case .missingKey: "请先在设置中保存豆包 API Key。"
        case .invalidKey: "API Key 不能为空或包含空白字符。"
        case .keychain(let code): "无法访问豆包 API Key 的钥匙串条目（\(code)）。"
        case .invalidPrice: "豆包估算单价必须是有效的非负数。"
        }
    }
}

public extension AppSettings {
    func validateSpeechConfiguration() throws {
        guard effectiveSpeechProvider == .doubao else { return }
        guard supportedRecognitionLanguages.contains(language) else { throw SpeechConfigurationError.unsupportedLanguage }
        guard effectiveDoubao.pricePerHour.isFinite, effectiveDoubao.pricePerHour >= 0 else { throw SpeechConfigurationError.invalidPrice }
    }
}
