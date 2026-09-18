import Foundation
import Testing
import AWSTranscribeStreaming
import MeetingCore
@testable import MeetingCloud

private func vocabulary() -> VocabularySnapshot {
    .init(scope: .init(profile: "default", region: "us-west-2"),
          bindings: VocabularyLanguage.allCases.map { .init(language: $0, name: "fixture-\($0.rawValue)", digest: "test", entryCount: 1) })
}

@Test func englishJapaneseStreamingAndBatchExcludeChineseVocabulary() throws {
    for source in AudioSource.allCases {
        let input = TranscriptionStream.makeInput(language: .englishJapanese, source: source, sessionID: "en-ja", vocabulary: vocabulary())
        #expect(input.identifyMultipleLanguages == true)
        #expect(input.languageCode == nil)
        #expect(input.languageOptions == "en-US,ja-JP")
        #expect(Set(input.vocabularyNames!.split(separator: ",")) == ["fixture-en-US", "fixture-ja-JP"])
        #expect(input.vocabularyName == nil)
        #expect(input.showSpeakerLabel == (source == .application))
        var settings = AppSettings()
        settings.language = .englishJapanese; settings.transcriptionVocabulary = vocabulary()
        var meeting = Meeting(title: "Fixture", applicationName: "", bundleID: "", microphoneName: "", settings: settings)
        meeting.status = .pending
        meeting.audioChunks = [.init(source: source, relativePath: "fixture.caf", start: 0)]
        let version = try BatchTranscriptionVersion(meeting: meeting, settings: settings, bucket: "fixture-bucket")
        let batch = AWSBatchTranscriptionRemote.input(version.jobs[0], version: version)
        #expect(batch.identifyMultipleLanguages == true)
        #expect(batch.languageCode == nil)
        #expect(batch.languageOptions?.map(\.rawValue) == ["en-US", "ja-JP"])
        #expect(Set(batch.languageIdSettings!.keys) == ["en-US", "ja-JP"])
        #expect(batch.languageIdSettings?["ja-JP"]?.vocabularyName == "fixture-ja-JP")
        #expect(batch.languageIdSettings?["en-US"]?.vocabularyName == "fixture-en-US")
        #expect(batch.settings?.vocabularyName == nil)
        #expect(batch.settings?.showSpeakerLabels == (source == .application))
    }
}

@Test func japaneseStreamingAndThreeLanguageRequestsUseCorrectVocabularyFields() {
    for source in AudioSource.allCases {
        let fixed = TranscriptionStream.makeInput(language: .japanese, source: source, sessionID: "ja", vocabulary: vocabulary())
        #expect(fixed.languageCode == .jaJp)
        #expect(fixed.languageOptions == nil)
        #expect(fixed.identifyMultipleLanguages != true)
        #expect(fixed.vocabularyName == "fixture-ja-JP")
        #expect(fixed.vocabularyNames == nil)
        let mixed = TranscriptionStream.makeInput(language: .multilingual, source: source, sessionID: "all", vocabulary: vocabulary())
        #expect(mixed.languageCode == nil)
        #expect(mixed.identifyMultipleLanguages == true)
        #expect(mixed.languageOptions == "zh-CN,en-US,ja-JP")
        #expect(Set(mixed.vocabularyNames!.split(separator: ",")) == ["fixture-zh-CN", "fixture-en-US", "fixture-ja-JP"])
        #expect(mixed.vocabularyName == nil)
        #expect(mixed.showSpeakerLabel == (source == .application))
        let legacy = TranscriptionStream.makeInput(language: .mixed, source: source, sessionID: "old", vocabulary: vocabulary())
        #expect(legacy.languageOptions == "zh-CN,en-US")
        #expect(legacy.vocabularyNames?.contains("ja-JP") == false)
    }
}

@Test func japaneseBatchAndThreeLanguageRequestsKeepLanguageSpecificVocabularies() throws {
    var meeting = Meeting(title: "Fixture", applicationName: "", bundleID: "", microphoneName: "", settings: .init())
    meeting.status = .pending
    meeting.audioChunks = [.init(source: .application, relativePath: "fixture.caf", start: 0)]
    var settings = AppSettings(); settings.transcriptionVocabulary = vocabulary()
    for language in [RecognitionLanguage.japanese, .multilingual, .mixed] {
        settings.language = language
        let version = try BatchTranscriptionVersion(meeting: meeting, settings: settings, bucket: "fixture-bucket")
        let input = AWSBatchTranscriptionRemote.input(version.jobs[0], version: version)
        if language == .japanese {
            #expect(input.languageCode == .jaJp)
            #expect(input.settings?.vocabularyName == "fixture-ja-JP")
            #expect(input.identifyMultipleLanguages != true)
            #expect(input.languageIdSettings == nil)
        } else {
            #expect(input.languageCode == nil)
            #expect(input.languageOptions?.map(\.rawValue) == (language == .mixed ? ["zh-CN", "en-US"] : ["zh-CN", "en-US", "ja-JP"]))
            #expect(input.languageIdSettings?["ja-JP"]?.vocabularyName == (language == .mixed ? nil : "fixture-ja-JP"))
            #expect(input.settings?.vocabularyName == nil)
        }
    }
}

