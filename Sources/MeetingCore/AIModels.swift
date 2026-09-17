import Foundation

public struct AISegment: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let reference: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let speakerID: String
    public let speakerName: String
    public let originalText: String
    public var text: String
    public let humanProtected: Bool
    public let note: String
}

public struct AIInputSnapshot: Codable, Equatable, Sendable {
    public let meetingID: UUID
    public let title: String
    public let startedAt: Date
    public let inputRevision: Int
    public var reviewRevision: Int
    public let glossary: String
    public let userNote: String
    public let participants: [Speaker]
    public var segments: [AISegment]
    public var limitations: [String]
    public var transcriptSource: String?

    public init(meeting: Meeting) {
        meetingID = meeting.id; title = meeting.title; startedAt = meeting.startedAt
        inputRevision = meeting.revision; reviewRevision = meeting.correctionReviewRevision ?? 0
        glossary = meeting.glossary; userNote = meeting.note
        participants = meeting.speakers
        transcriptSource = meeting.transcriptSourceDescription
        segments = meeting.workingSegments.enumerated().map { index, segment in
            AISegment(id: segment.id, reference: String(format: "S%04d", index + 1),
                start: segment.start, end: segment.end, speakerID: meeting.speakerID(for: segment),
                speakerName: meeting.speakerName(for: segment), originalText: segment.originalText,
                text: meeting.text(for: segment),
                humanProtected: meeting.edits.contains { $0.active && $0.segmentID == segment.id },
                note: meeting.annotations[segment.id]?.note ?? "")
        }
        limitations = meeting.intervals.filter { $0.kind != .pause }.map {
            "\(TimeLabel.format($0.start))–\($0.end.map(TimeLabel.format) ?? "未知")：\($0.reason)"
        }
        if meeting.selectedBatchVersion != nil {
            limitations.append("依据会后录音批量转录。实时与批量的发言人编号独立，需核对人物；未录到的声音无法恢复。区间异常保留供复核。")
        }
    }
}

public enum CorrectionDisposition: String, Codable, Sendable { case accepted, pending, rejected }

public struct AICorrection: Identifiable, Codable, Sendable {
    public let id: UUID
    public let segmentID: String
    public let before: String
    public let after: String
    public let reason: String
    public let initialDisposition: CorrectionDisposition
    public init(segmentID: String, before: String, after: String, reason: String, disposition: CorrectionDisposition) {
        id = UUID(); self.segmentID = segmentID; self.before = before; self.after = after
        self.reason = reason; initialDisposition = disposition
    }
}

public struct CorrectionVersion: Identifiable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let input: AIInputSnapshot
    public let configuration: ModelConfiguration
    public let profile: String
    public let chunkCount: Int
    public var completedChunks: [Int]
    public var changes: [AICorrection]
    public var warnings: [String]
    public var calls: [AIInvocation]
    public var isComplete: Bool { completedChunks.count == chunkCount }
    public init(input: AIInputSnapshot, configuration: ModelConfiguration, profile: String, chunkCount: Int) {
        id = UUID(); createdAt = Date(); self.input = input; self.configuration = configuration
        self.profile = profile; self.chunkCount = chunkCount; completedChunks = []
        changes = []; warnings = []; calls = []
    }
}

public struct CorrectionReview: Identifiable, Codable, Sendable {
    public var id = UUID()
    public let versionID: UUID
    public let changeID: UUID
    public let disposition: CorrectionDisposition
    public var reviewedAt = Date()
    public init(versionID: UUID, changeID: UUID, disposition: CorrectionDisposition) {
        self.versionID = versionID; self.changeID = changeID; self.disposition = disposition
    }
}

public struct SourceCitation: Identifiable, Codable, Equatable, Sendable {
    public var id: String { segmentID + ":" + quote }
    public let segmentID: String
    public let reference: String
    public let quote: String
    public init(segmentID: String, reference: String, quote: String) {
        self.segmentID = segmentID; self.reference = reference; self.quote = quote
    }
}

