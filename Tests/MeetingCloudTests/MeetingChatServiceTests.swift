import Foundation
import Testing
import MeetingCore
@testable import MeetingCloud

@Test func importedMixedAudioRequestsSpeakerDiarization() throws {
    for source in AudioSource.allCases {
        var meeting = Meeting(title: "Imported", applicationName: "", bundleID: "", microphoneName: "", settings: .init())
        meeting.status = .pending
        meeting.audioChunks = [.init(source: source, relativePath: "imported.caf", start: 0)]
        let version = try BatchTranscriptionVersion(meeting: meeting, settings: meeting.settings, bucket: "test-bucket")
        let input = AWSBatchTranscriptionRemote.input(version.jobs[0], version: version)
        #expect(input.settings?.showSpeakerLabels == (source != .microphone))
        #expect(input.settings?.maxSpeakerLabels == (source != .microphone ? 10 : nil))
    }
}

private actor ChatClient: AITextGenerating {
    let output: String
    var inputs: [String] = []
    init(_ output: String) { self.output = output }
    func generate(instructions: String, input: String, configuration: ModelConfiguration, profile: String, maxOutputTokens: Int) async throws -> AITextResponse {
        inputs.append(input)
        #expect(maxOutputTokens == 8_192)
        return .init(text: output, invocation: .init(responseID: "test", model: "fixture", endpoint: "test", startedAt: Date(), durationSeconds: 0, inputTokens: 1, outputTokens: 1))
    }
}

private func chatContext(text: String = "周五再决定，尚未承诺。") throws -> MeetingChatContext {
    var meeting = Meeting(title: "Fixture", applicationName: "Test", bundleID: "", microphoneName: "", settings: .init())
    try meeting.ingest(.init(sessionID: "test", resultID: "1", source: .mixed, start: 0, end: 3, text: text, speakerID: "speaker"))
    return MeetingChatContext(meeting: meeting, scope: .all)
}

@Test func chatValidatesEvidenceAndSendsOnlyCompletedRecentHistory() async throws {
    let context = try chatContext()
    var history: [MeetingChatTurn] = []
    for index in 0..<15 {
        var turn = MeetingChatTurn(question: "question-\(index)", context: context)
        turn.state = .completed; turn.answer = "answer-\(index)"; history.append(turn)
    }
    history.append(.init(question: "unfinished", context: context))
    let client = ChatClient(#"{"answer":"尚未承诺 [O1]","insufficientEvidence":false,"citations":[{"sourceID":"O1","quote":"尚未承诺"}]}"#)
    let answer = try await MeetingChatService(client: client).answer(question: "结论呢？", context: context, history: history, configuration: .init(), profile: "fixture", language: "中文")
    #expect(answer.citations.first?.quote == "尚未承诺")
    let input = try #require(await client.inputs.first)
    let object = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
    let sentHistory = try #require(object["history"] as? [[String: Any]])
    #expect(sentHistory.count == 12)
    #expect(sentHistory[0]["question"] as? String == "question-3")
    #expect(!input.contains("unfinished"))
}

@Test(arguments: [
    #"{"answer":"假引文 [O1]","insufficientEvidence":false,"citations":[{"sourceID":"O1","quote":"已经决定上线"}]}"#,
    #"{"answer":"不存在的来源 [O99]","insufficientEvidence":false,"citations":[{"sourceID":"O99","quote":"尚未承诺"}]}"#,
    #"{"answer":"无依据","insufficientEvidence":false,"citations":[]}"#,
    #"{"answer":"错误的内文引用 [O99]","insufficientEvidence":false,"citations":[{"sourceID":"O1","quote":"尚未承诺"}]}"#,
    "not JSON"
]) func chatRejectsInvalidEvidenceAndFormat(output: String) async throws {
    let context = try chatContext(), client = ChatClient(output)
    await #expect(throws: AIError.self) {
        try await MeetingChatService(client: client).answer(question: "问题", context: context, history: [], configuration: .init(), profile: "fixture", language: "中文")
    }
    #expect(await client.inputs.count == 1) // Never retry inference automatically.
}

@Test func chatInsufficientEvidenceUsesExplicitFallback() async throws {
    let client = ChatClient(#"{"answer":"猜测内容","insufficientEvidence":true,"citations":[]}"#)
    let answer = try await MeetingChatService(client: client).answer(question: "收入是多少？", context: chatContext(), history: [], configuration: .init(), profile: "fixture", language: "中文")
    #expect(answer.text == "所选会议资料中没有足够依据回答这个问题。")
    #expect(answer.citations.isEmpty)
}

@Test func chatRejectsOversizedAndEmptyRequestsBeforeCallingModel() async throws {
    let client = ChatClient("not used")
    let large = try chatContext(text: String(repeating: "文", count: 220_000))
    let empty = MeetingChatContext(meeting: Meeting(title: "Empty", applicationName: "", bundleID: "", microphoneName: "", settings: .init()), scope: .all)
    for context in [large, empty] {
        await #expect(throws: AIError.self) {
            try await MeetingChatService(client: client).answer(question: "问题", context: context, history: [], configuration: .init(), profile: "fixture", language: "中文")
        }
    }
    #expect(await client.inputs.isEmpty)
}

@Test func chatCancellationDoesNotCallModel() async throws {
    let client = ChatClient("not used"), context = try chatContext()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await MeetingChatService(client: client).answer(question: "问题", context: context, history: [], configuration: .init(), profile: "fixture", language: "中文")
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await client.inputs.isEmpty)
}
