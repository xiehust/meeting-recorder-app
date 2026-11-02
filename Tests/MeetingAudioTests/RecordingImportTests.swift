import Foundation
import AVFoundation
import Testing
import MeetingCore
@testable import MeetingAudio

private func importFixture(_ url: URL, compressed: Bool = false, empty: Bool = false) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
    buffer.frameLength = 44_100
    for channel in 0..<2 {
        for frame in 0..<44_100 { buffer.floatChannelData![channel][frame] = channel == 0 ? 0 : sin(Float(frame) * 0.08) * 0.2 }
    }
    let settings: [String: Any] = compressed
        ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]
        : format.settings
    let file = try AVAudioFile(forWriting: url, settings: settings)
    if !empty { try file.write(from: buffer) }
}

@Test(arguments: [false, true]) func importedRecordingPreservesSourceAndReusesBothBatchProviders(compressed: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent(compressed ? "source.m4a" : "source.wav")
    try importFixture(source, compressed: compressed)
    let before = try Data(contentsOf: source)
    let started = Date(timeIntervalSince1970: 1_700_000_000)
    let meeting = try RecordingImporter.prepare(source: source, title: "Imported meeting", startedAt: started,
        settings: .init(), directory: root)
    #expect(meeting.status == .pending && !meeting.status.isActive)
    #expect(meeting.importedRecording?.fileName == source.lastPathComponent)
    #expect(abs(meeting.endedAt!.timeIntervalSince(started) - 1) < 0.1)
    #expect(meeting.audioChunks.count == 1 && meeting.audioChunks[0].source == .mixed)
    let cached = root.appendingPathComponent(meeting.audioChunks[0].relativePath)
    let file = try AVAudioFile(forReading: cached)
    #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1)
    let samples = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
    try file.read(into: samples)
    #expect((0..<Int(samples.frameLength)).contains { abs(samples.floatChannelData![0][$0]) > 0.01 })
    #expect(try FileManager.default.attributesOfItem(atPath: cached.path)[.posixPermissions] as? Int == 0o600)
    let plan = try RecordingReviewAudio.plan(meeting: meeting, directory: root)
    #expect(plan.slices.count == 1 && abs(plan.mixedSeconds - 1) < 0.1)
    for provider in RecordingReviewProvider.allCases {
        var settings = meeting.settings; settings.recordingReviewProvider = provider
        let version = try BatchTranscriptionVersion(meeting: meeting, settings: settings, bucket: "test-bucket", audioPlan: plan)
        #expect(version.jobs.count == 1)
    }
    // Import time, not the old recording date, starts automatic cache retention.
    let cleanup = try await AudioCacheManager(directory: root).clean(meetings: [meeting], retention: .oneWeek)
    #expect(cleanup.removedFiles == 0)
    #expect(try Data(contentsOf: source) == before)
}

@Test func importRejectsEmptyAndCorruptAudioWithoutLeavingMeetings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = root.appendingPathComponent("empty.caf"), corrupt = root.appendingPathComponent("broken.mp3")
    try importFixture(empty, empty: true); try Data("invalid".utf8).write(to: corrupt)
    for file in [empty, corrupt] {
        #expect(throws: BatchTranscriptionError.self) {
            try RecordingImporter.prepare(source: file, title: "", startedAt: Date(), settings: .init(), directory: root)
        }
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Audio").path))
    #expect(try Data(contentsOf: corrupt) == Data("invalid".utf8))
}

@Test func cancelledImportLeavesSourceIntact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.caf")
    try importFixture(source)
    let before = try Data(contentsOf: source)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try RecordingImporter.prepare(source: source, title: "", startedAt: Date(), settings: .init(), directory: root)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: source) == before)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Audio").path))
}