public struct MinutesPoint: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var text: String
    public var citations: [SourceCitation]
    public init(text: String, citations: [SourceCitation]) { self.text = text; self.citations = citations }
}

public struct MinutesAction: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var task: String
    public var owner: String?
    public var dueDate: String?
    public var citations: [SourceCitation]
    public init(task: String, owner: String?, dueDate: String?, citations: [SourceCitation]) {
        self.task = task; self.owner = owner; self.dueDate = dueDate; self.citations = citations
    }
}

public struct MeetingMinutes: Codable, Sendable {
    public var overview: String
    public var topics: [MinutesPoint]
    public var decisions: [MinutesPoint]
    public var actions: [MinutesAction]
    public var questions: [MinutesPoint]
    public var limitations: [String]
    public var sections: [MinutesSection]?
    public init(overview: String, topics: [MinutesPoint], decisions: [MinutesPoint],
                actions: [MinutesAction], questions: [MinutesPoint], limitations: [String], sections: [MinutesSection]? = nil) {
        self.overview = overview; self.topics = topics; self.decisions = decisions
        self.actions = actions; self.questions = questions; self.limitations = limitations
        self.sections = sections
    }

    public var supplementalQuestions: [MinutesPoint] {
        let placed = Set((sections ?? []).flatMap(\.points).map(\.id))
        return questions.filter { !placed.contains($0.id) }
    }
}

public struct MinutesSection: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let kind: SummarySectionKind
    public var points: [MinutesPoint]
    public var actions: [MinutesAction]
    public init(id: String, title: String, kind: SummarySectionKind, points: [MinutesPoint] = [], actions: [MinutesAction] = []) {
        self.id = id; self.title = title; self.kind = kind; self.points = points; self.actions = actions
    }
}

public struct AIInvocation: Codable, Sendable {
    public let responseID: String
    public let model: String
    public let endpoint: String
    public let startedAt: Date
    public let durationSeconds: Double
    public let inputTokens: Int?
    public let outputTokens: Int?
    public init(responseID: String, model: String, endpoint: String, startedAt: Date,
                durationSeconds: Double, inputTokens: Int?, outputTokens: Int?) {
        self.responseID = responseID; self.model = model; self.endpoint = endpoint
        self.startedAt = startedAt; self.durationSeconds = durationSeconds
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

public struct MinutesVersion: Identifiable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let input: AIInputSnapshot
    public let correctionVersionID: UUID?
    public let configuration: ModelConfiguration
    public let profile: String
    public let minutes: MeetingMinutes
    public let invocation: AIInvocation?
    public let editedFromVersionID: UUID?
    public let editedMarkdown: String?
    public let language: String
    public let summaryTemplate: SummaryTemplate?
    public var effectiveSummaryTemplate: SummaryTemplate { summaryTemplate ?? .meeting }
    public var summaryTemplateDescription: String {
        summaryTemplate.map { "\($0.name) · V\($0.revision)" } ?? "会议纪要（历史版本）"
    }
    public var isHumanEdited: Bool { editedMarkdown != nil }
    public init(input: AIInputSnapshot, correctionVersionID: UUID?, configuration: ModelConfiguration,
                profile: String, minutes: MeetingMinutes, invocation: AIInvocation?,
                editedFromVersionID: UUID? = nil, editedMarkdown: String? = nil, language: String = "中文",
                summaryTemplate: SummaryTemplate? = nil) {
        id = UUID(); createdAt = Date(); self.input = input; self.correctionVersionID = correctionVersionID
        self.configuration = configuration; self.profile = profile; self.minutes = minutes; self.invocation = invocation
        self.editedFromVersionID = editedFromVersionID; self.editedMarkdown = editedMarkdown
        self.language = language
        self.summaryTemplate = summaryTemplate
    }
}

public struct AIProcessingTask: Codable, Sendable {
    public enum Stage: String, Codable, Sendable { case correction, summary, completed, failed, cancelled, interrupted }
    public var id = UUID()
    public var startedAt = Date()
    public var stage: Stage
    public var progress: String
    public var error: String?
    public var input: AIInputSnapshot?
    public var configuration: ModelConfiguration?
    public var profile: String?
    public var summaryTemplate: SummaryTemplate?
    public init(stage: Stage, progress: String, error: String? = nil, input: AIInputSnapshot? = nil,
                configuration: ModelConfiguration? = nil, profile: String? = nil, summaryTemplate: SummaryTemplate? = nil) {
        self.stage = stage; self.progress = progress; self.error = error
        self.input = input; self.configuration = configuration; self.profile = profile
        self.summaryTemplate = summaryTemplate
    }
}

public extension Meeting {
    func disposition(of change: AICorrection, in version: CorrectionVersion) -> CorrectionDisposition {
        correctionReviews?.last { $0.versionID == version.id && $0.changeID == change.id }?.disposition ?? change.initialDisposition
    }

