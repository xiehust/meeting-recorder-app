import Foundation
import Testing
import MeetingCore
import SmithyIdentity
import CryptoKit
@testable import MeetingCloud

private func aiMeeting() throws -> Meeting {
    var meeting = Meeting(title: "AI test", applicationName: "Teams", bundleID: "com.microsoft.teams2", microphoneName: "Mic", settings: .init())
    try meeting.ingest(.init(sessionID: "session", resultID: "one", source: .application, start: 1, end: 4,
                            text: "建议周五再决定，不是最终承诺。", speakerID: "remote"))
    meeting.status = .pending; meeting.endedAt = Date()
    return meeting
}
private func json(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
private func minimalMinutes(citations: [[String: String]]) -> [String: Any] {
    ["overview": "讨论了后续决定的时间。", "topics": [["text": "时间仍待确定", "citations": citations]],
     "decisions": [], "actions": [], "questions": [], "limitations": []]
}

@Test func requestSendsExplicitMediumAndDisablesStoredResponses() throws {
    let config = try AIModelCatalog.resolve(.init())
    let data = try BedrockResponsesClient.requestBody(instructions: "system", input: "data", configuration: config, maxOutputTokens: 4_096)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["model"] as? String == "openai.gpt-6-astra")
    #expect((object["reasoning"] as? [String: String])?["effort"] == "medium")
    #expect(object["store"] as? Bool == false)
    #expect(object["stream"] as? Bool == false)
}

@Test func standaloneSigningIncludesHostPayloadHashAndSessionTokenWithoutChangingBody() async throws {
    let body = Data("{\"test\":true}".utf8)
    let config = try AIModelCatalog.resolve(.init())
    let identity = AWSCredentialIdentity(accessKey: "AKIDEXAMPLE", secret: "not-a-real-secret", sessionToken: "test-session")
    let request = try await BedrockResponsesClient.signedRequest(body: body, configuration: config, identity: identity)
    #expect(request.httpBody == body)
    #expect(request.url?.absoluteString == "https://bedrock-mantle.us-west-2.api.aws/openai/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Host") == request.url?.host)
    #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") == SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
    #expect(request.value(forHTTPHeaderField: "x-amz-security-token") == "test-session")
    #expect(request.value(forHTTPHeaderField: "Authorization")?.contains(";host;") == true)
}

@Test func invalidModelRegionEffortAndRouteCannotSilentlyFallback() {
    var config = ModelConfiguration(); config.region = "us-east-1"
    #expect(throws: AIError.self) { try AIModelCatalog.resolve(config) }
    config.region = "us-west-2"; config.endpoint = "runtime"
    #expect(throws: AIError.self) { try AIModelCatalog.resolve(config) }
    config.endpoint = "mantle"; config.modelID = "openai.gpt-5.6-luna"
    #expect(throws: AIError.self) { try AIModelCatalog.resolve(config) }
    config.modelID = ""; config.reasoningEffort = "unknown"
    #expect(throws: AIError.self) { try AIModelCatalog.resolve(config) }
}

@Test func locationRestrictionIsIdentifiedWithoutTreatingItAsBadCredentials() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "error": ["message": "Access to OpenAI models is not allowed from unsupported countries, regions, or territories."]
    ])
    #expect(BedrockResponsesClient.isLocationRestricted(data))
    #expect(!BedrockResponsesClient.isLocationRestricted(Data("{\"message\":\"invalid model\"}".utf8)))
}

@Test func semanticAndNumericCorrectionsRemainPendingEvenIfModelClaimsSafe() throws {
    let meeting = try aiMeeting()
    let source = AIInputSnapshot(meeting: meeting)
    let value: [String: Any] = ["changes": [["segment": "S0001", "before": source.segments[0].text,
        "after": "周五最终决定。", "reason": "测试", "requiresConfirmation": false]], "warnings": []]
    let decoded = try AIOutputValidation.correction(json(value), snapshot: source, allowedIDs: ["S0001"])
    #expect(decoded.changes[0].initialDisposition == .pending)
    #expect(meeting.segments[0].originalText == source.segments[0].text)
}

@Test func correctionRejectsProtectedTextUnknownIDsAndOutOfChunkEdits() throws {
    var meeting = try aiMeeting()
    try meeting.edit(segmentID: meeting.segments[0].id, text: "我确认的文本")
    let source = AIInputSnapshot(meeting: meeting)
    let value: [String: Any] = ["changes": [["segment": "S0001", "before": "我确认的文本",
        "after": "覆盖后的文本", "reason": "测试", "requiresConfirmation": true]], "warnings": []]
    #expect(throws: AIError.self) { try AIOutputValidation.correction(json(value), snapshot: source, allowedIDs: ["S0001"]) }
    #expect(throws: AIError.self) { try AIOutputValidation.correction(json(value), snapshot: source, allowedIDs: []) }
}

