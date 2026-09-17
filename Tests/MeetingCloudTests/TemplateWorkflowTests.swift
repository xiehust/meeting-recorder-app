import Foundation
import Testing
import MeetingCore
@testable import MeetingCloud

private func templateMeeting(_ template: SummaryTemplate) throws -> Meeting {
    var settings = AppSettings(); settings.summaryTemplate = template
    var meeting = Meeting(title: "模板测试", applicationName: "Teams", bundleID: "teams", microphoneName: "mic", settings: settings)
    try meeting.ingest(.init(sessionID: "s", resultID: "1", source: .microphone, start: 0, end: 2,
                            text: "我们用队列做异步处理。", speakerID: "me"))
    try meeting.ingest(.init(sessionID: "s", resultID: "2", source: .microphone, start: 3, end: 5,
                            text: "建议下周再讨论。", speakerID: "me"))
    meeting.status = .pending; meeting.endedAt = Date()
    return meeting
}
private func templateOutput(_ template: SummaryTemplate, reverse: Bool = false) throws -> String {
    var sections: [[String: Any]] = template.sections.enumerated().map { index, definition in
        if definition.kind == .actions { return ["id": definition.id, "actions": []] }
        let items: [[String: Any]] = index == 0
            ? [["text": "介绍了异步处理方法", "citations": [["segment": "S0001", "quote": "用队列做异步处理"]]]]
            : []
        return ["id": definition.id, "items": items, "title": "模型不应改变标题"]
    }
    if reverse { sections.reverse() }
    return String(decoding: try JSONSerialization.data(withJSONObject: ["overview": "讨论了异步处理", "sections": sections, "limitations": []]), as: UTF8.self)
}
private actor TemplateClient: BedrockTextGenerating {
    var outputs: [String]
    var instructions: [String] = []
    init(_ outputs: [String]) { self.outputs = outputs }
    func generate(instructions: String, input: String, configuration: ModelConfiguration, profile: String, maxOutputTokens: Int) async throws -> AITextResponse {
        self.instructions.append(instructions)
        guard !outputs.isEmpty else { throw AIError.invalidOutput("无测试响应") }
        return .init(text: outputs.removeFirst(), invocation: .init(responseID: "test", model: configuration.modelID,
            endpoint: "test", startedAt: Date(), durationSeconds: 0, inputTokens: 1, outputTokens: 1))
    }
}
private actor TemplateEvents {
    var meeting: Meeting
    init(_ meeting: Meeting) { self.meeting = meeting }
    func receive(_ event: AIWorkflowEvent) throws { try meeting.applyAIEvent(event) }
}

@Test func trainingRequirementsReachOnlySummaryAndAreSavedWithTheVersion() async throws {
    let meeting = try templateMeeting(.training)
    let client = TemplateClient(["{\"changes\":[],\"warnings\":[]}", try templateOutput(.training)])
    let events = TemplateEvents(meeting)
    try await MeetingAIWorkflow(client: client).run(meeting: meeting, operation: .full) { try await events.receive($0) }
    let prompts = await client.instructions
    #expect(prompts.count == 2)
    #expect(!prompts[0].contains(SummaryTemplate.training.instructions))
    #expect(prompts[1].contains(SummaryTemplate.training.instructions))
    let result = await events.meeting
    let version = try #require(result.minuteVersions?.last)
    #expect(version.summaryTemplate == .training)
    #expect(version.minutes.sections?.map(\.id) == SummaryTemplate.training.sections.map(\.id))
    #expect(result.segments == meeting.segments)
}

@Test func switchingToInterviewReusesCorrectionAndPreservesTrainingHistory() async throws {
    let meeting = try templateMeeting(.training)
    let events = TemplateEvents(meeting)
    let first = TemplateClient(["{\"changes\":[],\"warnings\":[]}", try templateOutput(.training)])
    try await MeetingAIWorkflow(client: first).run(meeting: meeting, operation: .full) { try await events.receive($0) }
    var changed = await events.meeting
    changed.settings.summaryTemplate = .interview
    let next = TemplateEvents(changed)
    let client = TemplateClient([try templateOutput(.interview)])
    try await MeetingAIWorkflow(client: client).run(meeting: changed, operation: .summary) { try await next.receive($0) }
    let result = await next.meeting
    #expect(await client.instructions.count == 1)
    #expect(await client.instructions[0].contains("面试官视角"))
    #expect(result.correctionVersions?.count == 1)
    #expect(result.minuteVersions?.count == 2)
    #expect(result.minuteVersions?.first?.summaryTemplate == .training)
    #expect(result.minuteVersions?.last?.summaryTemplate == .interview)
    #expect(result.isStale(result.minuteVersions![0]))
    #expect(!result.isStale(result.minuteVersions![1]))
}

