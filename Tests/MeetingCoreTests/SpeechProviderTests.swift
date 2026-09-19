import Foundation
import Testing
@testable import MeetingCore

@Test func legacySpeechSettingsRemainAWSAndReviewIsIndependentOfLiveProvider() throws {
    let encoded = try JSONEncoder().encode(AppSettings())
    let legacy = try JSONDecoder().decode(AppSettings.self, from: encoded)
    #expect(legacy.effectiveSpeechProvider == .transcribe)
    var settings = legacy
    settings.speechProvider = .doubao; settings.automaticBatchTranscription = true
    #expect(settings.effectiveDoubao.audioMode == .mixed)
    var meeting = Meeting(title: "语音测试", applicationName: "Teams", bundleID: "teams", microphoneName: "mic", settings: settings)
    try meeting.ingest(.init(sessionID: "s", resultID: "1", source: .mixed, start: 0, end: 1, text: "测试", speakerID: "s:0"))
    meeting.status = .pending
    if case .batchReview = meeting.postRecordingAction {} else { Issue.record("Explicit automatic review must apply to either live provider") }
    #expect(settings.effectiveReviewProvider == .transcribe)
    #expect(meeting.speakers.first?.name == "发言人 A")
    #expect(meeting.transcriptSourceDescription == "豆包 2.0 实时转录")
    settings.speechProvider = .transcribe; meeting.settings = settings
    if case .batchReview = meeting.postRecordingAction {} else { Issue.record("AWS batch behavior changed") }
}

@Test func doubaoLanguageAndPriceValidationRejectsUnsupportedConfiguration() throws {
    var settings = AppSettings(); settings.speechProvider = .doubao
    for language in [RecognitionLanguage.chinese, .english, .mixed] {
        settings.language = language; try settings.validateSpeechConfiguration()
    }
    for language in [RecognitionLanguage.japanese, .englishJapanese, .multilingual] {
        settings.language = language
        #expect(throws: SpeechConfigurationError.self) { try settings.validateSpeechConfiguration() }
    }
    settings.language = .mixed
    var config = settings.effectiveDoubao; config.pricePerHour = .nan; settings.doubao = config
    #expect(throws: SpeechConfigurationError.self) { try settings.validateSpeechConfiguration() }
}

@Test func doubaoUsageCountsTransmittedAudioAndRoundTripsWithoutCredentials() throws {
    var usage = SpeechUsage(); usage.submittedSeconds = 3600
    #expect(abs(usage.estimatedCNY - 0.93) < 0.000001)
    usage.submittedSeconds += 3600
    #expect(abs(usage.estimatedCNY - 1.86) < 0.000001)
    let decoded = try JSONDecoder().decode(SpeechUsage.self, from: JSONEncoder().encode(usage))
    #expect(decoded.submittedSeconds == 7200)
    usage.submittedSeconds = 1
    #expect(usage.costDescription(locale: Locale(identifier: "zh-CN")).hasPrefix("< "))
    var settings = AppSettings(); settings.speechProvider = .doubao; settings.doubao = .init()
    let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).lowercased()
    #expect(!json.contains("apikey") && !json.contains("api_key") && !json.contains("secret"))
}
