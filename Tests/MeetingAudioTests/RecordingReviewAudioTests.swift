import Foundation
import AVFoundation
import Testing
import MeetingCore
@testable import MeetingAudio

private final class ReviewAudioFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var meeting = Meeting(title: "audio", applicationName: "", bundleID: "", microphoneName: "", settings: .init())
    init() throws {
        meeting.status = .pending
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Audio/\(meeting.id)"), withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func add(_ source: AudioSource, at start: Double, seconds: Double, value: Int16, rate: Double = 16000) throws {
        let path = "Audio/\(meeting.id)/\(UUID()).wav"
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: root.appendingPathComponent(path), settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.int16ChannelData![0][i] = value }
        try file.write(from: buffer)
        var chunk = AudioChunk(source: source, relativePath: path, start: 0); chunk.audioStart = start
        meeting.audioChunks.append(chunk)
    }
}

@Test func offlineReviewMixPreservesDurationOffsetAndSampleAlignment() throws {
    let fixture = try ReviewAudioFixture()
    try fixture.add(.application, at: 10, seconds: 1, value: 10000)
    try fixture.add(.microphone, at: 10.5, seconds: 1, value: 20000)
    let plan = try RecordingReviewAudio.plan(meeting: fixture.meeting, directory: fixture.root)
    #expect(plan.mixedSeconds == 1.5 && plan.sourceSeconds == 2)
    let output = fixture.root.appendingPathComponent("mixed.wav")
    _ = try RecordingReviewAudio.prepare(plan.slices[0], meetingID: fixture.meeting.id, directory: fixture.root, output: output)
    let file = try AVAudioFile(forReading: output, commonFormat: .pcmFormatInt16, interleaved: true)
    #expect(file.length == 24000)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24000)!
    try file.read(into: buffer)
    #expect(buffer.int16ChannelData![0][2000] == 5000)
    #expect(buffer.int16ChannelData![0][12000] == 15000)
    #expect(buffer.int16ChannelData![0][22000] == 10000)
}

@Test func offlineReviewResamplesSlicesAndDetectsMissingOriginals() throws {
    let fixture = try ReviewAudioFixture()
    try fixture.add(.application, at: 8, seconds: 3, value: 12000, rate: 48000)
    let plan = try RecordingReviewAudio.plan(meeting: fixture.meeting, directory: fixture.root)
    let sliced = try RecordingAudioPlan(inputs: plan.inputs, maximumSliceSeconds: 1)
    let output = fixture.root.appendingPathComponent("part.wav")
    _ = try RecordingReviewAudio.prepare(sliced.slices[1], meetingID: fixture.meeting.id, directory: fixture.root, output: output)
    #expect(try AVAudioFile(forReading: output).length == 16000)
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(fixture.meeting.audioChunks[0].relativePath))
    #expect(throws: BatchTranscriptionError.self) {
        try RecordingReviewAudio.prepare(sliced.slices[0], meetingID: fixture.meeting.id, directory: fixture.root, output: output)
    }
}
