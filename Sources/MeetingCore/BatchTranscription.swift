import Foundation

public enum BatchTranscriptionState: String, Codable, Sendable {
    case running, ready, failed, cancelled, interrupted
}

public enum PostRecordingAction: Sendable { case none, batchReview, generateMinutes }

public struct BatchTranscriptionJob: Identifiable, Codable, Sendable {
    public var id: UUID { chunk.id }
    public let chunk: AudioChunk
    public let name: String
    public let inputKey: String
    public let outputKey: String
    /// nil means unfinished; an empty array is a successfully transcribed silent recording.
    public var segments: [TranscriptSegment]?
    public var cloudCleaned = false
    public let mixedAudio: RecordingAudioSlice?
    public let requestID: String?
    public var submission: BatchSubmissionState?
    public var submittedSeconds: Double?
    public init(chunk: AudioChunk, meetingID: UUID, versionID: UUID, mixedAudio: RecordingAudioSlice? = nil) {
        self.chunk = chunk
        self.mixedAudio = mixedAudio
        requestID = mixedAudio == nil ? nil : UUID().uuidString.lowercased()
        name = "mr-batch-\(versionID.uuidString.lowercased())-\(chunk.id.uuidString.lowercased())"
        let prefix = "meetingrecord/batch/\(meetingID.uuidString)/\(versionID.uuidString)/\(chunk.id.uuidString)"
        inputKey = prefix + ".wav"; outputKey = prefix + ".json"
    }
}

public struct BatchTranscriptionVersion: Identifiable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let settings: AppSettings
    public let bucket: String
    public var state: BatchTranscriptionState = .running
    public var message = "准备录音"
    public var jobs: [BatchTranscriptionJob]
    public let provider: RecordingReviewProvider?
    public let audioPlan: RecordingAudioPlan?
    public let estimatedPricePerHour: Double?
    public var effectiveProvider: RecordingReviewProvider { provider ?? .transcribe }
    public var estimatedCost: SpeechUsage? {
        guard let audioPlan, let price = estimatedPricePerHour else { return nil }
        var usage = SpeechUsage(pricePerHour: price); usage.submittedSeconds = audioPlan.mixedSeconds; return usage
    }
    public var submittedCost: SpeechUsage? {
        guard let price = estimatedPricePerHour else { return nil }
        var usage = SpeechUsage(pricePerHour: price)
        usage.submittedSeconds = jobs.reduce(0) { $0 + ($1.submittedSeconds ?? 0) }
        return usage
    }
    public var segments: [TranscriptSegment] {
        jobs.flatMap { $0.segments ?? [] }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
    public var isComplete: Bool { !jobs.isEmpty && jobs.allSatisfy { $0.segments != nil } }
    public init(meeting: Meeting, settings: AppSettings, bucket: String, audioPlan: RecordingAudioPlan? = nil) throws {
        guard !meeting.status.isActive, !meeting.audioChunks.isEmpty else {
            throw BatchTranscriptionError.invalid("这场会议没有可用的会后录音。请在开始记录前开启本地音频缓存。")
        }
        try CustomVocabularyLibrary.validateBucket(bucket)
        try settings.validateReviewConfiguration()
        if settings.effectiveReviewProvider == .transcribe {
            try settings.transcriptionVocabulary?.validate(scope: .init(profile: settings.profile, region: settings.transcribeRegion))
        }
        let versionID = UUID()
        id = versionID; createdAt = Date(); self.settings = settings; self.bucket = bucket
        provider = settings.effectiveReviewProvider
        self.audioPlan = audioPlan
        estimatedPricePerHour = provider == .doubao ? settings.effectiveReviewSettings.pricePerHour : nil
        if provider == .doubao {
            guard let audioPlan, !audioPlan.slices.isEmpty else { throw BatchTranscriptionError.invalid("没有可提交的混音录音，请先检查本地录音。") }
            jobs = audioPlan.slices.map { slice in
                var chunk = AudioChunk(source: .mixed, relativePath: "", start: slice.start)
                chunk.audioStart = slice.start; chunk.end = slice.end
                return .init(chunk: chunk, meetingID: meeting.id, versionID: versionID, mixedAudio: slice)
            }
        } else { jobs = meeting.audioChunks.map { .init(chunk: $0, meetingID: meeting.id, versionID: versionID) } }
    }
}

public enum BatchTranscriptionError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

public extension Meeting {
    var postRecordingAction: PostRecordingAction {
        guard !status.isActive, !status.isProcessing else { return .none }
        if settings.automaticBatchTranscription == true { return .batchReview }
        if status == .pending, !workingSegments.isEmpty, settings.automaticallyGenerateMinutes ?? true {
            return .generateMinutes
        }
        return .none
    }
    var selectedBatchVersion: BatchTranscriptionVersion? {
        batchVersions?.first { $0.id == selectedBatchVersionID && $0.state == .ready && $0.isComplete }
    }
    var workingSegments: [TranscriptSegment] { selectedBatchVersion?.segments ?? sortedSegments }
    var allTranscriptSegments: [TranscriptSegment] { segments + (batchVersions ?? []).flatMap(\.segments) }
    var transcriptSourceDescription: String {
        guard let version = selectedBatchVersion else {
            return settings.effectiveSpeechProvider == .doubao ? "豆包 2.0 实时转录" : "实时转录"
        }
        let number = (batchVersions?.firstIndex { $0.id == version.id } ?? 0) + 1
        return version.effectiveProvider == .doubao ? "豆包录音复核 V\(number)" : "批量转录 V\(number)"
    }
    mutating func selectTranscript(batchVersionID: UUID?) throws {
        guard !status.isActive, !status.isProcessing else { throw MeetingError.invalidTransition }
        if let batchVersionID {
            guard let version = batchVersions?.first(where: { $0.id == batchVersionID }),
                  version.state == .ready, version.isComplete, !version.segments.isEmpty else {
                throw BatchTranscriptionError.invalid("只有完整且有正文的批量结果才能用于校对和纪要。")
            }
            for segment in version.segments where !speakers.contains(where: { $0.id == segment.originalSpeakerID }) {
                let count = speakers.filter { $0.id.hasPrefix("batch/") }.count + 1
                speakers.append(.init(id: segment.originalSpeakerID,
                    name: segment.source == .microphone ? "我" : "批量发言人 \(count)"))
            }
        }
        guard selectedBatchVersionID != batchVersionID else { return }
        selectedBatchVersionID = batchVersionID; revision += 1
    }
}
