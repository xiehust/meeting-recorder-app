import Foundation
import Testing
@testable import MeetingCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func meeting() -> Meeting {
    Meeting(title: "测试会议", applicationName: "Teams", bundleID: "com.microsoft.teams2",
            microphoneName: "测试麦克风", settings: AppSettings(), now: epoch)
}
private func segment(session: String = "s1", result: String = "r1", speaker: String? = nil,
                     text: String = "可能在周五发布，不是最终承诺。", start: Double = 10) -> TranscriptSegment {
    .init(sessionID: session, resultID: result, source: .application, start: start, end: start + 5,
          text: text, speakerID: speaker ?? "\(session):spk_0")
}

@Test func modelDefaultsAreExplicitAndIndependent() {
    var settings = AppSettings()
    #expect(settings.correction.model == .astra)
    #expect(settings.summary.model == .astra)
    #expect(settings.correction.reasoningEffort == "medium")
    #expect(settings.summary.reasoningEffort == "medium")
    settings.correction.model = .luna
    #expect(settings.summary.model == .astra)
    #expect(settings.language == .mixed)
    #expect(!settings.cacheAudio)
}

@Test func finalReplaysAreIdempotentAndConflictsRejected() throws {
    var value = meeting()
    #expect(try value.ingest(segment()))
    #expect(try !value.ingest(segment()))
    #expect(value.segments.count == 1)
    #expect(throws: MeetingError.self) { try value.ingest(segment(text: "无依据替换")) }
    #expect(value.segments[0].originalText == segment().originalText)
}

@Test func invalidTimelineRejected() {
    var value = meeting()
    #expect(throws: MeetingError.self) { try value.ingest(segment(start: -.infinity)) }
    #expect(throws: MeetingError.self) { try value.ingest(segment(start: -2)) }
}

@Test func reconnectDoesNotReuseSpeakerIdentity() throws {
    var value = meeting()
    try value.ingest(segment(session: "s1"))
    try value.ingest(segment(session: "s2"))
    #expect(value.segments.count == 2)
    #expect(value.speakers.count == 2)
    #expect(value.speakers[0].id != value.speakers[1].id)
}

@Test func humanEditDoesNotReplaceOriginalAndIsProtected() throws {
    var value = meeting()
    let original = segment()
    try value.ingest(original)
    try value.edit(segmentID: original.id, text: "可能在下周五发布，不是最终承诺。")
    #expect(value.segments[0].originalText == original.originalText)
    #expect(value.edits.count == 1)
    #expect(value.text(for: original) != original.originalText)
    let proposed = CorrectionProposal(segmentID: original.id, before: original.originalText,
        after: "将在周五发布。", reason: "测试不应覆盖", requiresConfirmation: false)
    #expect(throws: MeetingError.self) {
        try VersionValidation.validate([proposed], for: value, inputRevision: value.revision)
    }
}

@Test func correctionRejectsInventedSourcesMismatchesDuplicatesAndStaleInputs() throws {
    var value = meeting()
    try value.ingest(segment())
    let valid = CorrectionProposal(segmentID: segment().id, before: segment().originalText,
        after: "可能在周五发布；不是最终承诺。", reason: "标点", requiresConfirmation: false)
    try VersionValidation.validate([valid], for: value, inputRevision: value.revision)
    #expect(throws: MeetingError.self) { try VersionValidation.validate([valid, valid], for: value, inputRevision: value.revision) }
    #expect(throws: MeetingError.self) { try VersionValidation.validate([valid], for: value, inputRevision: 0) }
    var fabricated = valid; fabricated.segmentID = "fake"
    #expect(throws: MeetingError.self) { try VersionValidation.validate([fabricated], for: value, inputRevision: value.revision) }
    var mismatched = valid; mismatched.before = "别的发言"
    #expect(throws: MeetingError.self) { try VersionValidation.validate([mismatched], for: value, inputRevision: value.revision) }
}

@Test func pausePreservesWallClockGapAndRejectsInvalidTransitions() throws {
    var value = meeting()
    #expect(throws: MeetingError.self) { try value.resume(now: epoch) }
    try value.pause(now: epoch.addingTimeInterval(20))
    #expect(!value.status.isCapturing)
    #expect(throws: MeetingError.self) { try value.pause(now: epoch) }
    try value.resume(now: epoch.addingTimeInterval(70))
    #expect(value.intervals[0].start == 20)
    #expect(value.intervals[0].end == 70)
    #expect(value.offset(at: epoch.addingTimeInterval(80)) == 80)
    try value.finish(now: epoch.addingTimeInterval(100))
    #expect(value.status == .finalizing)
    #expect(value.endedAt == epoch.addingTimeInterval(100))
    #expect(throws: MeetingError.self) { try value.resume() }
}