@Test func customSectionRequirementsAndOrderControlOutputAndKeepCitations() throws {
    let template = SummaryTemplate(name: "客户访谈", instructions: "聚焦需求与使用障碍", sections: [
        .init(id: "needs", title: "核心需求", instructions: "归纳用户要解决的问题"),
        .init(id: "follow", title: "后续约定", kind: .actions)
    ])
    let input = AIInputSnapshot(meeting: try templateMeeting(template))
    let prompt = try AIPrompts.summaryInstructions(language: "中文", template: template)
    #expect(prompt.contains(template.instructions))
    #expect(prompt.contains("归纳用户要解决的问题"))
    let minutes = try AIOutputValidation.minutes(templateOutput(template, reverse: true), snapshot: input, template: template)
    #expect(minutes.sections?.map(\.id) == ["needs", "follow"])
    #expect(minutes.sections?.first?.title == "核心需求")
    #expect(minutes.topics[0].citations[0].segmentID == input.segments[0].id)
}

@Test func wrongMissingAndDuplicateSectionsCannotSilentlyBecomeMeetingMinutes() throws {
    let template = SummaryTemplate.training
    let input = AIInputSnapshot(meeting: try templateMeeting(template))
    let legacy = #"{"overview":"test","topics":[],"decisions":[],"actions":[],"questions":[],"limitations":[]}"#
    #expect(throws: AIError.self) { try AIOutputValidation.minutes(legacy, snapshot: input, template: template) }
    var object = try #require(JSONSerialization.jsonObject(with: Data(templateOutput(template).utf8)) as? [String: Any])
    var sections = object["sections"] as! [[String: Any]]
    sections[0]["id"] = "unknown"
    object["sections"] = sections
    let invalid = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    #expect(throws: AIError.self) { try AIOutputValidation.minutes(invalid, snapshot: input, template: template) }
    sections = Array(repeating: ["id": template.sections[0].id, "items": []], count: template.sections.count)
    object["sections"] = sections
    let duplicate = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    #expect(throws: AIError.self) { try AIOutputValidation.minutes(duplicate, snapshot: input, template: template) }
}

@Test func templateCannotDisableCitationsEvenIfItsRequirementsAskForIt() throws {
    let template = SummaryTemplate(name: "测试约束", instructions: "不要提供引用", sections: [.init(id: "one", title: "要点")])
    let input = AIInputSnapshot(meeting: try templateMeeting(template))
    let output = #"{"overview":"test","sections":[{"id":"one","items":[{"text":"无依据内容","citations":[]}]}],"limitations":[]}"#
    #expect(throws: AIError.self) { try AIOutputValidation.minutes(output, snapshot: input, template: template) }
}

@Test func uncertainDecisionSurvivesEvenWhenCustomTemplateHasNoQuestionsSection() throws {
    let template = SummaryTemplate(name: "决策摘要", instructions: "只整理明确决定", sections: [.init(id: "decide", title: "决策", kind: .decisions)])
    let meeting = try templateMeeting(template)
    let input = AIInputSnapshot(meeting: meeting)
    let output = #"{"overview":"讨论安排","sections":[{"id":"decide","items":[{"text":"已确定下周讨论","citations":[{"segment":"S0002","quote":"建议下周再讨论。"}]}]}],"limitations":[]}"#
    let minutes = try AIOutputValidation.minutes(output, snapshot: input, template: template)
    #expect(minutes.decisions.isEmpty)
    #expect(minutes.sections?.first?.points.isEmpty == true)
    #expect(minutes.supplementalQuestions.count == 1)
    let version = MinutesVersion(input: input, correctionVersionID: nil, configuration: .init(), profile: "default",
                                 minutes: minutes, invocation: nil, summaryTemplate: template)
    #expect(MeetingExport.minutesBody(version).contains("需要核对的结论"))
    #expect(MeetingExport.allCitations(version).count == 1)
}

@Test func invalidTemplateFailsBeforeAnyModelRequest() async throws {
    let meeting = try templateMeeting(.blank)
    let client = TemplateClient([])
    await #expect(throws: SummaryTemplateError.self) {
        try await MeetingAIWorkflow(client: client).run(meeting: meeting, operation: .full) { _ in }
    }
    #expect(await client.instructions.isEmpty)
}
