import Foundation
import Testing
@testable import MeetingCore

private func exportFixture(template: SummaryTemplate? = nil, edited: String? = nil,
                           language: String = "中文") throws -> MinutesVersion {
    var meeting = Meeting(title: "引用跳转测试", applicationName: "Teams", bundleID: "teams",
                          microphoneName: "mic", settings: .init())
    for (index, text) in ["先介绍培训目标", "下周完成练习", "未被引用的发言"].enumerated() {
        try meeting.ingest(.init(sessionID: "export", resultID: "\(index)", source: .application,
            start: Double(index * 60 + 3), end: Double(index * 60 + 5), text: text, speakerID: "speaker"))
    }
    var input = AIInputSnapshot(meeting: meeting)
    input.segments[0].text = "先介绍培训目标。"
    let citations = input.segments.prefix(2).map {
        SourceCitation(segmentID: $0.id, reference: $0.reference, quote: $0.text)
    }
    let point = MinutesPoint(text: "培训目标与知识框架", citations: [citations[0], citations[0]])
    let action = MinutesAction(task: "完成练习", owner: nil, dueDate: "下周", citations: [citations[1]])
    let question = MinutesPoint(text: "需要核对的结论", citations: [citations[0], citations[1]])
    let sections: [MinutesSection]? = template.map { _ in [
        .init(id: "knowledge", title: "培训目标与知识框架", kind: .points, points: [point]),
        .init(id: "practice", title: "课后实践", kind: .actions, actions: [action])
    ] }
    return MinutesVersion(input: input, correctionVersionID: nil, configuration: .init(), profile: "default",
        minutes: .init(overview: "介绍课程并安排练习", topics: [point], decisions: [], actions: [action],
                       questions: [question], limitations: [], sections: sections),
        invocation: nil, editedMarkdown: edited, language: language, summaryTemplate: template)
}

@Test func markdownCitationsLinkToUniqueSnapshotSources() throws {
    let version = try exportFixture()
    let body = MeetingExport.minutes(version, format: .markdown)
    #expect(body.contains("- 培训目标与知识框架 [S0001](#source-s0001)\n"))
    #expect(body.contains("[S0002](#source-s0002)"))
    for reference in ["s0001", "s0002"] {
        #expect(body.components(separatedBy: "<a id=\"source-\(reference)\"></a>").count == 2)
    }
    #expect(!body.contains("[^"))
    #expect(!body.contains("S0003"))
    #expect(!body.contains("未被引用的发言"))
    #expect(body.contains("00:00:03"))
    #expect(body.contains("先介绍培训目标。"))
    #expect(body.contains("原始识别: 先介绍培训目标"))
    #expect(version.input.segments[0].originalText == "先介绍培训目标")
}

@Test func templateSectionsActionsAndSupplementalQuestionsAllLinkToSources() throws {
    let body = MeetingExport.minutesBody(try exportFixture(template: .training))
    #expect(body.contains("## 培训目标与知识框架"))
    #expect(body.contains("## 课后实践"))
    #expect(body.contains("截止日期: 下周 [S0002](#source-s0002)"))
    #expect(body.contains("- 需要核对的结论 [S0001](#source-s0001) [S0002](#source-s0002)"))
    #expect(body.contains("<a id=\"source-s0001\"></a>\n\n### S0001\n\n"))
    #expect(body.contains("<a id=\"source-s0002\"></a>\n\n### S0002\n\n"))
}

@Test func englishMinutesUseTheSameLanguageIndependentLinkTargets() throws {
    let body = MeetingExport.minutesBody(try exportFixture(language: "English"))
    #expect(body.contains("## Source references"))
    #expect(body.contains("Original transcript: 先介绍培训目标"))
    #expect(body.contains("[S0001](#source-s0001)"))
    #expect(body.contains("<a id=\"source-s0001\"></a>"))
}

@Test func legacyEditedFootnotesMigrateWithoutChangingStoredBodyOrUserContent() throws {
    let edited = """
    ## 人工整理
    - 保留这条人工结论 [^S0001] [^S0002] [^custom]
    - 未提供定义的引用 [^S0003]
    - 代码示例 `[^S0001]` 和 ``示例 ` [^S0001]``，转义 \\[^S0001]

    ```md
    [^S0001]: 代码块里的内容
    [^S0001]
    ```

        [^S0001]

    ## 原文依据
    [^S0001]: 00:00:03 · 讲师 — 人工保留的引用文字
        原始识别: 先介绍培训目标
    [^S0002]: 00:01:03 · 学员 — 下周完成练习
    [^custom]: 人工补充的独立脚注
    """
    let version = try exportFixture(edited: edited)
    let body = MeetingExport.minutesBody(version)
    #expect(body.contains("- 保留这条人工结论 [S0001](#source-s0001) [S0002](#source-s0002) [^custom]"))
    #expect(body.contains("<a id=\"source-s0001\"></a>\n\n### S0001\n\n00:00:03 · 讲师 — 人工保留的引用文字"))
    #expect(body.contains("    原始识别: 先介绍培训目标"))
    #expect(body.contains("- 未提供定义的引用 [^S0003]"))
    #expect(!body.contains("#source-s0003"))
    #expect(body.contains("`[^S0001]` 和 ``示例 ` [^S0001]``，转义 \\[^S0001]"))
    #expect(body.contains("```md\n[^S0001]: 代码块里的内容\n[^S0001]\n```"))
    #expect(body.contains("    [^S0001]"))
    #expect(body.contains("[^custom]: 人工补充的独立脚注"))
    #expect(version.editedMarkdown == edited)
}

@Test func newEditedMarkdownAndVersionsWithoutLegacyDefinitionsStayUnchanged() throws {
    let generated = MeetingExport.minutesBody(try exportFixture())
    let edited = generated + "\n人工补充：保留已有结构。"
    #expect(MeetingExport.minutesBody(try exportFixture(edited: edited)) == edited)
    let noDefinition = "人工文字 [^S0001]\n```\n[^S0001]: 仅在示例代码中\n```"
    #expect(MeetingExport.minutesBody(try exportFixture(edited: noDefinition)) == noDefinition)
}

@Test func plainTextMinutesKeepSourceNumbersWithoutMarkdownLinksOrHTMLAnchors() throws {
    let generated = try exportFixture()
    let legacy = try exportFixture(edited: "人工结论 [^S0001]\n\n[^S0001]: 原文片段")
    for version in [generated, legacy] {
        let body = MeetingExport.minutes(version, format: .text)
        #expect(body.contains("[S0001]"))
        #expect(!body.contains("](#source-"))
        #expect(!body.contains("<a "))
        #expect(!body.contains("[^"))
        #expect(!body.contains("### "))
    }
    #expect(MeetingExport.minutes(generated, format: .text).contains("原始识别: 先介绍培训目标"))
    #expect(MeetingExport.minutes(legacy, format: .text).contains("S0001\n\n原文片段"))
}

@Test func minutesWithoutCitationsDoNotEmitAnEmptySourceSection() throws {
    let fixture = try exportFixture()
    let version = MinutesVersion(input: fixture.input, correctionVersionID: nil, configuration: .init(),
        profile: "default", minutes: .init(overview: "没有明确结论", topics: [], decisions: [], actions: [],
                                           questions: [], limitations: []), invocation: nil)
    let body = MeetingExport.minutesBody(version)
    #expect(!body.contains("## 原文依据"))
    #expect(!body.contains("<a "))
}
