import Foundation
import Testing
import MeetingCore
@testable import MeetingCloud

private func qualitySnapshot() throws -> AIInputSnapshot {
    var meeting = Meeting(title: "方案讨论", applicationName: "Teams", bundleID: "teams", microphoneName: "mic", settings: .init())
    meeting.glossary = "Runtime：运行时。仅作背景，不是会议结论。"
    for (index, text) in ["建议分为构建、治理、迭代三层。", "治理需要成本分摊和多租户管理。",
                          "小林你整理一下，我们可能只需要两三段话。"].enumerated() {
        try meeting.ingest(.init(sessionID: "quality", resultID: "\(index)", source: .application,
            start: Double(index * 10), end: Double(index * 10 + 8), text: text, speakerID: "remote"))
    }
    var input = AIInputSnapshot(meeting: meeting)
    input.limitations = (1...40).map { "00:00:\(String(format: "%02d", $0)) · 某个词的拼写待核。" }
    return input
}

private func qualityOutput(heading: String = "分层方案") throws -> String {
    let data = try JSONSerialization.data(withJSONObject: [
        "overview": "讨论了分层方案与整理安排。",
        "sections": [
            ["id": "topics", "items": [
                ["heading": heading, "text": "提出构建、治理、迭代三层方案。", "citations": [["segment": "S0001", "quote": "建议分为构建、治理、迭代三层。"]]],
                ["heading": heading, "text": "治理层关注成本分摊和多租户管理。", "citations": [["segment": "S0002", "quote": "治理需要成本分摊和多租户管理。"]]]
            ]],
            ["id": "decisions", "items": []],
            ["id": "actions", "actions": [["task": "整理方案", "owner": "小林", "dueDate": NSNull(),
                "citations": [["segment": "S0003", "quote": "小林你整理一下"]]]]],
            ["id": "questions", "items": []]
        ],
        "limitations": ["个别称呼拼写待核。", " 个别称呼拼写待核。 "]
    ])
    return String(decoding: data, as: UTF8.self)
}

@Test func summaryKeepsDetailedEvidenceWithoutCopyingTheProofreadingLogIntoTheBody() throws {
    let input = try qualitySnapshot()
    let minutes = try AIOutputValidation.minutes(qualityOutput(), snapshot: input)
    #expect(minutes.topics.map(\.heading) == ["分层方案", "分层方案"])
    #expect(minutes.topics[1].citations[0].quote == input.segments[1].text)
    #expect(minutes.decisions.isEmpty)
    #expect(minutes.actions.first?.owner == "小林")
    #expect(minutes.actions.first?.dueDate == nil)
    #expect(minutes.limitations == ["个别称呼拼写待核。"])
    #expect(minutes.reviewDetails == input.limitations)
    let version = MinutesVersion(input: input, correctionVersionID: nil, configuration: .init(), profile: "default",
                                 minutes: minutes, invocation: nil, summaryTemplate: .meeting)
    let restored = try JSONDecoder().decode(MinutesVersion.self, from: JSONEncoder().encode(version))
    #expect(restored.minutes.reviewDetails?.count == 40)
    let markdown = MeetingExport.minutes(restored, format: .markdown)
    #expect(markdown.components(separatedBy: "### 分层方案").count == 2)
    #expect(markdown.contains("成本分摊和多租户管理"))
    #expect(markdown.contains("[S0002](#source-s0002)"))
    #expect(!markdown.contains(input.limitations[0]))
    #expect(MeetingExport.minutes(restored, format: .text).contains("分层方案"))
    #expect(!MeetingExport.minutes(restored, format: .text).contains("### "))
}

@Test func summaryReceivesTerminologyWithoutTreatingItAsTranscript() throws {
    let input = try qualitySnapshot()
    let data = try #require(AIPrompts.summaryInput(input).data(using: .utf8))
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["glossary"] as? String == input.glossary)
    let segments = try #require(payload["suppliedSegments"] as? [[String: Any]])
    #expect(segments.compactMap { $0["text"] as? String } == input.segments.map(\.text))
    #expect(payload["limitations"] as? [String] == input.limitations)
}

@Test func skippingCorrectionRemainsExplicitEvenWhenTheModelOmitsIt() throws {
    var input = try qualitySnapshot()
    let warning = "本版本明确跳过了 AI 校对，直接根据原始转录与人工修订生成。"
    input.limitations.append(warning)
    let minutes = try AIOutputValidation.minutes(qualityOutput(), snapshot: input)
    #expect(minutes.limitations.contains(warning))
    #expect(minutes.reviewDetails == input.limitations)
}

@Test func invalidTopicHeadingCannotInjectAnExportSection() throws {
    #expect(throws: AIError.self) {
        try AIOutputValidation.minutes(qualityOutput(heading: "方案\n## 编造的决策"), snapshot: qualitySnapshot())
    }
}

private actor PreviewClient: BedrockTextGenerating {
    var calls = 0
    func generate(instructions: String, input: String, configuration: ModelConfiguration,
                  profile: String, maxOutputTokens: Int) async throws -> AITextResponse {
        calls += 1
        return .init(text: try qualityOutput(), invocation: .init(responseID: "preview", model: configuration.modelID,
            endpoint: configuration.endpoint, startedAt: Date(), durationSeconds: 0, inputTokens: 10, outputTokens: 10))
    }
}

@Test func isolatedPreviewUsesTheProductionSummaryPathAndFrozenInput() async throws {
    let input = try qualitySnapshot()
    let client = PreviewClient()
    let version = try await MeetingAIWorkflow(client: client).summarize(input: input, configuration: .init(), profile: "default")
    #expect(version.input == input)
    #expect(version.summaryTemplate == .meeting)
    #expect(version.invocation?.responseID == "preview")
    #expect(version.minutes.reviewDetails == input.limitations)
    #expect(await client.calls == 1)
}
