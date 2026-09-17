import Testing
import AWSTranscribeStreaming
import MeetingCore
@testable import MeetingCloud

@Test func mixedLanguageAndDiarizationAreExplicitAndIndependent() {
    let remote = TranscriptionStream.makeInput(language: .mixed, source: .application, sessionID: "remote")
    #expect(remote.identifyMultipleLanguages == true)
    #expect(remote.languageCode == nil)
    #expect(remote.identifyLanguage != true)
    #expect(remote.languageOptions == "zh-CN,en-US")
    #expect(remote.showSpeakerLabel == true)
    #expect(remote.mediaSampleRateHertz == 16_000)
    #expect(remote.mediaEncoding == .pcm)
    #expect(remote.numberOfChannels == nil)
    let microphone = TranscriptionStream.makeInput(language: .mixed, source: .microphone, sessionID: "mic")
    #expect(microphone.showSpeakerLabel == false)
    #expect(microphone.sessionId != remote.sessionId)
}

@Test func fixedLanguagesNeverEnableAutomaticIdentification() {
    let chinese = TranscriptionStream.makeInput(language: .chinese, source: .application, sessionID: "a")
    let english = TranscriptionStream.makeInput(language: .english, source: .application, sessionID: "b")
    #expect(chinese.languageCode == .zhCn)
    #expect(english.languageCode == .enUs)
    #expect(chinese.identifyMultipleLanguages != true)
    #expect(english.languageOptions == nil)
}

@Test func multipleSpeakersWithinOneAWSResultGetSeparateStableSegments() {
    let alternative = TranscribeStreamingClientTypes.Alternative(items: [
        .init(content: "Hello", endTime: 2, speaker: "spk_0", startTime: 1, type: .pronunciation),
        .init(content: ".", type: .punctuation),
        .init(content: "你好", endTime: 4, speaker: "spk_1", startTime: 3, type: .pronunciation),
        .init(content: "。", type: .punctuation)
    ], transcript: "Hello. 你好。")
    let result = TranscribeStreamingClientTypes.Result(alternatives: [alternative], endTime: 4, resultId: "r", startTime: 1)
    let values = TranscriptionStream.segments(result, alternative: alternative, source: .application, sessionID: "s", offset: 60)
    #expect(values.count == 2)
    #expect(values[0].originalText == "Hello.")
    #expect(values[1].originalText == "你好。")
    #expect(values[0].start == 61)
    #expect(values[0].end == 62)
    #expect(values[1].start == 63)
    #expect(values[1].end == 64)
    #expect(values[0].originalSpeakerID == "s:spk_0")
    #expect(values[1].originalSpeakerID == "s:spk_1")
    #expect(values[0].serviceTranscript == "Hello. 你好。")
    let replay = TranscriptionStream.segments(result, alternative: alternative, source: .application, sessionID: "s", offset: 60)
    #expect(replay == values)
}

@Test func microphoneAlwaysStartsWithMeLabelAndKeepsServiceText() {
    let alternative = TranscribeStreamingClientTypes.Alternative(transcript: "I might do it.")
    let result = TranscribeStreamingClientTypes.Result(alternatives: [alternative], endTime: 2, resultId: "r", startTime: 0)
    let values = TranscriptionStream.segments(result, alternative: alternative, source: .microphone, sessionID: "s", offset: 20)
    #expect(values.count == 1)
    #expect(values[0].originalSpeakerID == "me")
    #expect(values[0].originalText == "I might do it.")
    #expect(values[0].start == 20)
}
