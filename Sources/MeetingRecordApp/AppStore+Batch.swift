import Foundation
import MeetingCore
import MeetingAudio
import MeetingCloud

extension AppStore {
    var batchBucket: String {
        let configured = settings.batchTranscriptionBucket?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? vocabularyLibrary.bucket.trimmingCharacters(in: .whitespacesAndNewlines) : configured
    }

    func batchConfiguration(for meeting: Meeting, useVocabulary: Bool) throws -> AppSettings {
        var configuration = meeting.settings
        configuration.profile = settings.profile
        configuration.transcribeRegion = settings.transcribeRegion
        configuration.transcriptionVocabulary = useVocabulary
            ? try vocabularyLibrary.snapshot(language: meeting.settings.language, scope: vocabularyScope) : nil
        return configuration
    }

    func startBatch(meetingID: UUID, configuration: AppSettings, bucket: String) {
        guard !isProcessing(meetingID), let meeting = meetings.first(where: { $0.id == meetingID }),
              !meeting.status.isActive else { return }
        do {
            // Check every cache before the first upload; never silently drop a missing source.
            for chunk in meeting.audioChunks {
                _ = try BatchAudioPreparer.sourceURL(chunk, meetingID: meeting.id, directory: directory)
            }
            let version = try BatchTranscriptionVersion(meeting: meeting, settings: configuration,
                bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines))
            runBatch(meetingID: meetingID, version: version)
        } catch { self.error = error.localizedDescription }
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
                if let vocabulary = version.settings.transcriptionVocabulary, version.jobs.contains(where: { $0.segments == nil }) {
                    try await VocabularyService(remote: AWSVocabularyRemote(scope: scope)).verifyReady(vocabulary)
                }
                let remote = try await AWSBatchTranscriptionRemote(scope: scope)
                let work = directory.appendingPathComponent("BatchWork/\(version.id.uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: work) }
                try await BatchTranscriptionService(remote: remote).run(version: version, prepare: { chunk in
                    // Run conversion away from the UI actor, propagating cancellation into the worker.
                    let task = Task.detached {
                        try BatchAudioPreparer.prepare(chunk, meetingID: meetingID, directory: directory,
                            output: work.appendingPathComponent("\(chunk.id.uuidString).wav"))
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
                        ? "已停止本地等待。已提交的 AWS 任务可能仍在运行并计费；可继续任务或稍后清理云端文件。"
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
                let remote = try await AWSBatchTranscriptionRemote(scope: .init(profile: version.settings.profile, region: version.settings.transcribeRegion))
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
        if error is BatchTranscriptionError || error is StorageError || error is VocabularyError || error is VocabularyOperationError {
            return error.localizedDescription
        }
        return "批量转录未完成，请检查网络、AWS 凭证和录音文件。已保存的结果及原录音保留，可继续任务。"
    }
}
