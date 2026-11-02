import Foundation

public enum MeetingChatScope: String, Codable, CaseIterable, Sendable {
    case all, original, minutes
    public var title: String {
        switch self { case .all: "原文与纪要"; case .original: "原始记录"; case .minutes: "仅纪要" }
    }
}

public struct MeetingChatSource: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case original, reviewed, minutes
        public var title: String {
            switch self { case .original: "识别原文"; case .reviewed: "修订记录"; case .minutes: "纪要" }
        }
    }
    public let id: String
    public let kind: Kind
    public let text: String
    public let segmentID: String?
    public let start: TimeInterval?
    public let speaker: String?
    public let minutesVersionID: UUID?
    public init(id: String, kind: Kind, text: String, segmentID: String? = nil, start: TimeInterval? = nil,
                speaker: String? = nil, minutesVersionID: UUID? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.segmentID = segmentID
        self.start = start; self.speaker = speaker; self.minutesVersionID = minutesVersionID
    }
}

public struct MeetingChatCitation: Identifiable, Codable, Sendable {
    public var id: String { source.id + ":" + quote }
    public let source: MeetingChatSource
    public let quote: String
    public init(source: MeetingChatSource, quote: String) { self.source = source; self.quote = quote }
}

public struct MeetingChatContext: Codable, Sendable {
    public let meetingID: UUID
    public let title: String
    public let revision: Int
    public let reviewRevision: Int
    public let batchVersionID: UUID?
    public let minutesVersionID: UUID?
    public let minutesAreStale: Bool
    public let scope: MeetingChatScope
    public let limitations: [String]
    public let sources: [MeetingChatSource]

    public init(meeting: Meeting, scope: MeetingChatScope) {
        meetingID = meeting.id; title = meeting.title; revision = meeting.revision
        reviewRevision = meeting.correctionReviewRevision ?? 0
        batchVersionID = meeting.selectedBatchVersionID
        self.scope = scope
        let minutes = scope == .original ? nil : meeting.minuteVersions?.last
        minutesVersionID = minutes?.id
        minutesAreStale = minutes.map { meeting.isStale($0) } ?? false
        let current = meeting.reusableCorrectionVersion.map { meeting.correctedInput(using: $0) } ?? AIInputSnapshot(meeting: meeting)
        limitations = current.limitations
        var sources: [MeetingChatSource] = []
        if scope != .minutes {
            for (index, segment) in current.segments.enumerated() {
                sources.append(.init(id: "O\(index + 1)", kind: .original, text: segment.originalText,
                    segmentID: segment.id, start: segment.start, speaker: segment.speakerName))
                if scope == .all, segment.text != segment.originalText {
                    sources.append(.init(id: "T\(index + 1)", kind: .reviewed, text: segment.text,
                        segmentID: segment.id, start: segment.start, speaker: segment.speakerName))
                }
            }
        }
        if let minutes {
            let body = MeetingExport.minutesBody(minutes, includeCitations: false)
            for (index, paragraph) in body.components(separatedBy: "\n\n").enumerated() where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sources.append(.init(id: "M\(index + 1)", kind: .minutes, text: paragraph, minutesVersionID: minutes.id))
            }
        }
        self.sources = sources
    }
}

public struct MeetingChatTurn: Identifiable, Codable, Sendable {
    public enum State: String, Codable, Sendable { case answering, completed, failed, cancelled }
    public let id: UUID
    public let createdAt: Date
    public let question: String
    public let scope: MeetingChatScope
    public let inputRevision: Int
    public let reviewRevision: Int
    public let minutesVersionID: UUID?
    public let minutesWereStale: Bool
    public var state: State
    public var answer: String?
    public var citations: [MeetingChatCitation]
    public var error: String?
    public var invocation: AIInvocation?
    public init(question: String, context: MeetingChatContext) {
        id = UUID(); createdAt = Date(); self.question = question; scope = context.scope
        inputRevision = context.revision; reviewRevision = context.reviewRevision
        minutesVersionID = context.minutesVersionID; minutesWereStale = context.minutesAreStale
        state = .answering; citations = []
    }
    public func isStale(in meeting: Meeting) -> Bool {
        inputRevision != meeting.revision || reviewRevision != (meeting.correctionReviewRevision ?? 0)
            || (scope != .original && minutesVersionID != meeting.minuteVersions?.last?.id)
    }
}
