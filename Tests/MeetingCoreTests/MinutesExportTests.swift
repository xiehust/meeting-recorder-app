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

@Test func citationFreeExportsCoverTemplatesActionsAndQuestionsWithoutChangingStoredVersions() throws {
    for template in [nil, SummaryTemplate.training] {
        for language in ["中文", "English", "日本語"] {
            let version = try exportFixture(template: template, language: language)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let before = try encoder.encode(version)
            for format in MeetingExport.Format.allCases {
                let clean = MeetingExport.minutes(version, format: format, includeCitations: false)
                #expect(clean.contains("培训目标与知识框架"))
                #expect(clean.contains("完成练习"))
                #expect(clean.contains("需要核对的结论"))
                #expect(clean.contains("下周"))
                #expect(!clean.contains("#source-"))
                #expect(!clean.contains("S0001"))
                #expect(!clean.contains("S0002"))
                #expect(!clean.contains("00:00:03"))
                #expect(!clean.contains("先介绍培训目标"))
                #expect(!clean.contains("## 原文依据"))
                #expect(!clean.contains("## Source references"))
            }
            #expect(try encoder.encode(version) == before)
            #expect(MeetingExport.minutesBody(version).contains("[S0001](#source-s0001)"))
        }
    }
}

@Test func citationFreeEditedMarkdownRemovesOnlySourceBlocksAndKeepsManualParagraphs() throws {
    let original = try exportFixture()
    let edited = MeetingExport.minutesBody(original) + "\n人工补充：这段要保留。\n\n## 后续安排\n下一次会议。"
    let version = try exportFixture(edited: edited)
    let clean = MeetingExport.minutesBody(version, includeCitations: false)
    #expect(!clean.contains("#source-"))
    #expect(!clean.contains("S0001"))
    #expect(!clean.contains("### S0002"))
    #expect(!clean.contains("00:00:03"))
    #expect(!clean.contains("原始识别:"))
    #expect(clean.contains("培训目标与知识框架"))
    #expect(clean.contains("完成练习"))
    #expect(clean.contains("人工补充：这段要保留。"))
    #expect(clean.contains("## 后续安排\n下一次会议。"))
    #expect(version.editedMarkdown == edited)
    #expect(MeetingExport.minutesBody(version) == edited)
}

@Test func citationFreeLegacyEditsKeepCustomFootnotesLinksCodeAndEscapedText() throws {
    let edited = #"""
    ## 人工纪要
    保留人工结论 [^S0001] [S0002](#source-s0002)。
    普通链接 [S0001](https://example.com) 与 [外部资料](https://example.com) 保留。
    自定义脚注 [^custom]、未知引用 [^S0099] 和正文编号 S0001 保留。
    示例 `[^S0001]` 和 `[S0002](#source-s0002)`，转义 \[^S0001]。

    ```md
    [^S0001]: 代码不能删除
    [S0002](#source-s0002)
    ```

        [^S0001]: 缩进代码不能删除

    ## 原文依据
    [^S0001]: 00:00:03 · 讲师 — 引用正文
        原始识别: 旧的原文

        引用的后续段落
    [^custom]: 人工独立脚注

    ## 附记
    保留附记内容。
    """#
    let version = try exportFixture(edited: edited)
    let clean = MeetingExport.minutesBody(version, includeCitations: false)
    #expect(clean.contains("保留人工结论  。"))
    #expect(!clean.contains("00:00:03"))
    #expect(!clean.contains("原始识别: 旧的原文"))
    #expect(!clean.contains("引用的后续段落"))
    #expect(clean.contains("[S0001](https://example.com)"))
    #expect(clean.contains("[外部资料](https://example.com)"))
    #expect(clean.contains("[^custom]: 人工独立脚注"))
    #expect(clean.contains("未知引用 [^S0099] 和正文编号 S0001"))
    #expect(clean.contains(#"示例 `[^S0001]` 和 `[S0002](#source-s0002)`，转义 \[^S0001]。"#))
    #expect(clean.contains("```md\n[^S0001]: 代码不能删除\n[S0002](#source-s0002)\n```"))
    #expect(clean.contains("    [^S0001]: 缩进代码不能删除"))
    #expect(clean.contains("## 附记\n保留附记内容。"))
    #expect(version.editedMarkdown == edited)
}

@Test func citationFreeEditsRemoveEmptySourceAppendixButKeepSectionsWithManualContent() throws {
    for title in ["原文依据", "Source references", L10n.text("原文依据", language: .japanese)] {
        let edited = "结论 [^S0001]\n\n## \(title)\n[^S0001]: 引用原话\n\n## 后记\n人工说明"
        let clean = MeetingExport.minutesBody(try exportFixture(edited: edited), includeCitations: false)
        #expect(!clean.contains("## \(title)"))
        #expect(!clean.contains("引用原话"))
        #expect(clean.contains("## 后记\n人工说明"))
    }
    let manual = "## 原文依据\n\n这是人工写的章节，没有系统引用标注。"
    #expect(MeetingExport.minutesBody(try exportFixture(edited: manual), includeCitations: false) == manual)
}
