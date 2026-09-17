import Foundation

public enum MeetingExport {
    public enum Format: String, CaseIterable { case markdown = "md", text = "txt" }
    public static func transcript(_ meeting: Meeting, original: Bool, format: Format, includeNotes: Bool) -> String {
        let markdown = format == .markdown
        var lines = [
            "\(markdown ? "# " : "")\(meeting.title)",
            "",
            "时间：\(meeting.startedAt.formatted(date: .numeric, time: .shortened))",
            "来源：\(meeting.applicationName) · \(meeting.microphoneName)",
            "状态：\(meeting.status.title) · \(original ? "原始转录" : "人工修订稿")",
            "版本：\(meeting.revision)"
        ]
        if meeting.isExample { lines.append("示例数据；不是实际会议记录。") }
        if !meeting.intervals.isEmpty {
            lines += ["", "记录区间说明："]
            for interval in meeting.intervals {
                lines.append("[\(TimeLabel.format(interval.start))–\(interval.end.map(TimeLabel.format) ?? "未知")] \(interval.reason)")
            }
        }
        for segment in meeting.sortedSegments {
            let name = original
                ? (meeting.speakers.first { $0.id == segment.originalSpeakerID }?.name ?? "待确认发言人")
                : meeting.speakerName(for: segment)
            lines += ["", "\(markdown ? "### " : "")\(TimeLabel.format(segment.start))  \(name)",
                      original ? segment.originalText : meeting.text(for: segment)]
            if includeNotes, let note = meeting.annotations[segment.id]?.note, !note.isEmpty {
                lines += ["", "\(markdown ? "> " : "")【人工备注】\(note)"]
            }
        }
        if includeNotes && !meeting.note.isEmpty { lines += ["", "【会后人工补充】", meeting.note] }
        return lines.joined(separator: "\n") + "\n"
    }
}
