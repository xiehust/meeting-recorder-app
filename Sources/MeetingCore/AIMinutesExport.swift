import Foundation

public extension MeetingExport {
    static func minutesBody(_ version: MinutesVersion) -> String {
        if let edited = version.editedMarkdown { return linkedLegacySources(edited, input: version.input) }
        let minutes = version.minutes
        let english = version.language == "English"
        func label(_ chinese: String, _ englishText: String) -> String { english ? englishText : chinese }
        func references(_ citations: [SourceCitation]) -> String {
            Array(Set(citations.map(\.reference))).sorted().map(sourceLink).joined(separator: " ")
        }
        var lines = ["## \(minutes.sections == nil ? label("会议概览", "Overview") : version.effectiveSummaryTemplate.outputOverviewTitle(language: version.language))", "", minutes.overview]
        func appendPoints(_ title: String, _ points: [MinutesPoint], empty: String) {
            lines += ["", "## \(title)", ""]
            if points.isEmpty { lines.append(empty) }
            for point in points { lines.append("- \(point.text) \(references(point.citations))") }
        }
        func appendActions(_ title: String, _ actions: [MinutesAction]) {
            lines += ["", "## \(title)", ""]
            if actions.isEmpty { lines.append(label("未发现明确行动项。", "No explicit action items identified.")) }
            for action in actions {
                lines.append("- \(action.task) · \(label("负责人", "Owner")): \(action.owner ?? label("未明确", "Unspecified")) · \(label("截止日期", "Due date")): \(action.dueDate ?? label("未明确", "Unspecified")) \(references(action.citations))")
            }
        }
        if let sections = minutes.sections {
            for section in sections {
                if section.kind == .actions { appendActions(section.title, section.actions) }
                else { appendPoints(section.title, section.points, empty: label("未提取到有原文依据的条目。", "No items supported by the transcript.")) }
            }
            if !minutes.supplementalQuestions.isEmpty {
                appendPoints(label("需要核对的结论", "Conclusions requiring verification"), minutes.supplementalQuestions, empty: "")
            }
        } else {
            appendPoints(label("主要议题", "Discussion"), minutes.topics, empty: label("未提取到明确议题。", "No clear topics identified."))
            appendPoints(label("已确认决策", "Confirmed decisions"), minutes.decisions, empty: label("未发现明确达成的决策。", "No confirmed decisions identified."))
            appendActions(label("行动项", "Action items"), minutes.actions)
            appendPoints(label("待确认问题", "Open questions"), minutes.questions, empty: label("无单独提取的待确认问题。", "No separate open questions identified."))
        }
        if !minutes.limitations.isEmpty {
            lines += ["", "## \(label("记录限制与疑点", "Limitations and uncertainty"))", ""] + minutes.limitations.map { "- \($0)" }
        }
        if !version.input.userNote.isEmpty { lines += ["", "## \(label("用户补充（人工备注，非会上原话）", "User supplement (not spoken in the meeting)"))", "", version.input.userNote] }
        let citations = allCitations(version)
        let used = Set(citations.map(\.segmentID))
        if !used.isEmpty {
            lines += ["", "## \(label("原文依据", "Source references"))", ""]
            for segment in version.input.segments where used.contains(segment.id) {
                lines += [sourceHeading(segment.reference), "",
                          "\(TimeLabel.format(segment.start)) · \(segment.speakerName) — \(segment.text)", ""]
                if segment.text != segment.originalText {
                    lines += ["\(label("原始识别", "Original transcript")): \(segment.originalText)", ""]
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func allCitations(_ version: MinutesVersion) -> [SourceCitation] {
        (version.minutes.topics + version.minutes.decisions + version.minutes.questions).flatMap(\.citations)
            + version.minutes.actions.flatMap(\.citations)
    }

    static func minutes(_ version: MinutesVersion, format: Format) -> String {
        var text = """
        # \(version.input.title)

        时间：\(version.input.startedAt.formatted(date: .numeric, time: .shortened))
        版本：\(version.id.uuidString) · 输入版本 \(version.input.inputRevision)
        转录来源：\(version.input.transcriptSource ?? "实时转录")
        \(version.isHumanEdited ? "人工编辑版；新增内容未经 AI 引用校验" : "AI 生成；请结合原文核对")
        模型：\(version.configuration.model.rawValue) / \(version.configuration.reasoningEffort) · \(version.configuration.region) / \(version.configuration.endpoint)
        模板：\(version.summaryTemplateDescription)

        \(minutesBody(version))

        """
        if format == .text {
            for segment in version.input.segments {
                text = text.replacingOccurrences(of: sourceLink(segment.reference), with: "[\(segment.reference)]")
                    .replacingOccurrences(of: sourceAnchor(segment.reference) + "\n\n", with: "")
            }
            text = text.replacingOccurrences(of: #"(?m)^#{1,3} "#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "[^", with: "[")
        }
        return text
    }

    static func correctedTranscript(_ meeting: Meeting, version: CorrectionVersion, format: Format) -> String {
        let input = meeting.correctedInput(using: version)
        var lines = ["\(format == .markdown ? "# " : "")\(input.title) · 校对稿", "",
                     "输入版本：\(input.inputRevision) · 校对版本：\(version.id.uuidString)",
                     "转录来源：\(input.transcriptSource ?? "实时转录")",
                     "模型：\(version.configuration.model.rawValue) / \(version.configuration.reasoningEffort)",
                     "未确认建议不进入正文，人工修订优先。"]
        for segment in input.segments {
            lines += ["", "[\(TimeLabel.format(segment.start))] \(segment.speakerName)", segment.text]
            if !segment.note.isEmpty { lines += ["【人工备注】\(segment.note)"] }
        }
        if !input.limitations.isEmpty { lines += ["", "记录限制与疑点："] + input.limitations }
        return lines.joined(separator: "\n") + "\n"
    }
}

private extension MeetingExport {
    static func sourceLink(_ reference: String) -> String {
        "[\(reference)](#source-\(reference.lowercased()))"
    }

    static func sourceAnchor(_ reference: String) -> String {
        "<a id=\"source-\(reference.lowercased())\"></a>"
    }

    static func sourceHeading(_ reference: String) -> String {
        sourceAnchor(reference) + "\n\n### \(reference)"
    }

    /// Old human-edited versions contain the former footnote export as saved Markdown.
    /// Convert only snapshot references with a definition; never rebuild or persist their body.
    static func linkedLegacySources(_ markdown: String, input: AIInputSnapshot) -> String {
        let known = Set(input.segments.map(\.reference))
        let definition = try! NSRegularExpression(pattern: #"(?m)^\[\^(S[0-9]+)\]:[ \t]?"#)
        var defined = Set<String>()
        _ = mapMarkdownProse(markdown) { prose, startsLine in
            guard startsLine else { return prose }
            for match in definition.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)) {
                if let range = Range(match.range(at: 1), in: prose), known.contains(String(prose[range])) {
                    defined.insert(String(prose[range]))
                }
            }
            return prose
        }
        guard !defined.isEmpty else { return markdown }
        let referenceToken = try! NSRegularExpression(pattern: #"\[\^(S[0-9]+)\](:[ \t]?)?"#)
        return mapMarkdownProse(markdown) { prose, startsLine in
            var result = prose
            for match in referenceToken.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)).reversed() {
                guard let referenceRange = Range(match.range(at: 1), in: prose),
                      let range = Range(match.range, in: result) else { continue }
                let reference = String(prose[referenceRange])
                guard defined.contains(reference) else { continue }
                let suffix = Range(match.range(at: 2), in: prose).map { String(prose[$0]) } ?? ""
                let replacement = startsLine && match.range.location == 0 && !suffix.isEmpty
                    ? sourceHeading(reference) + "\n\n"
                    : sourceLink(reference) + suffix
                result.replaceSubrange(range, with: replacement)
            }
            return result
        }
    }

    /// Keep fenced/indented code, inline code and escaped punctuation literal during migration.
    static func mapMarkdownProse(_ markdown: String, transform: (String, Bool) -> String) -> String {
        let tokens = try! NSRegularExpression(pattern: #"\\.|(`+)[\s\S]*?\1(?!`)"#)
        var fence: (character: Character, count: Int)?
        return markdown.components(separatedBy: "\n").map { line in
            let trimmed = line.drop(while: { $0 == " " })
            let indent = line.count - trimmed.count
            if let active = fence {
                let count = trimmed.prefix(while: { $0 == active.character }).count
                if indent <= 3, count >= active.count,
                   trimmed.dropFirst(count).allSatisfy({ $0 == " " || $0 == "\t" }) { fence = nil }
                return line
            }
            if indent >= 4 || line.hasPrefix("\t") { return line }
            if let character = trimmed.first, character == "`" || character == "~" {
                let count = trimmed.prefix(while: { $0 == character }).count
                if count >= 3 { fence = (character, count); return line }
            }
            var result = ""
            var start = line.startIndex
            for match in tokens.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range, in: line) else { continue }
                result += transform(String(line[start..<range.lowerBound]), start == line.startIndex) + line[range]
                start = range.upperBound
            }
            return result + transform(String(line[start...]), start == line.startIndex)
        }.joined(separator: "\n")
    }
}
