import Foundation
import Testing
@testable import MeetingCore

@Test func correctionDecisionsPreserveOriginalAndInvalidateMinutesWithoutInvalidatingCorrectionInput() throws {
    var meeting = Meeting(title: "test", applicationName: "Teams", bundleID: "teams", microphoneName: "mic", settings: .init())
    try meeting.ingest(.init(sessionID: "s", resultID: "r", source: .microphone, start: 1, end: 2, text: "讨论结束", speakerID: "me"))
    let input = AIInputSnapshot(meeting: meeting)
    var correction = CorrectionVersion(input: input, configuration: .init(), profile: "default", chunkCount: 1)
    let change = AICorrection(segmentID: meeting.segments[0].id, before: "讨论结束", after: "讨论结束。",
                              reason: "标点", disposition: .accepted)
    correction.changes = [change]; correction.completedChunks = [0]
    meeting.correctionVersions = [correction]
    let corrected = meeting.correctedInput(using: correction)
    #expect(corrected.segments[0].text == "讨论结束。")
    let minutes = MinutesVersion(input: corrected, correctionVersionID: correction.id, configuration: .init(),
        profile: "default", minutes: .init(overview: "结束", topics: [], decisions: [], actions: [], questions: [], limitations: []), invocation: nil)
    meeting.minuteVersions = [minutes]
    #expect(!meeting.hasStaleSummary)
    try meeting.reviewCorrection(versionID: correction.id, changeID: change.id, disposition: .rejected)
    #expect(meeting.correctedInput(using: correction).segments[0].text == "讨论结束")
    #expect(meeting.hasStaleSummary)
    #expect(meeting.revision == correction.input.inputRevision)
    #expect(meeting.segments[0].originalText == "讨论结束")
    #expect(minutes.input.segments[0].text == "讨论结束。")
}

@Test func interruptedAIJobPreservesAudioTimelineAndVersions() {
    var meeting = Meeting(title: "test", applicationName: "Teams", bundleID: "teams", microphoneName: "mic", settings: .init())
    meeting.status = .summarizing
    meeting.aiTask = .init(stage: .summary, progress: "working")
    meeting.recoverInterrupted()
    #expect(meeting.status == .failed)
    #expect(meeting.aiTask?.stage == .interrupted)
    #expect(meeting.intervals.isEmpty)
}

private func bulkReviewFixture() throws -> (Meeting, CorrectionVersion) {
    var meeting = Meeting(title: "批量校对测试", applicationName: "Teams", bundleID: "teams", microphoneName: "mic", settings: .init())
    for index in 0..<4 {
        try meeting.ingest(.init(sessionID: "bulk", resultID: "\(index)", source: .application,
            start: Double(index), end: Double(index + 1), text: "原文\(index)", speakerID: "speaker"))
    }
    var version = CorrectionVersion(input: .init(meeting: meeting), configuration: .init(), profile: "default", chunkCount: 1)
    version.changes = version.input.segments.enumerated().map { index, segment in
        .init(segmentID: segment.id, before: segment.text, after: "校对\(index)", reason: "测试建议",
              disposition: index == 2 ? .accepted : .pending)
    }
    version.completedChunks = [0]
    meeting.correctionVersions = [version]
    try meeting.reviewCorrection(versionID: version.id, changeID: version.changes[3].id, disposition: .rejected)
    return (meeting, version)
}

@Test func bulkAcceptRecordsEachPendingChangePreservesRejectionsAndCanBeUndoneIndividually() throws {
    var (meeting, version) = try bulkReviewFixture()
    let originals = meeting.segments
    let rawRevision = meeting.revision
    let reviewRevision = meeting.correctionReviewRevision ?? 0
    meeting.minuteVersions = [.init(input: meeting.correctedInput(using: version), correctionVersionID: version.id,
        configuration: .init(), profile: "default",
        minutes: .init(overview: "测试纪要", topics: [], decisions: [], actions: [], questions: [], limitations: []), invocation: nil)]
    #expect(!meeting.hasStaleSummary)

    #expect(try meeting.acceptAllPendingCorrections(versionID: version.id) == 2)
    #expect(meeting.correctionReviews?.count == 3)
    #expect(meeting.correctionReviewRevision == reviewRevision + 1)
    #expect(meeting.disposition(of: version.changes[0], in: version) == .accepted)
    #expect(meeting.disposition(of: version.changes[1], in: version) == .accepted)
    #expect(meeting.disposition(of: version.changes[3], in: version) == .rejected)
    #expect(meeting.correctedInput(using: version).segments[0].text == "校对0")
    #expect(meeting.correctedInput(using: version).segments[3].text == "原文3")
    #expect(meeting.hasStaleSummary)
    #expect(meeting.segments == originals)
    #expect(meeting.revision == rawRevision)
    #expect(meeting.minuteVersions?[0].input.segments[0].text == "原文0")

    #expect(try meeting.acceptAllPendingCorrections(versionID: version.id) == 0)
    #expect(meeting.correctionReviews?.count == 3)
    #expect(meeting.correctionReviewRevision == reviewRevision + 1)
    try meeting.reviewCorrection(versionID: version.id, changeID: version.changes[0].id, disposition: .rejected)
    #expect(meeting.correctedInput(using: version).segments[0].text == "原文0")
    #expect(meeting.correctedInput(using: version).segments[1].text == "校对1")
    #expect(try meeting.acceptAllPendingCorrections(versionID: version.id) == 0)
}

@Test func bulkAcceptRejectsIncompleteOrOutdatedVersionsWithoutPartialWrites() throws {
    let (baseline, version) = try bulkReviewFixture()
    var stale = baseline
    stale.revision += 1
    #expect(throws: MeetingError.self) { try stale.acceptAllPendingCorrections(versionID: version.id) }
    #expect(stale.correctionReviews?.count == baseline.correctionReviews?.count)
    #expect(stale.correctionReviewRevision == baseline.correctionReviewRevision)

    var partial = baseline
    partial.correctionVersions?[0].completedChunks = []
    #expect(throws: MeetingError.self) { try partial.acceptAllPendingCorrections(versionID: version.id) }
    #expect(partial.correctionReviews?.count == baseline.correctionReviews?.count)
    #expect(throws: MeetingError.self) { try partial.acceptAllPendingCorrections(versionID: UUID()) }
}

@Test func bulkAcceptCannotApproveAnEditToHumanProtectedText() throws {
    var meeting = Meeting(title: "保护测试", applicationName: "Teams", bundleID: "teams", microphoneName: "mic", settings: .init())
    try meeting.ingest(.init(sessionID: "s", resultID: "r", source: .microphone, start: 0, end: 1, text: "原始识别", speakerID: "me"))
    try meeting.edit(segmentID: meeting.segments[0].id, text: "人工确认的文本")
    var version = CorrectionVersion(input: .init(meeting: meeting), configuration: .init(), profile: "default", chunkCount: 1)
    version.changes = [.init(segmentID: meeting.segments[0].id, before: "人工确认的文本", after: "不能覆盖",
                            reason: "防御异常历史数据", disposition: .pending)]
    version.completedChunks = [0]
    meeting.correctionVersions = [version]

    #expect(meeting.pendingCorrections(in: version).isEmpty)
    #expect(try meeting.acceptAllPendingCorrections(versionID: version.id) == 0)
    #expect(meeting.correctionReviews == nil)
    #expect(meeting.text(for: meeting.segments[0]) == "人工确认的文本")
    #expect(meeting.correctedInput(using: version).segments[0].text == "人工确认的文本")
}
