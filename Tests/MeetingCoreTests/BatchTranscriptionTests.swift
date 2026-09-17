import Foundation
import Testing
@testable import MeetingCore

private func batchMeeting() throws -> Meeting {
    var meeting = Meeting(title: "Fixture", applicationName: "Teams", bundleID: "", microphoneName: "Mic", settings: .init())
    try meeting.ingest(.init(sessionID: "live", resultID: "1", source: .application, start: 1, end: 3,
        text: "live original", speakerID: "live-person"))
    meeting.status = .pending
    meeting.audioChunks = [.init(source: .application, relativePath: "audio.caf", start: 0)]
    return meeting
}
private func readyVersion(_ meeting: Meeting) throws -> BatchTranscriptionVersion {
    var version = try BatchTranscriptionVersion(meeting: meeting, settings: meeting.settings, bucket: "fixture-bucket")
    version.jobs[0].segments = [.init(sessionID: version.jobs[0].name, resultID: "0", source: .application,
        start: 1, end: 3, text: "batch original", speakerID: "batch/person")]
    version.state = .ready
    return version
}

@Test func batchAdoptionChangesAIInputWithoutChangingLiveOriginalOrEdits() throws {
    var meeting = try batchMeeting()
    let original = try #require(meeting.segments.first)
    try meeting.edit(segmentID: original.id, text: "human live correction")
    let version = try readyVersion(meeting)
    meeting.batchVersions = [version]
    let revision = meeting.revision
    try meeting.selectTranscript(batchVersionID: version.id)
    #expect(meeting.segments == [original])
    #expect(meeting.text(for: original) == "human live correction")
    #expect(meeting.revision == revision + 1)
    #expect(AIInputSnapshot(meeting: meeting).segments.first?.text == "batch original")
    let batch = try #require(meeting.workingSegments.first)
    try meeting.edit(segmentID: batch.id, text: "human batch correction")
    #expect(AIInputSnapshot(meeting: meeting).segments.first?.humanProtected == true)
    #expect(AIInputSnapshot(meeting: meeting).segments.first?.text == "human batch correction")
    #expect(MeetingExport.transcript(meeting, original: true, format: .markdown, includeNotes: true).contains("live original"))
    #expect(!MeetingExport.transcript(meeting, original: true, format: .markdown, includeNotes: true).contains("batch original"))
    try meeting.selectTranscript(batchVersionID: nil)
    #expect(AIInputSnapshot(meeting: meeting).segments.first?.text == "human live correction")
    #expect(meeting.batchVersions?.first?.segments.first?.originalText == "batch original")
}

@Test func incompleteOrEmptyBatchCannotReplaceTranscript() throws {
    var meeting = try batchMeeting()
    var version = try readyVersion(meeting)
    version.state = .failed; meeting.batchVersions = [version]
    #expect(throws: BatchTranscriptionError.self) { try meeting.selectTranscript(batchVersionID: version.id) }
    version.state = .ready; version.jobs[0].segments = []; meeting.batchVersions = [version]
    #expect(throws: BatchTranscriptionError.self) { try meeting.selectTranscript(batchVersionID: version.id) }
    #expect(meeting.selectedBatchVersionID == nil)
}

@Test func legacyMeetingAndSettingsDecodeWithoutEnablingBatch() throws {
    let meeting = try batchMeeting()
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
    json.removeValue(forKey: "batchVersions"); json.removeValue(forKey: "selectedBatchVersionID")
    let decoded = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.settings.automaticBatchTranscription == nil)
    #expect(decoded.workingSegments == meeting.segments)
}

@Test func automaticBatchWaitsForReviewBeforeAIAndCanRecoverFailedStreaming() throws {
    var meeting = try batchMeeting()
    #expect(meeting.postRecordingAction == .generateMinutes)
    meeting.settings.automaticBatchTranscription = true
    #expect(meeting.postRecordingAction == .batchReview)
    meeting.settings.automaticallyGenerateMinutes = false
    meeting.status = .failed
    #expect(meeting.postRecordingAction == .batchReview)
    meeting.status = .recording
    #expect(meeting.postRecordingAction == .none)
    meeting.status = .pending; meeting.settings.automaticBatchTranscription = false
    #expect(meeting.postRecordingAction == .none)
}

@Test func batchRecoveryPreservesCompletedChunksAndDoesNotStartAI() throws {
    var meeting = try batchMeeting()
    var version = try readyVersion(meeting); version.state = .running
    meeting.batchVersions = [version]; meeting.status = .retranscribing
    meeting.recoverInterrupted()
    #expect(meeting.status == .pending)
    #expect(meeting.batchVersions?.first?.state == .interrupted)
    #expect(meeting.batchVersions?.first?.segments.count == 1)
    #expect(meeting.aiTask == nil)
}

@Test func repositoryProtectsBatchOriginalsAndRoundTripsChosenSource() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try MeetingRepository(directory: directory)
    var meeting = try batchMeeting(); let version = try readyVersion(meeting)
    meeting.batchVersions = [version]; try meeting.selectTranscript(batchVersionID: version.id)
    try await repository.save(meeting)
    let restored = try #require(try await repository.loadAll().first)
    #expect(restored.selectedBatchVersionID == version.id)
    #expect(restored.workingSegments == version.segments)
    let segment = try #require(version.segments.first)
    meeting.batchVersions?[0].jobs[0].segments = [.init(sessionID: segment.sessionID, resultID: segment.resultID,
        source: segment.source, start: segment.start, end: segment.end, text: "tampered", speakerID: segment.originalSpeakerID)]
    await #expect(throws: MeetingError.self) { try await repository.save(meeting) }
    #expect(try await repository.loadAll().first?.workingSegments.first?.originalText == "batch original")
}
