import Foundation
import MeetingCore

enum BatchTranscriptParser {
    struct Document: Decodable {
        let jobName: String
        let status: String
        let results: Results
    }
    struct Results: Decodable {
        let items: [Item]
        let transcripts: [Text]
        let speaker_labels: SpeakerLabels?
    }
    struct Text: Decodable { let transcript: String }
    struct Alternative: Decodable { let content: String }
    struct Item: Decodable {
        let type: String
        let start_time: String?
        let end_time: String?
        let speaker_label: String?
        let alternatives: [Alternative]
    }
    struct SpeakerLabels: Decodable { let segments: [SpeakerSegment] }
    struct SpeakerSegment: Decodable { let speaker_label: String; let items: [SpeakerItem] }
    struct SpeakerItem: Decodable { let start_time: String; let end_time: String }

    static func parse(_ data: Data, job: BatchTranscriptionJob) throws -> [TranscriptSegment] {
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw BatchTranscriptionError.invalid("AWS 批量结果格式无效，未采用此结果。") }
        guard document.jobName == job.name, document.status == "COMPLETED" else {
            throw BatchTranscriptionError.invalid("批量结果与请求不匹配或尚未完成。")
        }
        var labels: [String: String] = [:]
        for segment in document.results.speaker_labels?.segments ?? [] {
            for item in segment.items { labels[item.start_time + "/" + item.end_time] = segment.speaker_label }
        }
        var output: [TranscriptSegment] = []
        var text = "", speaker = "", start = 0.0, end = 0.0
        let offset = job.chunk.audioStart ?? job.chunk.start
        guard offset.isFinite, offset >= 0 else { throw MeetingError.invalidSegment }
        func flush() {
            guard !text.isEmpty else { return }
            output.append(.init(sessionID: job.name, resultID: "\(output.count)", source: job.chunk.source,
                start: offset + start, end: offset + end, text: text,
                speakerID: job.chunk.source == .microphone ? "me" : "batch/\(job.name)/\(speaker)"))
            text = ""
        }
        for item in document.results.items {
            guard let token = item.alternatives.first?.content, !token.isEmpty else { continue }
            if item.type == "punctuation" { if !text.isEmpty { text += token }; continue }
            guard item.type == "pronunciation", let from = item.start_time, let to = item.end_time,
                  let a = Double(from), let b = Double(to), a.isFinite, b.isFinite, a >= 0, b >= a else {
                throw BatchTranscriptionError.invalid("批量结果的词级时间戳无效。")
            }
            let who = item.speaker_label ?? labels[from + "/" + to] ?? "unknown"
            if !text.isEmpty && (who != speaker || a - end > 1.5 || b - start > 15) { flush() }
            if text.isEmpty { start = a; speaker = who }
            if let previous = text.last, let next = token.first, !isCJK(previous), !isCJK(next) { text += " " }
            text += token; end = b
        }
        flush()
        if output.isEmpty && document.results.transcripts.contains(where: { !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw BatchTranscriptionError.invalid("批量结果缺少可定位的词级时间戳，未采用此结果。")
        }
        return output
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x3134F).contains($0.value) }
    }
}