@Test func japaneseKanaJoinsWithoutSpacesInBothTranscriptionParsers() throws {
    let words = ["おはよう", "ござい", "ます", "。", "カタカナ", "テスト", "です", "。"]
    let items = words.enumerated().map { index, token in
        TranscribeStreamingClientTypes.Item(content: token, endTime: Double(index) + 0.4,
            speaker: index < 4 ? "spk_0" : "spk_1", startTime: Double(index),
            type: token == "。" ? .punctuation : .pronunciation)
    }
    let alternative = TranscribeStreamingClientTypes.Alternative(items: items, transcript: "おはようございます。カタカナテストです。")
    let result = TranscribeStreamingClientTypes.Result(alternatives: [alternative], endTime: 8, resultId: "1", startTime: 0)
    let live = TranscriptionStream.segments(result, alternative: alternative, source: .application, sessionID: "ja", offset: 0)
    #expect(live.map(\.originalText) == ["おはようございます。", "カタカナテストです。"])
    let job = BatchTranscriptionJob(chunk: .init(source: .application, relativePath: "", start: 0), meetingID: UUID(), versionID: UUID())
    let payload: [String: Any] = ["jobName": job.name, "status": "COMPLETED", "results": [
        "transcripts": [["transcript": alternative.transcript!]],
        "items": words.enumerated().map { index, token -> [String: Any] in
            ["type": token == "。" ? "punctuation" : "pronunciation",
             "start_time": "\(index)", "end_time": "\(Double(index) + 0.4)",
             "speaker_label": index < 4 ? "spk_0" : "spk_1", "alternatives": [["content": token]]]
        }]]
    let batch = try BatchTranscriptParser.parse(JSONSerialization.data(withJSONObject: payload), job: job)
    #expect(batch.map(\.originalText) == live.map(\.originalText))
    #expect(batch[0].originalSpeakerID != batch[1].originalSpeakerID)
}

@Test func japaneseSummaryPromptSectionsCitationsAndExportUseSavedOutputLanguage() throws {
    var settings = AppSettings(); settings.summaryLanguage = "日本語"; settings.language = .japanese
    var meeting = Meeting(title: "研修", applicationName: "", bundleID: "", microphoneName: "", settings: settings)
    try meeting.ingest(.init(sessionID: "ja", resultID: "1", source: .application, start: 0, end: 2,
                            text: "キューで非同期処理を実装します。", speakerID: "ja:0"))
    let input = AIInputSnapshot(meeting: meeting)
    let template = SummaryTemplate.training
    let prompt = try AIPrompts.summaryInstructions(language: "日本語", template: template)
    #expect(prompt.contains("输出语言：日文"))
    #expect(prompt.contains("quote 永远保持原文语言"))
    #expect(prompt.contains("研修の目標と知識体系"))
    let sections: [[String: Any]] = template.sections.enumerated().map { index, section in
        if section.kind == .actions { return ["id": section.id, "actions": []] }
        return ["id": section.id, "items": index == 0
            ? [["text": "非同期処理の実装を学びます。", "citations": [["segment": "S0001", "quote": "キューで非同期処理"]]]] : []]
    }
    let data = try JSONSerialization.data(withJSONObject: ["overview": "キューを使う研修です。", "sections": sections, "limitations": []])
    let minutes = try AIOutputValidation.minutes(String(decoding: data, as: UTF8.self), snapshot: input, template: template, language: "日本語")
    #expect(minutes.sections?.first?.title == "研修の目標と知識体系")
    let version = MinutesVersion(input: input, correctionVersionID: nil, configuration: .init(), profile: "default",
                                 minutes: minutes, invocation: nil, language: "日本語", summaryTemplate: template)
    let markdown = MeetingExport.minutes(version, format: .markdown)
    #expect(markdown.contains("## 研修の概要"))
    #expect(markdown.contains("原文の根拠"))
    #expect(markdown.contains("テンプレート：研修記録"))
    #expect(markdown.contains("[S0001](#source-s0001)"))
    #expect(markdown.contains("キューで非同期処理を実装します。"))
    #expect(!markdown.contains("模型："))
    #expect(!MeetingExport.minutes(version, format: .text).contains("#source-"))
}

@Test func japaneseUncertainDecisionsStayOpenQuestions() throws {
    var meeting = Meeting(title: "予定", applicationName: "", bundleID: "", microphoneName: "", settings: .init())
    try meeting.ingest(.init(sessionID: "ja", resultID: "1", source: .application, start: 0, end: 2,
                            text: "来週開始するかもしれません。", speakerID: "ja:0"))
    let output = #"{"overview":"予定を確認しました。","topics":[],"decisions":[{"text":"来週開始します。","citations":[{"segment":"S0001","quote":"来週開始するかもしれません。"}]}],"actions":[],"questions":[],"limitations":[]}"#
    let result = try AIOutputValidation.minutes(output, snapshot: .init(meeting: meeting), language: "日本語")
    #expect(result.decisions.isEmpty)
    #expect(result.questions.first?.text.hasPrefix("決定の根拠") == true)
    #expect(result.limitations.first?.contains("要確認") == true)
}
