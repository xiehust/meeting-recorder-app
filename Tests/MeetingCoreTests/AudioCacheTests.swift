import Foundation
import Testing
@testable import MeetingCore

private let cacheNow = Date(timeIntervalSince1970: 1_800_000_000)

private final class CacheFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func meeting(age: Double = 30, status: MeetingStatus = .completed) -> Meeting {
        var meeting = Meeting(title: "fixture", applicationName: "Test", bundleID: "test", microphoneName: "Test", settings: .init(), now: cacheNow.addingTimeInterval(-age * 86_400 - 60))
        meeting.status = status
        meeting.endedAt = cacheNow.addingTimeInterval(-age * 86_400)
        return meeting
    }
    @discardableResult func cache(_ meeting: inout Meeting, bytes: Int = 123, name: String = "application-test.caf", modified: Date = cacheNow) throws -> URL {
        let relative = "Audio/\(meeting.id.uuidString)/\(name)"
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        meeting.audioChunks.append(.init(source: .application, relativePath: relative, start: 0))
        return file
    }
}

@Test func cacheRetentionDefaultsToForeverAndPreservesLegacySettings() throws {
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    let legacy = try decoder.decode(AppSettings.self, from: encoder.encode(AppSettings()))
    #expect(legacy.effectiveAudioCacheRetention == .forever)
    #expect(legacy.effectiveAudioCacheRetention.cutoff(at: cacheNow) == nil)
    var settings = legacy; settings.audioCacheRetentionDays = 14
    #expect(try decoder.decode(AppSettings.self, from: encoder.encode(settings)).effectiveAudioCacheRetention == .twoWeeks)
    settings.audioCacheRetentionDays = -1
    #expect(settings.effectiveAudioCacheRetention == .forever)
    #expect(AudioCacheRetention.allCases.map(\.rawValue) == [0, 7, 14, 30, 90])
}

@Test func cacheStatisticsReportOnlyAudioAndRequireCompleteFilesForReview() async throws {
    let fixture = try CacheFixture()
    var meeting = fixture.meeting()
    try fixture.cache(&meeting, bytes: 100)
    let second = try fixture.cache(&meeting, bytes: 250, name: "microphone-test.caf")
    try Data(repeating: 0, count: 999).write(to: fixture.root.appendingPathComponent("meetings.sqlite"))
    let manager = AudioCacheManager(directory: fixture.root)
    let snapshot = try await manager.scan()
    #expect(snapshot.bytes == 350 && snapshot.files.count == 2 && snapshot.meetingCount == 1)
    #expect(snapshot.cleanableBytes(protecting: [meeting.id]) == 0)
    #expect(snapshot.containsAllAudio(for: meeting))
    try FileManager.default.removeItem(at: second)
    #expect(try await !manager.scan().containsAllAudio(for: meeting))
}

@Test func automaticCacheCleanupUsesMeetingEndAndExactRetentionBoundary() async throws {
    let fixture = try CacheFixture()
    var old = fixture.meeting(age: 8), boundary = fixture.meeting(age: 7), recent = fixture.meeting(age: 6.999)
    let oldFile = try fixture.cache(&old, modified: cacheNow) // Editing the meeting/file does not reset its recording age.
    let boundaryFile = try fixture.cache(&boundary)
    let recentFile = try fixture.cache(&recent, modified: cacheNow.addingTimeInterval(-100 * 86_400))
    let result = try await AudioCacheManager(directory: fixture.root).clean(meetings: [old, boundary, recent], retention: .oneWeek, now: cacheNow)
    #expect(result.removedFiles == 2 && result.removedBytes == 246 && result.failedFiles == 0)
    #expect(!FileManager.default.fileExists(atPath: oldFile.path) && !FileManager.default.fileExists(atPath: boundaryFile.path))
    #expect(FileManager.default.fileExists(atPath: recentFile.path))
}

@Test func cacheCleanupNeverRemovesRecordingPausedOrProcessingMeetings() async throws {
    let fixture = try CacheFixture()
    var meetings: [Meeting] = []
    for status: MeetingStatus in [.recording, .paused, .finalizing, .correcting, .summarizing, .retranscribing] {
        var meeting = fixture.meeting(status: status); try fixture.cache(&meeting); meetings.append(meeting)
    }
    var reserved = fixture.meeting(), idle = fixture.meeting(age: 0)
    try fixture.cache(&reserved); try fixture.cache(&idle)
    meetings += [reserved, idle]
    let result = try await AudioCacheManager(directory: fixture.root).clean(meetings: meetings, inUse: [reserved.id], retention: nil)
    #expect(result.removedFiles == 1)
    #expect(result.snapshot.files.count == 7)
    #expect(result.snapshot.files.allSatisfy { $0.meetingID != idle.id })
}

