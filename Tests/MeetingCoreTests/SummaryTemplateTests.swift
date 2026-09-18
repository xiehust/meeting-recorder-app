import Foundation
import Testing
@testable import MeetingCore

@Test func oldBuiltInSettingsUpgradeOnlyForNewGenerationsAndCustomTemplatesStayFrozen() throws {
    var old = SummaryTemplate.meeting
    old.revision = 1; old.instructions = "旧版要求"
    var settings = AppSettings(); settings.summaryTemplate = old
    let meeting = Meeting(title: "历史纪要", applicationName: "Teams", bundleID: "teams", microphoneName: "mic", settings: settings)
    let version = MinutesVersion(input: .init(meeting: meeting), correctionVersionID: nil, configuration: .init(), profile: "default",
        minutes: .init(overview: "旧概览", topics: [], decisions: [], actions: [], questions: [], limitations: []),
        invocation: nil, summaryTemplate: old)
    #expect(settings.effectiveSummaryTemplate == .meeting)
    #expect(settings.summaryTemplate == old)
    #expect(version.effectiveSummaryTemplate == old)
    #expect(meeting.isStale(version))
    settings.summaryTemplate = old.duplicate()
    #expect(settings.effectiveSummaryTemplate.instructions == "旧版要求")
    #expect(settings.effectiveSummaryTemplate.revision == 1)
}

@Test func historicalMinutesWithoutTopicHeadingsOrReviewDetailsRemainReadable() throws {
    let point = MinutesPoint(text: "旧条目", citations: [])
    let minutes = MeetingMinutes(overview: "旧概览", topics: [point], decisions: [], actions: [], questions: [], limitations: ["旧疑点"])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(minutes)) as? [String: Any])
    object.removeValue(forKey: "reviewDetails")
    var topics = try #require(object["topics"] as? [[String: Any]])
    topics[0].removeValue(forKey: "heading"); object["topics"] = topics
    let restored = try JSONDecoder().decode(MeetingMinutes.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(restored.topics[0].heading == nil)
    #expect(restored.reviewDetails == nil)
    #expect(restored.limitations == ["旧疑点"])
}

@Test func builtInTemplatesAndLegacySettingsDefaultToMeetingMinutes() throws {
    #expect(SummaryTemplate.builtIns.map(\.name) == ["会议纪要", "面试纪要（面试官视角）", "培训纪要"])
    for template in SummaryTemplate.builtIns { _ = try template.validated() }
    let data = try JSONEncoder().encode(AppSettings())
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.effectiveSummaryTemplate == .meeting)
    #expect(SummaryTemplate.interview.sections.contains { $0.title == "关键问题与回答" })
    #expect(SummaryTemplate.training.sections.contains { $0.title == "操作步骤与案例" })
}

@Test func customLibraryRoundTripsAndRevisionsPreserveSnapshotsAfterDeletion() throws {
    var library = SummaryTemplateLibrary()
    var draft = SummaryTemplate.meeting.duplicate()
    draft.name = "客户访谈"
    let first = try library.save(draft)
    var version = first
    version.instructions = "重点整理用户需求与使用障碍"
    version.sections.swapAt(0, 1)
    let second = try library.save(version)
    #expect(second.revision == 2)
    #expect(first.revision == 1)
    #expect(first.sections[0].id == "topics")
    let encoded = try JSONEncoder().encode(library)
    var restored = try JSONDecoder().decode(SummaryTemplateLibrary.self, from: encoded)
    try restored.validateLoaded()
    #expect(restored.custom == [second])
    #expect(try restored.save(second).revision == 2)
    try restored.delete(id: second.id)
    #expect(restored.custom.isEmpty)
    #expect(first.instructions == SummaryTemplate.meeting.instructions)
    #expect(first.sections[0].id == "topics")
}

@Test func invalidAndDuplicateTemplatesCannotReplaceBuiltIns() throws {
    var library = SummaryTemplateLibrary()
    #expect(throws: SummaryTemplateError.self) { try library.save(.meeting) }
    #expect(throws: SummaryTemplateError.self) { try library.delete(id: SummaryTemplate.training.id) }
    var draft = SummaryTemplate.blank
    #expect(throws: SummaryTemplateError.self) { try library.save(draft) }
    draft.name = "会议纪要"; draft.instructions = "测试"
    #expect(throws: SummaryTemplateError.self) { try library.save(draft) }
    draft.name = "重复章节"
    draft.sections = [.init(id: "same", title: "一"), .init(id: "same", title: "二")]
    #expect(throws: SummaryTemplateError.self) { try draft.validated() }
    #expect(library.custom.isEmpty)
}

@Test func changingTemplateInvalidatesMinutesButDoesNotChangeCorrectionRevision() throws {
    var meeting = Meeting(title: "test", applicationName: "Teams", bundleID: "teams", microphoneName: "mic", settings: .init())
    try meeting.ingest(.init(sessionID: "s", resultID: "r", source: .microphone, start: 0, end: 1, text: "讨论内容", speakerID: "me"))
    let input = AIInputSnapshot(meeting: meeting)
    let old = MinutesVersion(input: input, correctionVersionID: nil, configuration: .init(), profile: "default",
        minutes: .init(overview: "概览", topics: [], decisions: [], actions: [], questions: [], limitations: []), invocation: nil)
    meeting.minuteVersions = [old]
    #expect(!meeting.isStale(old))
    meeting.settings.summaryTemplate = .training
    #expect(meeting.isStale(old))
    #expect(meeting.revision == input.inputRevision)
    #expect(old.effectiveSummaryTemplate == .meeting)
}

@Test func templateAndRenderedChaptersSurviveVersionRoundTripAndExportInOrder() throws {
    let meeting = Meeting(title: "training", applicationName: "Zoom", bundleID: "zoom", microphoneName: "mic", settings: .init())
    let template = SummaryTemplate(name: "实践记录", instructions: "先案例，再结论", overviewTitle: "实践概览", sections: [
        .init(id: "case", title: "案例复盘"), .init(id: "conclusion", title: "关键结论")
    ])
    let minutes = MeetingMinutes(overview: "复盘", topics: [], decisions: [], actions: [], questions: [], limitations: [],
        sections: template.sections.map { .init(id: $0.id, title: $0.title, kind: $0.kind) })
    let version = MinutesVersion(input: .init(meeting: meeting), correctionVersionID: nil, configuration: .init(),
        profile: "default", minutes: minutes, invocation: nil, summaryTemplate: template)
    let restored = try JSONDecoder().decode(MinutesVersion.self, from: JSONEncoder().encode(version))
    #expect(restored.summaryTemplate == template)
    let body = MeetingExport.minutes(restored, format: .markdown)
    #expect(body.contains("## 实践概览"))
    #expect(body.contains("模板：实践记录"))
    let first = try #require(body.range(of: "## 案例复盘")?.lowerBound)
    let second = try #require(body.range(of: "## 关键结论")?.lowerBound)
    #expect(first < second)
}