@Test func inventedCitationAndMisquotedTextAreRejected() throws {
    let source = AIInputSnapshot(meeting: try aiMeeting())
    let missing = minimalMinutes(citations: [["segment": "invented", "quote": "不存在"]])
    #expect(throws: AIError.self) { try AIOutputValidation.minutes(json(missing), snapshot: source) }
    let misquote = minimalMinutes(citations: [["segment": "S0001", "quote": "我们决定周五发布"]])
    #expect(throws: AIError.self) { try AIOutputValidation.minutes(json(misquote), snapshot: source) }
    #expect(throws: AIError.self) { try AIOutputValidation.minutes(json(minimalMinutes(citations: [])), snapshot: source) }
}

@Test func suggestionsAreNotConfirmedAndOwnerDateCannotBeInvented() throws {
    let source = AIInputSnapshot(meeting: try aiMeeting())
    let citations = [["segment": "S0001", "quote": source.segments[0].text]]
    var value = minimalMinutes(citations: citations)
    value["decisions"] = [["text": "已经决定", "citations": citations]]
    value["actions"] = [["task": "后续确认", "owner": "发言人 A", "dueDate": "2026-09-25", "citations": citations]]
    let minutes = try AIOutputValidation.minutes(json(value), snapshot: source)
    #expect(minutes.decisions.isEmpty)
    #expect(minutes.questions.count == 1)
    #expect(minutes.actions[0].owner == nil)
    #expect(minutes.actions[0].dueDate == nil)
    #expect(!minutes.limitations.isEmpty)
}

@Test func truncatedOrRefusedResponsesNeverBecomeSavedMinutes() throws {
    let incomplete = try JSONSerialization.data(withJSONObject: ["status": "incomplete", "output": []])
    #expect(throws: AIError.self) { try BedrockResponsesClient.decode(incomplete, model: "test", endpoint: "test", startedAt: Date()) }
    let refusal = try JSONSerialization.data(withJSONObject: ["status": "completed", "output":
        [["type": "message", "content": [["type": "refusal", "refusal": "no"]]]]])
    #expect(throws: AIError.self) { try BedrockResponsesClient.decode(refusal, model: "test", endpoint: "test", startedAt: Date()) }
}

@Test func chunkingCoversEveryOriginalOnceWhileAllowingContext() throws {
    let source = AIInputSnapshot(meeting: try aiMeeting())
    var large = source
    large.segments = Array(repeating: source.segments[0], count: 450)
    let chunks = AIPrompts.chunks(large, maximumCharacters: 100_000, maximumSegments: 200)
    #expect(chunks.flatMap { Array($0) } == Array(0..<450))
    #expect(chunks.count == 3)
}

private actor FakeAI: BedrockTextGenerating {
    var responses: [String]
    var calls: [ModelConfiguration] = []
    var inputs: [String] = []
    init(_ responses: [String]) { self.responses = responses }
    func generate(instructions: String, input: String, configuration: ModelConfiguration,
                  profile: String, maxOutputTokens: Int) async throws -> AITextResponse {
        calls.append(configuration)
        inputs.append(input)
        guard !responses.isEmpty else { throw AIError.service(503, "test failure") }
        return .init(text: responses.removeFirst(), invocation: .init(responseID: "test", model: configuration.modelID,
            endpoint: "test", startedAt: Date(), durationSeconds: 0, inputTokens: 1, outputTokens: 1))
    }
}

@Test func savedTermsAndBackgroundNotesReachCorrectionBeforeSummaryWithoutBecomingTranscript() async throws {
    var meeting = try aiMeeting()
    let originalSegments = meeting.segments
    meeting.glossary = "QBR：季度业务回顾"
    meeting.note = "术语背景说明，仅作人工补充。"
    meeting.revision += 1
    let minutes = minimalMinutes(citations: [["segment": "S0001", "quote": "建议周五再决定"]])
    let client = FakeAI(["{\"changes\":[],\"warnings\":[]}", try json(minutes)])
    let state = EventStore(meeting)

    try await MeetingAIWorkflow(client: client).run(meeting: meeting, operation: .full) { try await state.apply($0) }
    let inputs = await client.inputs
    #expect(inputs.count == 2)
    let correctionInput = try #require(JSONSerialization.jsonObject(with: Data(inputs[0].utf8)) as? [String: Any])
    let summaryInput = try #require(JSONSerialization.jsonObject(with: Data(inputs[1].utf8)) as? [String: Any])
    #expect(correctionInput["glossary"] as? String == meeting.glossary)
    #expect(correctionInput["userSupplementNotSpoken"] as? String == meeting.note)
    #expect(summaryInput["userSupplementNotSpoken"] as? String == meeting.note)
    let result = await state.meeting
    #expect(result.segments == originalSegments)
    #expect(result.correctionVersions?.last?.input.userNote == meeting.note)
    let version = try #require(result.minuteVersions?.last)
    #expect(version.input.inputRevision == meeting.revision)
    #expect(MeetingExport.minutesBody(version).contains("用户补充（人工备注，非会上原话）"))
    #expect(MeetingExport.minutesBody(version).contains(meeting.note))
}
private actor EventStore {
    var meeting: Meeting
    init(_ meeting: Meeting) { self.meeting = meeting }
    func apply(_ event: AIWorkflowEvent) throws { try meeting.applyAIEvent(event) }
}

