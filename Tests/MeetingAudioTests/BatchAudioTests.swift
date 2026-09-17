import Foundation
import AVFoundation
import Testing
import MeetingCore
@testable import MeetingAudio

@Test func batchConvertsStereoCacheToMonoWAVWithFullDuration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(), relative = "Audio/"
    let path = relative + id.uuidString + "/fixture.caf"
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
    buffer.frameLength = 48_000
    for channel in 0..<2 {
        for frame in 0..<48_000 { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.05)) * 0.1 }
    }
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
    let output = root.appendingPathComponent("converted.wav")
    let result = try BatchAudioPreparer.prepare(.init(source: .application, relativePath: path, start: 17),
        meetingID: id, directory: root, output: output)
    #expect(result == output)
    let converted = try AVAudioFile(forReading: output)
    #expect(converted.fileFormat.sampleRate == 16_000)
    #expect(converted.fileFormat.channelCount == 1)
    #expect(abs(converted.length - 16_000) <= 2)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func batchRejectsMissingFilesAndSymlinkEscape() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Audio/\(id)"), withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("outside.caf"); try Data().write(to: outside)
    let relative = "Audio/\(id)/escape.caf"
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(relative), withDestinationURL: outside)
    #expect(throws: BatchTranscriptionError.self) {
        try BatchAudioPreparer.sourceURL(.init(source: .application, relativePath: relative, start: 0), meetingID: id, directory: root)
    }
    #expect(throws: BatchTranscriptionError.self) {
        try BatchAudioPreparer.sourceURL(.init(source: .application, relativePath: "missing.caf", start: 0), meetingID: id, directory: root)
    }
}
