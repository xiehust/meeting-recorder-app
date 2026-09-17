import Foundation
import Testing
import MeetingCore
@testable import MeetingCloud

private func fixture() throws -> BatchTranscriptionVersion {
    var meeting = Meeting(title: "Fixture", applicationName: "", bundleID: "", microphoneName: "", settings: .init())
    meeting.status = .pending
    var chunk = AudioChunk(source: .application, relativePath: "fixture.caf", start: 4)
    chunk.audioStart = 10
    meeting.audioChunks = [chunk]
    return try BatchTranscriptionVersion(meeting: meeting, settings: meeting.settings, bucket: "fixture-bucket")
}
private func document(_ job: BatchTranscriptionJob, wrongJob: Bool = false) -> Data {
    Data("""
    {"jobName":"\(wrongJob ? "other" : job.name)","status":"COMPLETED","results":{
      "transcripts":[{"transcript":"Hello AWS. 你好。"}],
      "items":[
        {"type":"pronunciation","start_time":"0.0","end_time":"0.4","alternatives":[{"content":"Hello"}]},
        {"type":"pronunciation","start_time":"0.5","end_time":"1.0","alternatives":[{"content":"AWS"}]},
        {"type":"punctuation","alternatives":[{"content":"."}]},
        {"type":"pronunciation","start_time":"2.0","end_time":"2.3","speaker_label":"spk_1","alternatives":[{"content":"你"}]},
        {"type":"pronunciation","start_time":"2.4","end_time":"2.7","speaker_label":"spk_1","alternatives":[{"content":"好"}]},
        {"type":"punctuation","alternatives":[{"content":"。"}]}],
      "speaker_labels":{"segments":[{"speaker_label":"spk_0","items":[
        {"start_time":"0.0","end_time":"0.4"},{"start_time":"0.5","end_time":"1.0"}]}]}}}
    """.utf8)
}
private actor FakeBatchRemote: BatchTranscriptionRemote {
    var calls: [String] = []
    var states: [RemoteBatchState]
    var failClean = false
    init(_ states: [RemoteBatchState], failClean: Bool = false) { self.states = states; self.failClean = failClean }
    func checkBucket(_ bucket: String) { calls.append("bucket") }
    func state(_ job: BatchTranscriptionJob) -> RemoteBatchState {
        calls.append("get"); return states.count > 1 ? states.removeFirst() : states[0]
    }
    func upload(_ file: URL, job: BatchTranscriptionJob, bucket: String) { calls.append("upload") }
    func submit(_ job: BatchTranscriptionJob, version: BatchTranscriptionVersion) { calls.append("submit") }
    func result(_ job: BatchTranscriptionJob, bucket: String) -> Data { calls.append("result"); return document(job) }
    func clean(_ job: BatchTranscriptionJob, bucket: String) throws {
        calls.append("clean"); if failClean { throw BatchTranscriptionError.invalid("cleanup denied") }
    }
}
private actor BatchUpdates {
    var versions: [BatchTranscriptionVersion] = []
    func append(_ version: BatchTranscriptionVersion) { versions.append(version) }
}

@Test func batchParserPreservesOffsetPunctuationAndSpeakerChanges() throws {
    let job = try fixture().jobs[0]
    let segments = try BatchTranscriptParser.parse(document(job), job: job)
    #expect(segments.count == 2)
    #expect(segments[0].originalText == "Hello AWS.")
    #expect(segments[1].originalText == "你好。")
    #expect(segments[0].start == 10)
    #expect(segments[1].end == 12.7)
    #expect(segments[0].originalSpeakerID != segments[1].originalSpeakerID)
    #expect(throws: BatchTranscriptionError.self) { try BatchTranscriptParser.parse(document(job, wrongJob: true), job: job) }
}

