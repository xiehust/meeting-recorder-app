import Foundation
import MeetingCore

public enum RemoteBatchState: Sendable { case missing, running, completed, failed }
public protocol BatchTranscriptionRemote: Sendable {
    func checkBucket(_ bucket: String) async throws
    func state(_ job: BatchTranscriptionJob) async throws -> RemoteBatchState
    func upload(_ file: URL, job: BatchTranscriptionJob, bucket: String) async throws
    func prepareSubmission(_ job: BatchTranscriptionJob, version: BatchTranscriptionVersion) async throws
    func submit(_ job: BatchTranscriptionJob, version: BatchTranscriptionVersion) async throws
    func result(_ job: BatchTranscriptionJob, bucket: String) async throws -> Data
    func clean(_ job: BatchTranscriptionJob, bucket: String) async throws
    func parseResult(_ data: Data, job: BatchTranscriptionJob) async throws -> [TranscriptSegment]
}

public extension BatchTranscriptionRemote {
    func prepareSubmission(_ job: BatchTranscriptionJob, version: BatchTranscriptionVersion) async throws {}
    func parseResult(_ data: Data, job: BatchTranscriptionJob) async throws -> [TranscriptSegment] { try BatchTranscriptParser.parse(data, job: job) }
}

public struct BatchTranscriptionService: Sendable {
    let remote: any BatchTranscriptionRemote
    let pollLimit: Int
    let pollDelay: Duration
    public init(remote: any BatchTranscriptionRemote, pollLimit: Int = 720, pollDelay: Duration = .seconds(5)) {
        self.remote = remote; self.pollLimit = pollLimit; self.pollDelay = pollDelay
    }
    public func run(version: BatchTranscriptionVersion,
                    prepare: @Sendable (AudioChunk) async throws -> URL?,
                    receive: @Sendable (BatchTranscriptionVersion) async throws -> Void) async throws {
        var version = version
        version.state = .running
        try Task.checkCancellation()
        try await remote.checkBucket(version.bucket)
        for index in version.jobs.indices {
            try Task.checkCancellation()
            guard version.jobs[index].segments == nil else { continue }
            let job = version.jobs[index]
            version.message = "批量转录 \(index + 1)/\(version.jobs.count) · \(job.chunk.source.title)"
            try await receive(version) // Persist identifiers before uploading or submitting.
            let state = try await remote.state(job)
            if state == .failed {
                throw BatchTranscriptionError.invalid("AWS 任务失败。请在 AWS 控制台查看该任务原因；修正配置后创建新版本。任务：\(job.name)")
            }
            if state == .missing {
                version.jobs[index].cloudCleaned = false
                try await receive(version)
                guard let file = try await prepare(job.chunk) else {
                    version.jobs[index].segments = []
                    version.jobs[index].cloudCleaned = true
                    try await receive(version)
                    continue
                }
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                try await remote.upload(file, job: job, bucket: version.bucket)
                try await remote.prepareSubmission(job, version: version)
                try Task.checkCancellation()
                version.jobs[index].submission = .submitting
                version.jobs[index].submittedSeconds = job.mixedAudio.map { Double(Int64(($0.duration * 16000).rounded())) / 16000 }
                try await receive(version) // Persist uncertainty before a possibly accepted, interrupted POST.
                try await remote.submit(version.jobs[index], version: version)
                version.jobs[index].submission = .submitted
                try await receive(version)
            }
            var completed = state == .completed
            for _ in 0..<pollLimit where !completed {
                try Task.checkCancellation()
                let current = try await remote.state(version.jobs[index])
                if current == .completed { completed = true; break }
                if current == .failed { throw BatchTranscriptionError.invalid("AWS 批量任务失败，请查看任务 \(job.name) 的失败原因。可修正配置后创建新版本。") }
                try await Task.sleep(for: pollDelay)
            }
            guard completed else { throw BatchTranscriptionError.invalid("识别服务仍在处理录音。稍后点击“继续任务”复用已提交的任务。") }
            let data = try await remote.result(job, bucket: version.bucket)
            version.jobs[index].segments = try await remote.parseResult(data, job: job)
            // Cloud files are only removed after the local transcript has been durably saved.
            try await receive(version)
            do {
                try await remote.clean(job, bucket: version.bucket)
                version.jobs[index].cloudCleaned = true
            } catch { /* Retain cleanup metadata; a separate user action can retry. */ }
            try await receive(version)
        }
        try Task.checkCancellation()
        version.state = .ready
        version.message = version.segments.isEmpty ? "录音处理完成，未识别到发言。" : "批量结果已保存，请复核后采用。"
        if version.jobs.contains(where: { !$0.cloudCleaned }) { version.message += " 部分云端文件未清理，可重试清理。" }
        try await receive(version)
    }
}
