import Foundation
import Testing
import MeetingCore
@testable import MeetingCloud

private func recordingVersion() throws -> BatchTranscriptionVersion {
    var settings = AppSettings(); settings.recordingReviewProvider = .doubao
    var meeting = Meeting(title: "fixture", applicationName: "", bundleID: "", microphoneName: "", settings: settings)
    meeting.status = .pending
    let chunk = AudioChunk(source: .application, relativePath: "file.caf", start: 30)
    meeting.audioChunks = [chunk]
    let plan = try RecordingAudioPlan(inputs: [.init(chunk: chunk, frames: 32000, sampleRate: 16000)])
    return try BatchTranscriptionVersion(meeting: meeting, settings: settings, bucket: "test-bucket", audioPlan: plan)
}
private let recordingJSON = Data(#"{"audio_info":{"duration":2000},"result":{"text":"测试文本","utterances":[{"text":"测试文本","end_time":1800,"additions":{"speaker_id":"0"}}]}}"#.utf8)

private actor RecordingAPIStub: DoubaoRecordingAPI {
    var responses: [DoubaoRecordingResult]
    var submitted = 0
    let failSubmit: Bool
    init(_ responses: [DoubaoRecordingResult], failSubmit: Bool = false) { self.responses = responses; self.failSubmit = failSubmit }
    func submit(id: String, audioURL: URL, settings: AppSettings) throws {
        submitted += 1
        if failSubmit { throw BatchTranscriptionError.invalid("transport interrupted") }
    }
    func query(id: String) -> DoubaoRecordingResult { responses.count > 1 ? responses.removeFirst() : responses[0] }
}
private actor ReviewStorageStub: ReviewAudioStorage {
    var calls: [String] = []
    let failPresign: Bool
    init(failPresign: Bool = false) { self.failPresign = failPresign }
    func checkBucket(_ bucket: String) { calls.append("bucket") }
    func upload(_ file: URL, bucket: String, key: String) { calls.append("upload") }
    func downloadURL(bucket: String, key: String) throws -> URL {
        calls.append("presign")
        if failPresign { throw BatchTranscriptionError.invalid("S3 read denied") }
        return URL(string: "https://example.test/audio?signature=temporary-secret")!
    }
    func remove(bucket: String, key: String) { calls.append("remove") }
}
private actor RecordingReceipts {
    var latest: BatchTranscriptionVersion?
    func save(_ version: BatchTranscriptionVersion) { latest = version }
}

@Test func recordingTaskPersistsSubmissionAndResultBeforeCleanup() async throws {
    let api = RecordingAPIStub([.missing, .completed(recordingJSON)])
    let storage = ReviewStorageStub(), receipts = RecordingReceipts()
    let remote = DoubaoBatchTranscriptionRemote(api: api, storage: storage)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1, 2, 3]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    try await BatchTranscriptionService(remote: remote, pollDelay: .zero).run(version: recordingVersion(), prepare: { _ in file }) { version in
        if version.jobs[0].submission == .submitting { #expect(await api.submitted == 0) }
        if version.jobs[0].segments != nil, !version.jobs[0].cloudCleaned { #expect(await !storage.calls.contains("remove")) }
        await receipts.save(version)
    }
    let version = try #require(await receipts.latest)
    #expect(version.state == .ready && version.jobs[0].cloudCleaned)
    #expect(version.segments[0].start == 30 && version.segments[0].end == 31.8)
    #expect(version.segments[0].source == .mixed)
    #expect(await api.submitted == 1)
    let json = String(decoding: try JSONEncoder().encode(version), as: UTF8.self)
    #expect(!json.contains("temporary-secret"))
}

@Test func uncertainRecordingSubmissionNeverAutomaticallyResubmitsWhenQueryIsMissing() async throws {
    let receipts = RecordingReceipts(), storage = ReviewStorageStub()
    let api = RecordingAPIStub([.missing], failSubmit: true)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    await #expect(throws: BatchTranscriptionError.self) {
        try await BatchTranscriptionService(remote: DoubaoBatchTranscriptionRemote(api: api, storage: storage))
            .run(version: recordingVersion(), prepare: { _ in file }) { await receipts.save($0) }
    }
    let version = try #require(await receipts.latest)
    #expect(version.jobs[0].submission == .submitting)
    let retryAPI = RecordingAPIStub([.missing]), retryStorage = ReviewStorageStub()
    await #expect(throws: BatchTranscriptionError.self) {
        try await BatchTranscriptionService(remote: DoubaoBatchTranscriptionRemote(api: retryAPI, storage: retryStorage))
            .run(version: version, prepare: { _ in Issue.record("must not prepare again"); return nil }) { _ in }
    }
    #expect(await retryAPI.submitted == 0)
    #expect(await !retryStorage.calls.contains("upload"))
}

