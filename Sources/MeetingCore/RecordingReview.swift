import Foundation

public enum RecordingReviewProvider: String, Codable, CaseIterable, Sendable {
    case transcribe, doubao
    public var title: String { self == .transcribe ? "AWS Transcribe" : "豆包录音文件识别 2.0" }
}

public struct RecordingReviewSettings: Codable, Sendable {
    public var pricePerHour: Double = 0.80
    public var hotwords: [String] = []
    public init() {}
}

public struct RecordingAudioInput: Codable, Sendable {
    public let chunk: AudioChunk
    public let frames: Int64
    public let sampleRate: Double
    public var start: Double { chunk.audioStart ?? chunk.start }
    public var duration: Double { Double(frames) / sampleRate }
    public var end: Double { start + duration }
    public init(chunk: AudioChunk, frames: Int64, sampleRate: Double) {
        self.chunk = chunk; self.frames = frames; self.sampleRate = sampleRate
    }
}

public struct RecordingAudioSlice: Codable, Sendable {
    public let start: Double
    public let duration: Double
    public let inputs: [RecordingAudioInput]
    public var end: Double { start + duration }
}

public struct RecordingAudioPlan: Codable, Sendable {
    public let inputs: [RecordingAudioInput]
    public let slices: [RecordingAudioSlice]
    public var sourceSeconds: Double { inputs.reduce(0) { $0 + $1.duration } }
    public var mixedSeconds: Double { slices.reduce(0) { $0 + $1.duration } }
    public var applicationSeconds: Double { inputs.filter { $0.chunk.source == .application }.reduce(0) { $0 + $1.duration } }
    public var microphoneSeconds: Double { inputs.filter { $0.chunk.source == .microphone }.reduce(0) { $0 + $1.duration } }

    public init(inputs: [RecordingAudioInput], maximumSliceSeconds: Double = 14_400) throws {
        guard maximumSliceSeconds.isFinite, maximumSliceSeconds > 0, maximumSliceSeconds <= 14_400,
              inputs.allSatisfy({ $0.frames >= 0 && $0.sampleRate.isFinite && $0.sampleRate > 0
                  && $0.start.isFinite && $0.start >= 0 && $0.end.isFinite && $0.end < 1e10 }) else {
            throw BatchTranscriptionError.invalid("录音时长或时间位置无效，无法估算费用。")
        }
        self.inputs = inputs.filter { $0.frames > 0 }.sorted { $0.start < $1.start }
        var ranges: [(start: Double, end: Double)] = []
        for input in self.inputs {
            if let last = ranges.last, input.start <= last.end + 1 / 16_000 {
                ranges[ranges.count - 1].end = max(last.end, input.end)
            } else { ranges.append((input.start, input.end)) }
        }
        var slices: [RecordingAudioSlice] = []
        for range in ranges {
            var start = range.start
            while range.end - start > 0.5 / 16_000 {
                guard slices.count < 4096 else { throw BatchTranscriptionError.invalid("录音分段过多，无法创建复核任务。") }
                let end = min(range.end, start + maximumSliceSeconds)
                slices.append(.init(start: start, duration: end - start,
                    inputs: self.inputs.filter { $0.end > start && $0.start < end }))
                start = end
            }
        }
        self.slices = slices
    }
}

public enum BatchSubmissionState: String, Codable, Sendable { case submitting, submitted }

public extension AppSettings {
    var effectiveReviewProvider: RecordingReviewProvider { recordingReviewProvider ?? .transcribe }
    var effectiveReviewSettings: RecordingReviewSettings { recordingReviewSettings ?? .init() }
    func validateReviewConfiguration() throws {
        guard effectiveReviewProvider == .doubao else { return }
        guard [.mixed, .chinese, .english, .japanese].contains(language) else {
            throw BatchTranscriptionError.invalid("豆包录音文件识别暂支持中文、英文、中英混合和日语；英日混合请使用 AWS Transcribe。")
        }
        let price = effectiveReviewSettings.pricePerHour
        guard price.isFinite, price >= 0 else { throw BatchTranscriptionError.invalid("录音复核估算单价无效。") }
    }
}