@Test func runningBatchReceiptProtectsAudioEvenBeforeMeetingStatusUpdates() async throws {
    let fixture = try CacheFixture()
    var meeting = fixture.meeting()
    try fixture.cache(&meeting)
    var settings = AppSettings(); settings.recordingReviewProvider = .transcribe
    meeting.batchVersions = [try BatchTranscriptionVersion(meeting: meeting, settings: settings, bucket: "test-bucket")]
    let result = try await AudioCacheManager(directory: fixture.root).clean(meetings: [meeting], retention: nil)
    #expect(result.removedFiles == 0 && result.snapshot.files.count == 1)
}

@Test func automaticForeverKeepsCacheAndOrphansUseFileModificationDate() async throws {
    let fixture = try CacheFixture()
    var old = fixture.meeting(), recent = fixture.meeting()
    try fixture.cache(&old, modified: cacheNow.addingTimeInterval(-15 * 86_400))
    try fixture.cache(&recent, modified: cacheNow)
    let manager = AudioCacheManager(directory: fixture.root)
    #expect(try await manager.clean(meetings: [], retention: .forever, now: cacheNow).removedFiles == 0)
    let result = try await manager.clean(meetings: [], retention: .twoWeeks, now: cacheNow)
    #expect(result.removedFiles == 1 && result.snapshot.files.first?.meetingID == recent.id)
}

@Test func cacheCleanupKeepsMeetingTextAndAudioMetadataInRepository() async throws {
    let fixture = try CacheFixture()
    var meeting = fixture.meeting()
    try fixture.cache(&meeting)
    meeting.note = "手动备注"
    try meeting.ingest(.init(sessionID: "fixture", resultID: "1", source: .application, start: 0, end: 1, text: "原始转录", speakerID: "speaker"))
    let repository = try MeetingRepository(directory: fixture.root)
    try await repository.save(meeting)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let before = try encoder.encode(await repository.loadAll())
    let result = try await AudioCacheManager(directory: fixture.root).clean(meetings: [meeting], retention: nil)
    #expect(result.removedFiles == 1 && result.snapshot.bytes == 0)
    #expect(try encoder.encode(await repository.loadAll()) == before)
    #expect(try await repository.loadAll()[0].audioChunks.count == 1)
}

@Test func cacheCleanupDoesNotTraverseLinksOrTouchOtherFiles() async throws {
    let fixture = try CacheFixture(), outside = try CacheFixture()
    var meeting = fixture.meeting(), external = outside.meeting()
    let actual = try fixture.cache(&meeting)
    let externalFile = try outside.cache(&external)
    let extra = actual.deletingLastPathComponent().appendingPathComponent("notes.txt")
    try Data([1]).write(to: extra)
    try FileManager.default.createSymbolicLink(at: actual.deletingLastPathComponent().appendingPathComponent("linked.caf"), withDestinationURL: externalFile)
    try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("Audio/\(external.id)"), withDestinationURL: externalFile.deletingLastPathComponent())
    let work = fixture.root.appendingPathComponent("BatchWork")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let workingAudio = work.appendingPathComponent("work.caf"); try Data([2]).write(to: workingAudio)
    let result = try await AudioCacheManager(directory: fixture.root).clean(meetings: [meeting], retention: nil)
    #expect(result.removedFiles == 1 && result.snapshot.bytes == 0)
    for file in [externalFile, extra, workingAudio] { #expect(FileManager.default.fileExists(atPath: file.path)) }
}

@Test func cacheCleanupRejectsSymlinkedAudioRoot() async throws {
    let fixture = try CacheFixture(), outside = try CacheFixture()
    var meeting = outside.meeting(); let file = try outside.cache(&meeting)
    try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("Audio"), withDestinationURL: outside.root.appendingPathComponent("Audio"))
    await #expect(throws: AudioCacheError.self) { try await AudioCacheManager(directory: fixture.root).clean(meetings: [], retention: nil) }
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func failedCacheDeletionRemainsCountedAndDoesNotHideSuccessfulCleanup() async throws {
    let fixture = try CacheFixture()
    var meeting = fixture.meeting()
    try fixture.cache(&meeting, bytes: 100, name: "locked.caf")
    try fixture.cache(&meeting, bytes: 200, name: "other.caf")
    let manager = AudioCacheManager(directory: fixture.root, removeFile: { url in
        if url.lastPathComponent == "locked.caf" { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: url)
    })
    let result = try await manager.clean(meetings: [meeting], retention: nil)
    #expect(result.failedFiles == 1 && result.removedFiles == 1 && result.removedBytes == 200)
    #expect(result.snapshot.bytes == 100 && result.snapshot.files.count == 1)
}
