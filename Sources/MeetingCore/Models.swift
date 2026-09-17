import Foundation

public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case application, microphone
    public var title: String { self == .application ? "会议应用" : "我的麦克风" }
}

public enum RecognitionLanguage: String, Codable, CaseIterable, Sendable {
    case mixed, chinese, english
    public var title: String {
        switch self { case .mixed: "中英混合"; case .chinese: "中文"; case .english: "English" }
    }
}

public enum MeetingStatus: String, Codable, Sendable {
    case recording, paused, finalizing, pending, interrupted, failed, completed, correcting, summarizing
    public var title: String {
        switch self {
        case .recording: "记录中"
        case .paused: "已暂停"
        case .finalizing: "转录收尾"
        case .pending: "待处理"
        case .interrupted: "记录已中断"
        case .failed: "部分完成"
        case .completed: "已完成"
        case .correcting: "AI 校对中"
        case .summarizing: "纪要生成中"
        }
    }
    public var isCapturing: Bool { self == .recording }
    public var isActive: Bool { [.recording, .paused, .finalizing].contains(self) }
    public var isProcessing: Bool { self == .correcting || self == .summarizing }
}

public enum ModelChoice: String, Codable, CaseIterable, Sendable {
    case astra = "GPT-6 Astra", sol = "GPT-5.6 Sol", terra = "GPT-5.6 Terra", luna = "GPT-5.6 Luna"
}

public struct ModelConfiguration: Codable, Equatable, Sendable {
    public var model: ModelChoice = .astra
    public var reasoningEffort = "medium"
    // A display name is deliberately not treated as a verified runtime model ID.
    public var modelID = ""
    public var region = "us-west-2"
    public var endpoint = "mantle"
    public init() {}
}

public struct AppSettings: Codable, Sendable {
    public var profile = "default"
    public var transcribeRegion = "us-west-2"
    public var language: RecognitionLanguage = .mixed
    public var correction = ModelConfiguration()
    public var summary = ModelConfiguration()
    public var summaryLanguage = "中文"
    public var cacheAudio = false
    public var detectMeetings = true
    public var automaticallyGenerateMinutes: Bool?
    public var summaryTemplate: SummaryTemplate?
    public var effectiveSummaryTemplate: SummaryTemplate { summaryTemplate ?? .meeting }
    public init() {}
}

public struct Speaker: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var role: String
    public var note: String
    public init(id: String, name: String, role: String = "", note: String = "") {
        self.id = id; self.name = name; self.role = role; self.note = note
    }
}

public struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let resultID: String
    public let source: AudioSource
    public let start: TimeInterval
    public let end: TimeInterval
    public let originalText: String
    public let serviceTranscript: String?
    public let originalSpeakerID: String
    public init(sessionID: String, resultID: String, source: AudioSource, start: TimeInterval,
                end: TimeInterval, text: String, speakerID: String, serviceTranscript: String? = nil) {
        self.id = "\(source.rawValue)/\(sessionID)/\(resultID)"
        self.sessionID = sessionID; self.resultID = resultID; self.source = source
        self.start = start; self.end = end; self.originalText = text; self.originalSpeakerID = speakerID
        self.serviceTranscript = serviceTranscript
    }
}

public struct TranscriptEdit: Identifiable, Codable, Sendable {
    public var id = UUID()
    public let segmentID: String
    public let before: String
    public let after: String
    public var createdAt = Date()
    public var active = true
}

public struct SegmentAnnotation: Codable, Sendable {
    public var note = ""
    public var highlighted = false
    public var assignedSpeakerID: String?
    public init() {}
}

public struct TimelineInterval: Identifiable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case pause, missing, pendingTranscription, interruption }
    public var id = UUID()
    public var kind: Kind
    public var source: AudioSource?
    public var start: TimeInterval
    public var end: TimeInterval?
    public var reason: String
    public init(kind: Kind, source: AudioSource? = nil, start: TimeInterval, end: TimeInterval? = nil, reason: String) {
        self.kind = kind; self.source = source; self.start = start; self.end = end; self.reason = reason
    }
}

