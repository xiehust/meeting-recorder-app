import Foundation
import Testing
@testable import MeetingCore

private func chatMeeting() throws -> Meeting {
    var meeting = Meeting(title: "Chat", applicationName: "Test", bundleID: "", microphoneName: "", settings: .init())
    try meeting.ingest(.init(sessionID: "test", resultID: "one", source: .mixed, start: 3, end: 7, text: "原文待确认", speakerID: "speaker"))
    meeting.status = .pending
    meeting.minuteVersions = [.init(input: .init(meeting: meeting), correctionVersionID: nil, configuration: .init(), profile: "default",
        minutes: .init(overview: "旧纪要内容", topics: [], decisions: [], actions: [], questions: [], limitations: []), invocation: nil)]
    return meeting
}

@Test func chatScopesSeparateOriginalRevisionsAndMinutes() throws {
    var meeting = try chatMeeting()
    try meeting.edit(segmentID: meeting.segments[0].id, text: "人工修订")
    let original = MeetingChatContext(meeting: meeting, scope: .original)
    #expect(original.sources.map(\.text) == ["原文待确认"])
    #expect(original.minutesVersionID == nil)
    let all = MeetingChatContext(meeting: meeting, scope: .all)
    #expect(all.sources.contains { $0.kind == .reviewed && $0.text == "人工修订" })
    #expect(all.sources.contains { $0.kind == .minutes && $0.text.contains("旧纪要内容") })
    #expect(all.minutesAreStale)
    let minutes = MeetingChatContext(meeting: meeting, scope: .minutes)
    #expect(minutes.sources.allSatisfy { $0.kind == .minutes })
    #expect(!minutes.sources.contains { $0.text.contains("原文待确认") })
    // A different meeting never enters the context.
    let other = Meeting(title: "Unrelated", applicationName: "", bundleID: "", microphoneName: "", settings: .init())
    #expect(MeetingChatContext(meeting: other, scope: .all).sources.isEmpty)
}

@Test func importedTranscriptAdoptionFeedsProofreadingExportAndChat() throws {
    var meeting = Meeting(title: "File", applicationName: "导入录音", bundleID: "", microphoneName: "", settings: .init())
    meeting.status = .pending
    meeting.importedRecording = .init(fileName: "file.mp3", duration: 10)
    meeting.audioChunks = [.init(source: .mixed, relativePath: "audio.caf", start: 0)]
    var version = try BatchTranscriptionVersion(meeting: meeting, settings: meeting.settings, bucket: "test-bucket")
    version.jobs[0].segments = [.init(sessionID: "batch", resultID: "1", source: .mixed, start: 0, end: 10, text: "录音转录结果", speakerID: "batch/1")]
    version.state = .ready; meeting.batchVersions = [version]
    #expect(meeting.workingSegments.isEmpty)
    #expect(meeting.originalSegments == version.segments)
    try meeting.selectTranscript(batchVersionID: version.id)
    #expect(AIInputSnapshot(meeting: meeting).segments.first?.text == "录音转录结果")
    #expect(MeetingChatContext(meeting: meeting, scope: .original).sources.first?.text == "录音转录结果")
    try meeting.edit(segmentID: version.segments[0].id, text: "人工修改结果")
    let originalExport = MeetingExport.transcript(meeting, original: true, format: .text, includeNotes: false)
    #expect(originalExport.contains("录音转录结果") && !originalExport.contains("人工修改结果"))
    #expect(meeting.segments.isEmpty)
}

@Test func chatPersistsEvidenceAndRecoversInterruptedTurnsWithoutChangingTranscript() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try MeetingRepository(directory: root)
    var meeting = try chatMeeting()
    let context = MeetingChatContext(meeting: meeting, scope: .all)
    var done = MeetingChatTurn(question: "什么待确认？", context: context)
    done.state = .completed; done.answer = "原文待确认 [O1]"
    done.citations = [.init(source: context.sources[0], quote: "原文待确认")]
    meeting.chatTurns = [done, .init(question: "继续", context: context)]
    try await repository.save(meeting)
    let recovered = try #require(try await repository.loadAll(recover: true).first)
    #expect(recovered.chatTurns?[0].answer == done.answer)
    #expect(recovered.chatTurns?[0].citations[0].source.text == "原文待确认")
    #expect(recovered.chatTurns?[1].state == .cancelled)
    #expect(recovered.segments == meeting.segments && recovered.revision == meeting.revision)
    try meeting.edit(segmentID: meeting.segments[0].id, text: "改变后的文本")
    #expect(done.isStale(in: meeting))
    #expect(done.citations[0].source.text == "原文待确认")
}

@Test func legacyMeetingDecodesWithoutImportOrChatFields() throws {
    let meeting = try chatMeeting()
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
    object.removeValue(forKey: "chatTurns"); object.removeValue(forKey: "importedRecording")
    let decoded = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.chatTurns == nil && decoded.importedRecording == nil)
    #expect(decoded.originalSegments == meeting.sortedSegments)
}
