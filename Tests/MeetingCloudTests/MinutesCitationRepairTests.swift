import Foundation
import Testing
import MeetingCore
@testable import MeetingCloud

private func repairMeeting() throws -> Meeting {
    var meeting = Meeting(title: "引用修复测试", applicationName: "Teams", bundleID: "", microphoneName: "", settings: .init())
    for (index, text) in ["建议周五再决定，不是最终承诺。", "小林你整理一下，截止下周五。"].enumerated() {
        try meeting.ingest(.init(sessionID: "fixture", resultID: "\(index)", source: .application,
            start: Double(index), end: Double(index + 1), text: text, speakerID: "remote"))
    }
    meeting.status = .pending; meeting.endedAt = Date()
    return meeting
}

private func repairDraft(template: SummaryTemplate = .interview) throws -> String {
    let sections: [[String: Any]] = template.sections.enumerated().map { index, section in
        if section.kind == .actions {
            return ["id": section.id, "actions": [["task": "整理材料", "owner": "小林", "dueDate": "下周五",
                "citations": [["segment": "missing", "quote": "小林你整理一下"]]]]]
        }
        return ["id": section.id, "items": index == 0 ? [["heading": "讨论时间", "text": "时间仍待确定",
            "citations": [["segment": "S0001", "quote": "建议周五再决定"],
                          ["segment": "S0001", "quote": "周五已确认"]]]] : []]
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: ["overview": "讨论后续安排。", "sections": sections,
        "limitations": []]), as: UTF8.self)
}

private func repairs(_ issues: [MinutesCitationRepair.Issue], valid: Bool = true) throws -> String {
    let patches = issues.map { issue in
        ["path": issue.path, "segment": valid ? (issue.collection == "actions" ? "S0002" : "S0001") : "invented",
         "quote": issue.collection == "actions" ? "小林你整理一下，截止下周五。" : "建议周五再决定"]
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: ["repairs": patches]), as: UTF8.self)
}

private actor RepairClient: AITextGenerating {
    var replies: [String]
    var inputs: [String] = []
    var configurations: [ModelConfiguration] = []
    init(_ replies: [String]) { self.replies = replies }
    func generate(instructions: String, input: String, configuration: ModelConfiguration,
                  profile: String, maxOutputTokens: Int) async throws -> AITextResponse {
        inputs.append(input); configurations.append(configuration)
        guard !replies.isEmpty else { throw AIError.service(503, "fixture failure") }
        return .init(text: replies.removeFirst(), invocation: .init(responseID: "call-\(inputs.count)", model: configuration.modelID,
            endpoint: configuration.endpoint, startedAt: Date(), durationSeconds: 0, inputTokens: 1, outputTokens: 1))
    }
}

@Test func citationRepairChangesOnlyRejectedEvidenceAndKeepsTemplateBody() throws {
    let source = AIInputSnapshot(meeting: try repairMeeting())
    let draft = try repairDraft()
    let repair = try MinutesCitationRepair(draft: "```json\n\(draft)\n```", snapshot: source)
    #expect(repair.issues.count == 2)
    let patched = try repair.applying(repairs(repair.issues), snapshot: source)
    let minutes = try AIOutputValidation.minutes(patched, snapshot: source, template: .interview)
    #expect(minutes.overview == "讨论后续安排。")
    #expect(minutes.topics[0].heading == "讨论时间")
    #expect(minutes.topics[0].text == "时间仍待确定")
    #expect(minutes.topics[0].citations.map(\.quote) == ["建议周五再决定", "建议周五再决定"])
    #expect(minutes.actions[0].owner == "小林")
    #expect(minutes.actions[0].dueDate == "下周五")
    #expect(minutes.sections?.map(\.id) == SummaryTemplate.interview.sections.map(\.id))
}

@Test func repairRejectsInventedQuotesMissingDuplicateOrExtraPaths() throws {
    let source = AIInputSnapshot(meeting: try repairMeeting())
    let repair = try MinutesCitationRepair(draft: repairDraft(), snapshot: source)
    #expect(throws: AIError.self) { try repair.applying(repairs(repair.issues, valid: false), snapshot: source) }
    #expect(throws: AIError.self) { try repair.applying(repairs(Array(repair.issues.prefix(1))), snapshot: source) }
    #expect(throws: AIError.self) { try repair.applying(repairs([repair.issues[0], repair.issues[0]]), snapshot: source) }
    #expect(throws: AIError.self) { try repair.applying(repairs(repair.issues + [repair.issues[0]]), snapshot: source) }
    let wrong = try repairs(repair.issues).replacingOccurrences(of: "建议周五再决定", with: "已决定周五发布")
    #expect(throws: AIError.self) { try repair.applying(wrong, snapshot: source) }
}