public struct AudioChunk: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var source: AudioSource
    public var relativePath: String
    public var start: TimeInterval
    public var end: TimeInterval?
    public init(source: AudioSource, relativePath: String, start: TimeInterval) {
        self.source = source; self.relativePath = relativePath; self.start = start
    }
}

public struct AudioCaptureDiagnostic: Codable, Sendable {
    public var bundleIDs: [String]
    public var processCount: Int
    public var clockDeviceName: String?
    public init(bundleIDs: [String], processCount: Int, clockDeviceName: String?) {
        self.bundleIDs = bundleIDs; self.processCount = processCount; self.clockDeviceName = clockDeviceName
    }
}

public struct SpeakerMerge: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var from: String
    public var into: String
    public var createdAt = Date()
    public var active = true
}

public struct DerivedVersion: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var inputRevision: Int
    public var createdAt = Date()
    public var configuration: ModelConfiguration
    public var text: String
    public var sourceSegmentIDs: [String]
    public var userEdited = false
}

public struct Meeting: Identifiable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var lastSavedAt: Date
    public var applicationName: String
    public var applicationBundleID: String
    public var microphoneName: String
    public var status: MeetingStatus
    public var settings: AppSettings
    public var revision: Int = 0
    public var speakers: [Speaker] = []
    public private(set) var segments: [TranscriptSegment] = []
    public var edits: [TranscriptEdit] = []
    public var annotations: [String: SegmentAnnotation] = [:]
    public var intervals: [TimelineInterval] = []
    public var audioChunks: [AudioChunk] = []
    public var applicationAudioDiagnostic: AudioCaptureDiagnostic?
    public var merges: [SpeakerMerge] = []
    public var glossary = ""
    public var note = ""
    public var summaries: [DerivedVersion] = []
    public var correctionVersions: [CorrectionVersion]?
    public var correctionReviews: [CorrectionReview]?
    public var correctionReviewRevision: Int?
    public var minuteVersions: [MinutesVersion]?
    public var aiTask: AIProcessingTask?
    public var issue: String?
    public var isExample = false

    public init(title: String, applicationName: String, bundleID: String, microphoneName: String,
                settings: AppSettings, now: Date = Date()) {
        id = UUID(); self.title = title; startedAt = now; lastSavedAt = now
        self.applicationName = applicationName; applicationBundleID = bundleID
        self.microphoneName = microphoneName; self.settings = settings; status = .recording
    }

    public func offset(at date: Date = Date()) -> TimeInterval { max(0, date.timeIntervalSince(startedAt)) }
    public var sortedSegments: [TranscriptSegment] {
        segments.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
    public func text(for segment: TranscriptSegment) -> String {
        edits.last { $0.active && $0.segmentID == segment.id }?.after ?? segment.originalText
    }
    public func speakerID(for segment: TranscriptSegment) -> String {
        var id = annotations[segment.id]?.assignedSpeakerID ?? segment.originalSpeakerID
        var visited = Set<String>()
        while visited.insert(id).inserted, let merge = merges.last(where: { $0.active && $0.from == id }) {
            id = merge.into
        }
        return id
    }
    public func speakerName(for segment: TranscriptSegment) -> String {
        speakers.first { $0.id == speakerID(for: segment) }?.name ?? "待确认发言人"
    }
    public var hasStaleSummary: Bool {
        minuteVersions?.last.map { isStale($0) } ?? summaries.last.map { $0.inputRevision != revision } ?? false
    }

    /// Final results are append-only. Identical service replay is idempotent; a changed replay is rejected.
    @discardableResult
    public mutating func ingest(_ segment: TranscriptSegment) throws -> Bool {
        guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start,
              !segment.originalText.isEmpty else { throw MeetingError.invalidSegment }
        if let existing = segments.first(where: { $0.id == segment.id }) {
            guard existing == segment else { throw MeetingError.conflictingResult }
            return false
        }
        if !speakers.contains(where: { $0.id == segment.originalSpeakerID }) {
            let number = speakers.filter { $0.id != "me" }.count
            let label = number < 26 ? String(UnicodeScalar(65 + number)!) : "\(number + 1)"
            speakers.append(Speaker(id: segment.originalSpeakerID,
                                    name: segment.originalSpeakerID == "me" ? "我" : "发言人 \(label)"))
        }
        segments.append(segment); revision += 1
        return true
    }

    public mutating func edit(segmentID: String, text newText: String) throws {
        guard let segment = segments.first(where: { $0.id == segmentID }) else { throw MeetingError.unknownSegment }
        let before = text(for: segment)
        guard before != newText else { return }
        edits.append(TranscriptEdit(segmentID: segmentID, before: before, after: newText))
        revision += 1
    }

    public mutating func mergeSpeaker(from: String, into: String) throws {
        guard from != into, speakers.contains(where: { $0.id == from }),
              speakers.contains(where: { $0.id == into }) else { throw MeetingError.invalidMerge }
        var current = into
        var visited: Set<String> = [from]
        while visited.insert(current).inserted {
            guard let next = merges.last(where: { $0.active && $0.from == current }) else {
                merges.append(SpeakerMerge(from: from, into: into)); revision += 1; return
            }
            current = next.into
        }
        throw MeetingError.invalidMerge
    }

    public mutating func pause(now: Date = Date(), reason: String = "用户暂停") throws {
        guard status == .recording else { throw MeetingError.invalidTransition }
        intervals.append(.init(kind: .pause, start: offset(at: now), reason: reason))
        status = .paused
    }
    public mutating func resume(now: Date = Date()) throws {
        guard status == .paused else { throw MeetingError.invalidTransition }
        closeIntervals(now: now); status = .recording
    }
    public mutating func finish(now: Date = Date()) throws {
        guard status == .recording || status == .paused else { throw MeetingError.invalidTransition }
        closeIntervals(now: now); endedAt = now; status = .finalizing
    }
    public mutating func closeIntervals(now: Date = Date()) {
        for i in intervals.indices where intervals[i].end == nil { intervals[i].end = offset(at: now) }
        for i in audioChunks.indices where audioChunks[i].end == nil { audioChunks[i].end = offset(at: now) }
    }
    public mutating func recoverInterrupted() {
        if status.isProcessing {
            status = .failed
            if aiTask == nil { aiTask = .init(stage: .interrupted, progress: "AI 处理中断") }
            aiTask?.stage = .interrupted
            aiTask?.progress = "AI 处理中断"
            aiTask?.error = "可从已保存的校对分块或纪要阶段重试。"
            return
        }
        guard status.isActive else { return }
        closeIntervals(now: lastSavedAt)
        intervals.append(.init(kind: .interruption, start: offset(at: lastSavedAt),
                               reason: "应用或任务意外中断；最后保存之后的内容无法保证完整"))
        endedAt = lastSavedAt; status = .interrupted
        issue = "已恢复保存的资料。请核对中断区间；应用未自动恢复录音。"
    }
}

public enum MeetingError: LocalizedError {
    case invalidSegment, conflictingResult, unknownSegment, invalidTransition, invalidMerge, invalidCorrection
    public var errorDescription: String? {
        switch self {
        case .invalidSegment: "转录时间或正文无效。"
        case .conflictingResult: "服务重发了内容不同的确定结果；已保留最初原文。"
        case .unknownSegment: "找不到对应的原文片段。"
        case .invalidTransition: "当前会议状态不允许此操作。"
        case .invalidMerge: "无法合并这些人物标签，可能形成循环。"
        case .invalidCorrection: "校对未匹配输入版本、原文，或试图覆盖人工编辑。"
        }
    }
}

public enum TimeLabel {
    public static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