@Test func mergeIsReversibleAndCyclesAreRejected() throws {
    var value = meeting()
    let first = segment(session: "one"), second = segment(session: "two"), third = segment(session: "three")
    try value.ingest(first); try value.ingest(second); try value.ingest(third)
    try value.mergeSpeaker(from: first.originalSpeakerID, into: second.originalSpeakerID)
    try value.mergeSpeaker(from: second.originalSpeakerID, into: third.originalSpeakerID)
    #expect(value.speakerID(for: first) == third.originalSpeakerID)
    #expect(throws: MeetingError.self) { try value.mergeSpeaker(from: third.originalSpeakerID, into: first.originalSpeakerID) }
    value.merges[0].active = false
    #expect(value.speakerID(for: first) == first.originalSpeakerID)
    #expect(first.originalSpeakerID == value.segments[0].originalSpeakerID)
}

@Test func perSegmentAssignmentDoesNotChangeOtherSegments() throws {
    var value = meeting()
    let first = segment(), second = segment(result: "r2", speaker: "s1:spk_1")
    try value.ingest(first); try value.ingest(second)
    var annotation = SegmentAnnotation(); annotation.assignedSpeakerID = second.originalSpeakerID
    value.annotations[first.id] = annotation
    #expect(value.speakerID(for: first) == second.originalSpeakerID)
    #expect(value.speakerID(for: second) == second.originalSpeakerID)
    #expect(value.segments[0].originalSpeakerID == first.originalSpeakerID)
}

@Test func exportKeepsNotesSeparateAndHonorsSelectedText() throws {
    var value = meeting()
    let source = segment()
    try value.ingest(source)
    try value.edit(segmentID: source.id, text: "人工修订正文")
    var note = SegmentAnnotation(); note.note = "这是会后想法"
    value.annotations[source.id] = note
    let raw = MeetingExport.transcript(value, original: true, format: .markdown, includeNotes: false)
    #expect(raw.contains(source.originalText))
    #expect(!raw.contains("人工修订正文"))
    #expect(!raw.contains(note.note))
    let edited = MeetingExport.transcript(value, original: false, format: .text, includeNotes: true)
    #expect(edited.contains("人工修订正文"))
    #expect(edited.contains("【人工备注】这是会后想法"))
    #expect(edited.contains("00:00:10"))
}

@Test func repositoryRecoversFinalResultsAndHumanEditsAcrossReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var value = meeting()
    try value.ingest(segment()); try value.edit(segmentID: segment().id, text: "人工修订")
    value.lastSavedAt = epoch.addingTimeInterval(45)
    let repository = try MeetingRepository(directory: directory)
    try await repository.save(value)
    let reopened = try MeetingRepository(directory: directory)
    let recovered = try await reopened.loadAll(recover: true)
    #expect(recovered.count == 1)
    #expect(recovered[0].status == .interrupted)
    #expect(recovered[0].segments[0].originalText == segment().originalText)
    #expect(recovered[0].text(for: segment()) == "人工修订")
    #expect(recovered[0].intervals.last?.start == 45)
    #expect(recovered[0].endedAt == value.lastSavedAt)
    let twice = try await reopened.loadAll(recover: true)
    #expect(twice[0].intervals.count == 1)
}

@Test func repositoryRefusesChangedOriginalAndRollsBack() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try MeetingRepository(directory: directory)
    var first = meeting(); try first.ingest(segment())
    try await repository.save(first)
    var conflicting = meeting(); conflicting.id = first.id
    try conflicting.ingest(segment(text: "篡改原文"))
    await #expect(throws: MeetingError.self) { try await repository.save(conflicting) }
    let restored = try await repository.loadAll()
    #expect(restored[0].segments[0].originalText == segment().originalText)
}

@Test func deletionRemovesLinkedAudioAndMeeting() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try MeetingRepository(directory: directory)
    let value = meeting()
    try await repository.save(value)
    let audio = directory.appendingPathComponent("Audio/\(value.id.uuidString)")
    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: audio.appendingPathComponent("test.caf"))
    try await repository.delete(value.id)
    #expect(!FileManager.default.fileExists(atPath: audio.path))
    #expect(try await repository.loadAll().isEmpty)
}

@Test func referencesRequireExistingStableOriginalIDs() throws {
    var value = meeting(); try value.ingest(segment())
    try VersionValidation.validateReferences([segment().id], in: value)
    #expect(throws: MeetingError.self) { try VersionValidation.validateReferences([], in: value) }
    #expect(throws: MeetingError.self) { try VersionValidation.validateReferences(["hallucinated"], in: value) }
}