@Test func summaryRepairsAllBadCitationsOnceUsingFrozenTextAndStoresBothInvocations() async throws {
    let source = AIInputSnapshot(meeting: try repairMeeting())
    let draft = try repairDraft()
    let repair = try MinutesCitationRepair(draft: draft, snapshot: source)
    let client = RepairClient([draft, try repairs(repair.issues)])
    let version = try await MeetingAIWorkflow(client: client).summarize(input: source,
        configuration: .init(), profile: "default", template: .interview)
    #expect(version.input == source)
    #expect(version.invocation?.responseID == "call-1")
    #expect(version.citationRepairInvocations?.map(\.responseID) == ["call-2"])
    let inputs = await client.inputs
    #expect(inputs.count == 2)
    let payload = try #require(JSONSerialization.jsonObject(with: Data(inputs[1].utf8)) as? [String: Any])
    let segments = try #require(payload["suppliedSegments"] as? [[String: String]])
    #expect(segments.compactMap { $0["text"] } == source.segments.map(\.text))
    let configurations = await client.configurations
    #expect(configurations.count == 2)
    #expect(configurations.first == configurations.last)
    let restored = try JSONDecoder().decode(MinutesVersion.self, from: JSONEncoder().encode(version))
    #expect(restored.citationRepairInvocations?.count == 1)
}

@Test func failedRepairPreservesCompletedCorrectionAndDoesNotSaveOrLoop() async throws {
    var meeting = try repairMeeting()
    meeting.settings.summaryTemplate = .interview
    var correction = CorrectionVersion(input: AIInputSnapshot(meeting: meeting), configuration: .init(), profile: "default", chunkCount: 1)
    correction.completedChunks = [0]
    meeting.correctionVersions = [correction]
    let draft = try repairDraft()
    let repair = try MinutesCitationRepair(draft: draft, snapshot: AIInputSnapshot(meeting: meeting))
    let client = RepairClient([draft, try repairs(repair.issues, valid: false), try repairs(repair.issues)])
    let state = RepairEventStore(meeting)
    await #expect(throws: AIError.self) {
        try await MeetingAIWorkflow(client: client).run(meeting: meeting, operation: .summary) { try await state.receive($0) }
    }
    let result = await state.meeting
    #expect(await client.inputs.count == 2)
    #expect(result.correctionVersions?.count == 1)
    #expect(result.correctionVersions?.last?.isComplete == true)
    #expect(result.minuteVersions == nil)
    #expect(result.segments == meeting.segments)
}

private actor RepairEventStore {
    var meeting: Meeting
    init(_ meeting: Meeting) { self.meeting = meeting }
    func receive(_ event: AIWorkflowEvent) throws { try meeting.applyAIEvent(event) }
}

@Test func invalidJSONMissingEvidenceAndTransportErrorsDoNotTriggerRepair() async throws {
    let source = AIInputSnapshot(meeting: try repairMeeting())
    let emptyEvidence = #"{"overview":"讨论","topics":[{"text":"待确认","citations":[]}],"decisions":[],"actions":[],"questions":[],"limitations":[]}"#
    for replies in [["not json"], [emptyEvidence], []] {
        let client = RepairClient(replies)
        await #expect(throws: AIError.self) {
            try await MeetingAIWorkflow(client: client).summarize(input: source, configuration: .init(), profile: "default")
        }
        #expect(await client.inputs.count == 1)
    }
}

@Test func legacyRepairUsesEffectiveTextAndNeverNormalizesAnInvalidQuote() throws {
    var source = AIInputSnapshot(meeting: try repairMeeting())
    source.segments[0].text = "建议周五再决定，不是最终承诺！"
    let draft = #"{"overview":"讨论","topics":[{"text":"待确认","citations":[{"segment":"S0001","quote":"不是最终承诺。"},{"segment":"S0001","quote":"   "}]}],"decisions":[],"actions":[],"questions":[],"limitations":[]}"#
    let repair = try MinutesCitationRepair(draft: draft, snapshot: source)
    #expect(repair.issues.count == 2)
    #expect(repair.issues[0].path == "/topics/0/citations/0")
    let bad = #"{"repairs":[{"path":"/topics/0/citations/0","segment":"S0001","quote":"不是最终承诺。"},{"path":"/topics/0/citations/1","segment":"S0001","quote":"   "}]}"#
    #expect(throws: AIError.self) { try repair.applying(bad, snapshot: source) }
    let good = #"{"repairs":[{"path":"/topics/0/citations/0","segment":"S0001","quote":"不是最终承诺！"},{"path":"/topics/0/citations/1","segment":"S0001","quote":"建议周五再决定"}]}"#
    let minutes = try AIOutputValidation.minutes(repair.applying(good, snapshot: source), snapshot: source)
    #expect(minutes.topics[0].citations[0].quote == "不是最终承诺！")
}

private actor CancelRepairClient: AITextGenerating {
    var calls = 0
    let draft: String
    init(_ draft: String) { self.draft = draft }
    func generate(instructions: String, input: String, configuration: ModelConfiguration,
                  profile: String, maxOutputTokens: Int) async throws -> AITextResponse {
        calls += 1
        if calls == 2 { throw CancellationError() }
        return .init(text: draft, invocation: .init(responseID: "cancel-test", model: configuration.modelID,
            endpoint: configuration.endpoint, startedAt: Date(), durationSeconds: 0, inputTokens: nil, outputTokens: nil))
    }
}

@Test func cancellationDuringRepairPropagatesWithoutSavingMinutes() async throws {
    let source = AIInputSnapshot(meeting: try repairMeeting())
    let client = CancelRepairClient(try repairDraft())
    await #expect(throws: CancellationError.self) {
        try await MeetingAIWorkflow(client: client).summarize(input: source, configuration: .init(), profile: "default", template: .interview)
    }
    #expect(await client.calls == 2)
}
