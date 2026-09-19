import Foundation
import MeetingCore
import MeetingAudio
import MeetingCloud

extension AppStore {
    var batchBucket: String {
        let configured = settings.batchTranscriptionBucket?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? vocabularyLibrary.bucket.trimmingCharacters(in: .whitespacesAndNewlines) : configured
    }

    func batchConfiguration(for meeting: Meeting, useVocabulary: Bool, provider: RecordingReviewProvider? = nil) throws -> AppSettings {
        var configuration = meeting.settings
        configuration.profile = settings.profile
        configuration.transcribeRegion = settings.transcribeRegion
        configuration.recordingReviewProvider = provider ?? settings.effectiveReviewProvider
        configuration.recordingReviewSettings = settings.effectiveReviewSettings
        if configuration.effectiveReviewProvider == .doubao {
            configuration.transcriptionVocabulary = nil
            var review = configuration.effectiveReviewSettings
            review.hotwords = useVocabulary ? recordingHotwords(language: meeting.settings.language) : []
            configuration.recordingReviewSettings = review
        } else {
            configuration.transcriptionVocabulary = useVocabulary
                ? try vocabularyLibrary.snapshot(language: meeting.settings.language, scope: vocabularyScope) : nil
        }
        try configuration.validateReviewConfiguration()
        return configuration
    }

    func startBatch(meetingID: UUID, configuration: AppSettings, bucket: String) {
        guard !isProcessing(meetingID), let meeting = meetings.first(where: { $0.id == meetingID }),
              !meeting.status.isActive else { return }
        batchTasks[meetingID] = Task {
            do {
                let plan = try await reviewAudioPlan(meeting)
                try Task.checkCancellation()
                let version = try BatchTranscriptionVersion(meeting: meeting, settings: configuration,
                    bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
                    audioPlan: configuration.effectiveReviewProvider == .doubao ? plan : nil)
                batchTasks[meetingID] = nil
                runBatch(meetingID: meetingID, version: version)
            } catch {
                batchTasks[meetingID] = nil
                if !Task.isCancelled { self.error = batchMessage(error) }
                objectWillChange.send()
            }
        }
        objectWillChange.send()
    }

