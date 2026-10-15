import Foundation

public extension MeetingExport {
    static func minutesBody(_ version: MinutesVersion, includeCitations: Bool = true) -> String {
        if let edited = version.editedMarkdown {
            return includeCitations ? linkedLegacySources(edited, input: version.input)
                : withoutSourceCitations(edited, input: version.input)
        }
        let minutes = version.minutes
        let english = version.language == "English"
        func label(_ chinese: String, _ englishText: String) -> String {
            if version.language == SummaryLanguage.japanese.rawValue { return L10n.text(chinese, language: .japanese) }
            return english ? englishText : chinese
        }
        func references(_ citations: [SourceCitation]) -> String {
            guard includeCitations else { return "" }
            let links = Array(Set(citations.map(\.reference))).sorted().map(sourceLink).joined(separator: " ")
            return links.isEmpty ? "" : " " + links
        }
        var lines = ["## \(minutes.sections == nil ? label("会议概览", "Overview") : version.effectiveSummaryTemplate.outputOverviewTitle(language: version.language))", "", minutes.overview]
        func appendPoints(_ title: String, _ points: [MinutesPoint], empty: String) {
            lines += ["", "## \(title)", ""]
            if points.isEmpty { lines.append(empty) }
            var previousHeading: String?
            for point in points {
                if let heading = point.heading, heading != previousHeading {
                    lines += ["", "### \(heading)", ""]
                }
                lines.append("- \(point.text)\(references(point.citations))")
                previousHeading = point.heading
            }
        }
        func appendActions(_ title: String, _ actions: [MinutesAction]) {
            lines += ["", "## \(title)", ""]
            if actions.isEmpty { lines.append(label("未发现明确行动项。", "No explicit action items identified.")) }
            for action in actions {
                lines.append("- \(action.task) · \(label("负责人", "Owner")): \(action.owner ?? label("未明确", "Unspecified")) · \(label("截止日期", "Due date")): \(action.dueDate ?? label("未明确", "Unspecified"))\(references(action.citations))")
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
        if minutes.reviewDetails?.isEmpty == false {
            lines += ["", label("完整录音与校对详情保留在 App 的纪要详情和校对稿中。", "Full recording and proofreading details are retained in the app and the proofread transcript."), ""]
        }
        if !version.input.userNote.isEmpty { lines += ["", "## \(label("用户补充（人工备注，非会上原话）", "User supplement (not spoken in the meeting)"))", "", version.input.userNote] }
        let citations = allCitations(version)
        let used = Set(citations.map(\.segmentID))
        if includeCitations && !used.isEmpty {
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

    static func minutes(_ version: MinutesVersion, format: Format, includeCitations: Bool = true) -> String {
        let language = (SummaryLanguage(rawValue: version.language) ?? .chinese).locale
        func label(_ key: String) -> String { L10n.text(key, language: language) }
        let template = version.effectiveSummaryTemplate
        let templateName = version.summaryTemplate == nil ? label("会议纪要（历史版本）")
            : (template.isBuiltIn ? label(template.name) : template.name) + " · V\(template.revision)"
        var text = """
        # \(version.input.title)

        \(L10n.tr("时间：\(version.input.startedAt.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(Locale(identifier: language.rawValue))))", language: language))
        \(L10n.tr("版本：\(version.id.uuidString) · 输入版本 \(version.input.inputRevision)", language: language))
        \(L10n.tr("转录来源：\(L10n.message(version.input.transcriptSource ?? "实时转录", language: language))", language: language))
        \(label(version.isHumanEdited ? "人工编辑版；新增内容未经 AI 引用校验" : "AI 生成；请结合原文核对"))
        \(L10n.tr("模型：\(version.configuration.displayModel) / \(L10n.text(version.configuration.reasoningLabel, language: language)) · \(version.configuration.destination) / \(version.configuration.endpoint)", language: language))
        \(L10n.tr("模板：\(templateName)", language: language))

        \(minutesBody(version, includeCitations: includeCitations))

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
                     "模型：\(version.configuration.displayModel) / \(version.configuration.reasoningLabel) · \(version.configuration.destination)",
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
    /// Strip only app-owned source notation from a derived copy of human-edited Markdown.
    /// Keep ordinary links, custom footnotes, code examples and manual paragraphs intact.
    static func withoutSourceCitations(_ markdown: String, input: AIInputSnapshot) -> String {
        let known = Set(input.segments.map(\.reference))
        let anchors = Dictionary(uniqueKeysWithValues: known.map { (sourceAnchor($0), $0) })
        let lines = markdown.components(separatedBy: "\n")
        let prose = markdownProseLines(lines)
        let definition = try! NSRegularExpression(pattern: #"^\[\^(S[0-9]+)\]:"#)
        var removed = Set<Int>()
        func nextContent(_ start: Int) -> Int {
            var cursor = start
            while cursor < lines.count && lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty { cursor += 1 }
            return cursor
        }
        func isHeading(_ line: String) -> Bool { line.range(of: #"^#{1,6} "#, options: .regularExpression) != nil }
        func removeParagraph(_ start: Int) -> Int {
            var cursor = start
            while cursor < lines.count, !lines[cursor].isEmpty, prose[cursor],
                  !isHeading(lines[cursor]), anchors[lines[cursor]] == nil,
                  !lines[cursor].hasPrefix("[^") {
                removed.insert(cursor); cursor += 1
            }
            return cursor
        }
        let originalLabels = ["原始识别", "Original transcript", L10n.text("原始识别", language: .japanese)]
        for index in lines.indices where prose[index] && !removed.contains(index) {
            let line = lines[index]
            if let match = definition.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line), known.contains(String(line[range])) {
                removed.insert(index)
                var cursor = index + 1
                // Indented continuation paragraphs belong to this footnote, including their blank separators.
                while cursor < lines.count {
                    let next = nextContent(cursor)
                    guard next < lines.count, lines[next].hasPrefix("    ") || lines[next].hasPrefix("\t") else { break }
                    removed.formUnion(cursor...next); cursor = next + 1
                }
            } else if let reference = anchors[line] {
                let heading = nextContent(index + 1)
                guard heading < lines.count, prose[heading], lines[heading] == "### \(reference)" else { continue }
                removed.formUnion(index...heading)
                let end = removeParagraph(nextContent(heading + 1))
                let original = nextContent(end)
                if original < lines.count, originalLabels.contains(where: { lines[original].hasPrefix($0 + ":") }) {
                    _ = removeParagraph(original)
                }
            }
        }
        let sourceTitles = Set(["原文依据", "Source references", L10n.text("原文依据", language: .japanese)].map { "## " + $0 })
        for index in lines.indices where prose[index] && sourceTitles.contains(lines[index]) {
            var cursor = index + 1
            while cursor < lines.count && (removed.contains(cursor) || lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty) { cursor += 1 }
            if cursor == lines.count || (prose[cursor] && (lines[cursor].hasPrefix("## ") || lines[cursor].hasPrefix("# "))) {
                removed.insert(index)
            }
        }
        let body = lines.enumerated().filter { !removed.contains($0.offset) }.map(\.element).joined(separator: "\n")
        let token = try! NSRegularExpression(pattern: #"\[(S[0-9]+)\]\(#source-(s[0-9]+)\)|\[\^(S[0-9]+)\]"#)
        return mapMarkdownProse(body) { prose, _ in
            var result = prose
            for match in token.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)).reversed() {
                let capture = match.range(at: 1).location != NSNotFound ? 1 : 3
                guard let idRange = Range(match.range(at: capture), in: prose),
                      known.contains(String(prose[idRange])), let range = Range(match.range, in: result) else { continue }
                if capture == 1, let target = Range(match.range(at: 2), in: prose),
                   prose[idRange].lowercased() != String(prose[target]) { continue }
                result.removeSubrange(range)
            }
            return result
        }.trimmingCharacters(in: .newlines)
    }

    static func markdownProseLines(_ lines: [String]) -> [Bool] {
        var fence: (character: Character, count: Int)?
        return lines.map { line in
            let trimmed = line.drop(while: { $0 == " " })
            let indent = line.count - trimmed.count
            if let active = fence {
                let count = trimmed.prefix(while: { $0 == active.character }).count
                if indent <= 3, count >= active.count, trimmed.dropFirst(count).allSatisfy({ $0 == " " || $0 == "\t" }) { fence = nil }
                return false
            }
            if indent >= 4 || line.hasPrefix("\t") { return false }
            if let character = trimmed.first, character == "`" || character == "~" {
                let count = trimmed.prefix(while: { $0 == character }).count
                if count >= 3 { fence = (character, count); return false }
            }
            return true
        }
    }

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