@Test func summaryFailurePreservesCorrectionAndSummaryRetryDoesNotCorrectAgain() async throws {
    let meeting = try aiMeeting()
    let state = EventStore(meeting)
    let first = FakeAI(["{\"changes\":[],\"warnings\":[]}"])
    await #expect(throws: AIError.self) {
        try await MeetingAIWorkflow(client: first).run(meeting: meeting, operation: .full) { try await state.apply($0) }
    }
    let afterFailure = await state.meeting
    #expect(afterFailure.correctionVersions?.last?.isComplete == true)
    #expect(afterFailure.minuteVersions == nil)
    let value = minimalMinutes(citations: [["segment": "S0001", "quote": "建议周五再决定"]])
    let retry = FakeAI([try json(value)])
    try await MeetingAIWorkflow(client: retry).run(meeting: afterFailure, operation: .summary) { try await state.apply($0) }
    let finished = await state.meeting
    #expect(await retry.calls.count == 1)
    #expect(finished.correctionVersions?.count == 1)
    #expect(finished.minuteVersions?.count == 1)
    #expect(finished.segments == meeting.segments)
    #expect(finished.status == .completed)
}

@Test func partialCorrectionRetryResumesOnlyUnfinishedChunks() async throws {
    var meeting = try aiMeeting()
    for i in 0..<205 {
        try meeting.ingest(.init(sessionID: "s", resultID: "\(i)", source: .microphone,
            start: Double(i + 10), end: Double(i + 11), text: "继续讨论", speakerID: "me"))
    }
    // The unused summary configuration must not block a correction-only operation.
    meeting.settings.summary.region = "invalid"
    let state = EventStore(meeting)
    let initial = FakeAI(["{\"changes\":[],\"warnings\":[]}"])
    await #expect(throws: AIError.self) {
        try await MeetingAIWorkflow(client: initial).run(meeting: meeting, operation: .correction) { try await state.apply($0) }
    }
    let partial = await state.meeting
    #expect(partial.correctionVersions?.last?.completedChunks == [0])
    #expect(partial.correctionVersions?.last?.chunkCount == 2)
    let retry = FakeAI(["{\"changes\":[],\"warnings\":[]}"])
    try await MeetingAIWorkflow(client: retry).run(meeting: partial, operation: .correction) { try await state.apply($0) }
    let completed = await state.meeting
    #expect(await retry.calls.count == 1)
    #expect(completed.correctionVersions?.count == 1)
    #expect(completed.correctionVersions?.last?.isComplete == true)
    #expect(completed.correctionVersions?.last?.calls.count == 2)
}

@Test func failureBeforeFirstResultStillKeepsInputAndChangingInputCreatesNewVersion() async throws {
    let meeting = try aiMeeting()
    let state = EventStore(meeting)
    await #expect(throws: AIError.self) {
        try await MeetingAIWorkflow(client: FakeAI([])).run(meeting: meeting, operation: .correction) { try await state.apply($0) }
    }
    var changed = await state.meeting
    #expect(changed.correctionVersions?.last?.input.segments.first?.text == meeting.segments[0].originalText)
    #expect(changed.aiTask?.configuration?.reasoningEffort == "medium")
    try changed.edit(segmentID: changed.segments[0].id, text: "人工确认的文本")
    let next = EventStore(changed)
    try await MeetingAIWorkflow(client: FakeAI(["{\"changes\":[],\"warnings\":[]}"])).run(meeting: changed, operation: .correction) { try await next.apply($0) }
    let result = await next.meeting
    #expect(result.correctionVersions?.count == 2)
    #expect(result.correctionVersions?.last?.input.segments[0].humanProtected == true)
    #expect(result.correctionVersions?.first?.input.segments[0].text == meeting.segments[0].originalText)
}

@Test func remoteFirstPersonDoesNotAssignAnActionToLocalMe() throws {
    var meeting = try aiMeeting()
    try meeting.edit(segmentID: meeting.segments[0].id, text: "我会整理文档")
    let source = AIInputSnapshot(meeting: meeting)
    let citations = [["segment": "S0001", "quote": "我会整理文档"]]
    var value = minimalMinutes(citations: citations)
    value["actions"] = [["task": "整理文档", "owner": "我", "dueDate": NSNull(), "citations": citations]]
    let minutes = try AIOutputValidation.minutes(json(value), snapshot: source)
    #expect(minutes.actions[0].owner == nil)
}