    func reviewAudioPlan(_ meeting: Meeting) async throws -> RecordingAudioPlan {
        let directory = directory
        let worker = Task.detached { try RecordingReviewAudio.plan(meeting: meeting, directory: directory) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func batchRemote(_ version: BatchTranscriptionVersion, needsKey: Bool = true) async throws -> any BatchTranscriptionRemote {
        let scope = VocabularyScope(profile: version.settings.profile, region: version.settings.transcribeRegion)
        if version.effectiveProvider == .doubao {
            let key = needsKey ? (try DoubaoKeychain.read() ?? "") : ""
            if needsKey && key.isEmpty { throw SpeechConfigurationError.missingKey }
            return DoubaoBatchTranscriptionRemote(api: DoubaoRecordingClient(apiKey: key), storage: try await S3ReviewAudioStorage(scope: scope))
        }
        return try await AWSBatchTranscriptionRemote(scope: scope)
    }

    func resumeBatch(meetingID: UUID, version: BatchTranscriptionVersion) {
        guard !isProcessing(meetingID), version.state != .ready,
              meetings.first(where: { $0.id == meetingID })?.status.isActive == false else { return }
        runBatch(meetingID: meetingID, version: version)
    }

    private func runBatch(meetingID: UUID, version: BatchTranscriptionVersion) {
        let directory = directory
        batchTasks[meetingID] = Task { [weak self] in
            guard let self else { return }
            defer { batchTasks.removeValue(forKey: meetingID); objectWillChange.send() }
            do {
                var starting = version; starting.state = .running
                try await saveBatch(starting, meetingID: meetingID)
                let scope = VocabularyScope(profile: version.settings.profile, region: version.settings.transcribeRegion)
                if version.effectiveProvider == .transcribe, let vocabulary = version.settings.transcriptionVocabulary, version.jobs.contains(where: { $0.segments == nil }) {
                    try await VocabularyService(remote: AWSVocabularyRemote(scope: scope)).verifyReady(vocabulary)
                }
                let remote = try await batchRemote(version)
                let work = directory.appendingPathComponent("BatchWork/\(version.id.uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: work) }
                try await BatchTranscriptionService(remote: remote).run(version: version, prepare: { chunk in
                    // Run conversion away from the UI actor, propagating cancellation into the worker.
                    let task = Task.detached {
                        let output = work.appendingPathComponent("\(chunk.id.uuidString).wav")
                        if let slice = version.jobs.first(where: { $0.chunk.id == chunk.id })?.mixedAudio {
                            return try RecordingReviewAudio.prepare(slice, meetingID: meetingID, directory: directory, output: output)
                        }
                        return try BatchAudioPreparer.prepare(chunk, meetingID: meetingID, directory: directory, output: output)
                    }
                    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                }, receive: { [weak self] update in
                    try Task.checkCancellation()
                    try await self?.saveBatch(update, meetingID: meetingID)
                })
            } catch {
                if var failed = meetings.first(where: { $0.id == meetingID })?.batchVersions?.first(where: { $0.id == version.id }) {
                    failed.state = Task.isCancelled ? .cancelled : .failed
                    failed.message = Task.isCancelled
                        ? "已停止本地等待。已提交的识别任务可能仍在运行并计费；可继续任务或稍后清理云端文件。"
                        : batchMessage(error)
                    try? await saveBatch(failed, meetingID: meetingID)
                } else { self.error = batchMessage(error) }
            }
        }
        objectWillChange.send()
    }

    private func saveBatch(_ version: BatchTranscriptionVersion, meetingID: UUID) async throws {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { throw CancellationError() }
        if meetings[index].batchVersions == nil { meetings[index].batchVersions = [] }
        if let position = meetings[index].batchVersions?.firstIndex(where: { $0.id == version.id }) {
            meetings[index].batchVersions?[position] = version
        } else { meetings[index].batchVersions?.append(version) }
        meetings[index].status = version.state == .running ? .retranscribing
            : ((meetings[index].minuteVersions?.isEmpty ?? true) ? .pending : .completed)
        meetings[index].lastSavedAt = Date()
        try await enqueueSave(meetings[index]).value
    }

    func adoptBatch(_ meetingID: UUID, versionID: UUID?, runAI: Bool = false) async {
        guard !isProcessing(meetingID), let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        do {
            try meetings[index].selectTranscript(batchVersionID: versionID)
            meetings[index].lastSavedAt = Date()
            try await enqueueSave(meetings[index]).value
            if runAI { processAI(meetingID, operation: .full) }
        } catch { self.error = error.localizedDescription }
    }

    func cleanBatch(_ meetingID: UUID, version: BatchTranscriptionVersion) {
        guard !isProcessing(meetingID), meetings.first(where: { $0.id == meetingID })?.status.isActive == false else { return }
        batchTasks[meetingID] = Task {
            defer { batchTasks.removeValue(forKey: meetingID); objectWillChange.send() }
            do {
                let remote = try await batchRemote(version, needsKey: false)
                var version = version
                for index in version.jobs.indices where !version.jobs[index].cloudCleaned {
                    try Task.checkCancellation()
                    try await remote.clean(version.jobs[index], bucket: version.bucket)
                    version.jobs[index].cloudCleaned = true
                    try await saveBatch(version, meetingID: meetingID)
                }
            } catch { self.error = batchMessage(error) }
        }
        objectWillChange.send()
    }
    private func batchMessage(_ error: Error) -> String {
        if error is BatchTranscriptionError || error is StorageError || error is VocabularyError || error is VocabularyOperationError || error is SpeechConfigurationError {
            return error.localizedDescription
        }
        return "批量转录未完成，请检查网络、识别服务凭证和录音文件。已保存的结果及原录音保留，可继续任务。"
    }
}