@Test func recordingRequestsUseFileModelAndDoNotSmoothOrDisableSpeakers() throws {
    let version = try recordingVersion()
    let data = try DoubaoRecordingClient.submissionBody(id: "test", audioURL: URL(string: "https://example.test/audio?signature=test")!, settings: version.settings)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let request = try #require(object["request"] as? [String: Any])
    #expect(DoubaoRecordingClient.resource == "volc.seedasr.auc")
    #expect(request["enable_speaker_info"] as? Bool == true)
    #expect(request["enable_ddc"] as? Bool == false)
    #expect(request["show_utterances"] as? Bool == true)
    #expect(request["ssd_version"] as? String == "200")
}

@Test func presignFailureDoesNotMarkTheRecognitionTaskAsPossiblySubmitted() async throws {
    let api = RecordingAPIStub([.missing]), receipts = RecordingReceipts()
    let remote = DoubaoBatchTranscriptionRemote(api: api, storage: ReviewStorageStub(failPresign: true))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    await #expect(throws: BatchTranscriptionError.self) {
        try await BatchTranscriptionService(remote: remote).run(version: recordingVersion(), prepare: { _ in file }) { await receipts.save($0) }
    }
    #expect(await receipts.latest?.jobs[0].submission == nil)
    #expect(await api.submitted == 0)
}

@Test func recordingQueryDistinguishesMissingTasksFromAuthorizationErrors() throws {
    func response(_ status: Int, _ message: String) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.test/query")!, statusCode: status, httpVersion: nil,
            headerFields: ["X-Api-Status-Code": "45000001", "X-Api-Message": message])!
    }
    if case .missing = try DoubaoRecordingClient.queryResult(Data(), response: response(200, "request_id not found")) {} else { Issue.record("expected missing") }
    #expect(throws: BatchTranscriptionError.self) { try DoubaoRecordingClient.queryResult(Data(), response: response(403, "request_id not found")) }
    #expect(throws: BatchTranscriptionError.self) { try DoubaoRecordingClient.queryResult(Data(), response: response(200, "resource not found")) }
    let error = DoubaoRecordingClient.failure(response(403, "secret https://example.test/?signature=private"))
    #expect(!error.localizedDescription.contains("signature") && !error.localizedDescription.contains("secret"))
}

@Test func recordingQueryRecognizesActualMissingTaskResponseWithoutBypassingAuthorization() throws {
    let message = "[Client-side generic error] OperatorWrapper Process failed: cannot find task"
    func response(_ status: Int, message: String) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.test/query")!, statusCode: status, httpVersion: nil,
            headerFields: ["X-Api-Status-Code": "45000000", "X-Api-Message": message])!
    }
    if case .missing = try DoubaoRecordingClient.queryResult(Data("{}".utf8), response: response(200, message: message)) {}
    else { Issue.record("A never-submitted task must be recognized as missing") }
    for status in [401, 403, 500] {
        #expect(throws: BatchTranscriptionError.self) {
            try DoubaoRecordingClient.queryResult(Data(), response: response(status, message: message))
        }
    }
    #expect(throws: BatchTranscriptionError.self) {
        try DoubaoRecordingClient.queryResult(Data(), response: response(200, message: "invalid audio parameter"))
    }
    let failure = DoubaoRecordingClient.failure(response(200, message: "invalid audio parameter"))
    #expect(failure.localizedDescription.contains("不能单独判断"))
}