@Test func batchRequestUsesLanguageSpecificVocabularyAndSeparateMicIdentity() throws {
    let base = try fixture()
    var meeting = Meeting(title: "", applicationName: "", bundleID: "", microphoneName: "", settings: .init())
    meeting.status = .pending; meeting.audioChunks = [base.jobs[0].chunk]
    var settings = AppSettings()
    settings.transcriptionVocabulary = .init(scope: .init(profile: "default", region: "us-west-2"),
        bindings: [.init(language: .english, name: "english-vocab", digest: "1", entryCount: 4),
                   .init(language: .chinese, name: "chinese-vocab", digest: "2", entryCount: 3)])
    let mixed = try BatchTranscriptionVersion(meeting: meeting, settings: settings, bucket: "fixture-bucket")
    let mixedInput = AWSBatchTranscriptionRemote.input(mixed.jobs[0], version: mixed)
    #expect(mixedInput.identifyMultipleLanguages == true)
    #expect(mixedInput.languageIdSettings?["en-US"]?.vocabularyName == "english-vocab")
    #expect(mixedInput.settings?.vocabularyName == nil)
    #expect(mixedInput.settings?.showSpeakerLabels == true)
    settings.language = .english
    meeting.audioChunks = [.init(source: .microphone, relativePath: "mic.caf", start: 30)]
    let fixed = try BatchTranscriptionVersion(meeting: meeting, settings: settings, bucket: "fixture-bucket")
    let fixedInput = AWSBatchTranscriptionRemote.input(fixed.jobs[0], version: fixed)
    #expect(fixedInput.settings?.vocabularyName == "english-vocab")
    #expect(fixedInput.identifyMultipleLanguages == nil)
    #expect(fixedInput.settings?.showSpeakerLabels == false)
    #expect(fixedInput.outputKey == fixed.jobs[0].outputKey)
    #expect(try BatchTranscriptParser.parse(document(fixed.jobs[0]), job: fixed.jobs[0]).allSatisfy { $0.originalSpeakerID == "me" })
}

@Test func batchResumesExistingJobWithoutUploadingAndSavesBeforeCleanup() async throws {
    let remote = FakeBatchRemote([.running, .completed])
    let updates = BatchUpdates()
    try await BatchTranscriptionService(remote: remote, pollDelay: .zero).run(version: fixture(),
        prepare: { _ in throw BatchTranscriptionError.invalid("Must not upload") },
        receive: { version in
            if version.jobs[0].segments != nil, !version.jobs[0].cloudCleaned {
                #expect(await remote.calls.contains("clean") == false)
            }
            await updates.append(version)
        })
    #expect(await remote.calls == ["bucket", "get", "get", "result", "clean"])
    #expect(await updates.versions.last?.state == .ready)
}

@Test func batchStorageFailurePreventsCloudCleanup() async throws {
    let remote = FakeBatchRemote([.completed])
    await #expect(throws: StorageError.self) {
        try await BatchTranscriptionService(remote: remote).run(version: fixture(), prepare: { _ in nil }) { version in
            if version.jobs[0].segments != nil { throw StorageError.operation("disk full") }
        }
    }
    #expect(await remote.calls == ["bucket", "get", "result"])
}

@Test func batchKeepsReadyResultWhenCleanupFailsAndSkipsSavedChunksOnResume() async throws {
    let remote = FakeBatchRemote([.completed], failClean: true)
    let updates = BatchUpdates()
    try await BatchTranscriptionService(remote: remote).run(version: fixture(), prepare: { _ in nil }) { await updates.append($0) }
    let saved = try #require(await updates.versions.last)
    #expect(saved.state == .ready)
    #expect(!saved.jobs[0].cloudCleaned)
    let second = FakeBatchRemote([.missing])
    try await BatchTranscriptionService(remote: second).run(version: saved, prepare: { _ in nil }) { _ in }
    #expect(await second.calls == ["bucket"])
}

@Test func batchWaitIsBoundedAndFailedJobsDoNotSilentlyResubmit() async throws {
    for state in [RemoteBatchState.running, .failed] {
        let remote = FakeBatchRemote([state])
        await #expect(throws: BatchTranscriptionError.self) {
            try await BatchTranscriptionService(remote: remote, pollLimit: 2, pollDelay: .zero)
                .run(version: fixture(), prepare: { _ in nil }) { _ in }
        }
        #expect(await remote.calls.contains("submit") == false)
    }
}

@Test func batchCancellationDoesNotSubmitOrDeleteCloudData() async throws {
    let remote = FakeBatchRemote([.missing])
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await BatchTranscriptionService(remote: remote).run(version: fixture(), prepare: { _ in nil }) { _ in }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await remote.calls.contains("upload") == false)
    #expect(await remote.calls.contains("clean") == false)
}