    func correctedInput(using version: CorrectionVersion) -> AIInputSnapshot {
        var snapshot = version.input
        snapshot.reviewRevision = correctionReviewRevision ?? 0
        for index in snapshot.segments.indices {
            let segment = snapshot.segments[index]
            if !segment.humanProtected, let change = version.changes.first(where: { $0.segmentID == segment.id }),
               disposition(of: change, in: version) == .accepted {
                snapshot.segments[index].text = change.after
            }
        }
        let pending = version.changes.filter { disposition(of: $0, in: version) == .pending }
        if !pending.isEmpty {
            snapshot.limitations.append("有 \(pending.count) 处校对建议尚未确认；这些片段仍使用修改前的文本。")
        }
        snapshot.limitations += version.warnings
        return snapshot
    }

    mutating func reviewCorrection(versionID: UUID, changeID: UUID, disposition: CorrectionDisposition) throws {
        guard let version = correctionVersions?.first(where: { $0.id == versionID }),
              version.isComplete, version.changes.contains(where: { $0.id == changeID }) else {
            throw MeetingError.invalidCorrection
        }
        if correctionReviews == nil { correctionReviews = [] }
        correctionReviews?.append(.init(versionID: versionID, changeID: changeID, disposition: disposition))
        correctionReviewRevision = (correctionReviewRevision ?? 0) + 1
    }

    func pendingCorrections(in version: CorrectionVersion) -> [AICorrection] {
        let protectedIDs = Set(edits.filter(\.active).map(\.segmentID))
        let sources = Dictionary(uniqueKeysWithValues: version.input.segments.map { ($0.id, $0) })
        return version.changes.filter { change in
            guard disposition(of: change, in: version) == .pending,
                  !protectedIDs.contains(change.segmentID),
                  let source = sources[change.segmentID], !source.humanProtected,
                  source.text == change.before else { return false }
            return true
        }
    }

    /// One explicit approval of the pending suggestions, with a separate reversible review record for each change.
    /// Previously rejected suggestions are preserved; repeated clicks do not create new records.
    @discardableResult
    mutating func acceptAllPendingCorrections(versionID: UUID) throws -> Int {
        guard let version = correctionVersions?.first(where: { $0.id == versionID }),
              version.isComplete, version.input.meetingID == id, version.input.inputRevision == revision else {
            throw MeetingError.invalidCorrection
        }
        let pending = pendingCorrections(in: version)
        guard !pending.isEmpty else { return 0 }
        if correctionReviews == nil { correctionReviews = [] }
        correctionReviews?.append(contentsOf: pending.map {
            CorrectionReview(versionID: version.id, changeID: $0.id, disposition: .accepted)
        })
        correctionReviewRevision = (correctionReviewRevision ?? 0) + 1
        return pending.count
    }

    func isStale(_ version: MinutesVersion) -> Bool {
        if version.effectiveSummaryTemplate != settings.effectiveSummaryTemplate { return true }
        if version.input.inputRevision != revision || version.input.reviewRevision != (correctionReviewRevision ?? 0) { return true }
        if let inputCorrection = version.correctionVersionID,
           let newest = correctionVersions?.last(where: { $0.isComplete && $0.input.inputRevision == revision }),
           newest.id != inputCorrection { return true }
        return false
    }
}
