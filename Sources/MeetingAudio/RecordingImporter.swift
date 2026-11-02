import Foundation
import AVFoundation
import MeetingCore

public enum RecordingImporter {
    public static func readDuration(_ source: URL) throws -> TimeInterval {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw BatchTranscriptionError.invalid("请选择有效的音频文件。") }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: source) }
        catch { throw BatchTranscriptionError.invalid("无法读取录音，请选择未损坏的 M4A、MP3、WAV、CAF 或 AIFF 文件。") }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw BatchTranscriptionError.invalid("录音为空，无法导入。") }
        guard duration <= 14_400 else { throw BatchTranscriptionError.invalid("导入录音最长支持 4 小时，请先分段。") }
        return duration
    }

    /// Bounded-buffer conversion; the user's source is only ever opened for reading.
    /// The new meeting directory is owned by this operation and removed on failure/cancellation.
    public static func prepare(source: URL, title: String, startedAt: Date, settings: AppSettings,
                               directory: URL) throws -> Meeting {
        try Task.checkCancellation()
        let duration = try readDuration(source)
        var configuration = settings
        configuration.cacheAudio = true
        var meeting = Meeting(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            applicationName: "导入录音", bundleID: "", microphoneName: "", settings: configuration, now: startedAt)
        if meeting.title.isEmpty { meeting.title = source.deletingPathExtension().lastPathComponent }
        let folder = directory.appendingPathComponent("Audio/\(meeting.id.uuidString)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw MeetingError.invalidTransition }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: folder) } }
        let output = folder.appendingPathComponent("imported.caf")
        guard try BatchAudioPreparer.convert(source: source, output: output) != nil else {
            throw BatchTranscriptionError.invalid("录音为空，无法导入。")
        }
        try Task.checkCancellation()
        let converted = try AVAudioFile(forReading: output)
        let actualDuration = Double(converted.length) / converted.processingFormat.sampleRate
        guard actualDuration > 0, abs(actualDuration - duration) < 0.25 else {
            throw BatchTranscriptionError.invalid("转换后的录音长度与预计切片不一致。")
        }
        var chunk = AudioChunk(source: .mixed, relativePath: "Audio/\(meeting.id.uuidString)/imported.caf", start: 0)
        chunk.audioStart = 0; chunk.end = actualDuration
        meeting.audioChunks = [chunk]
        meeting.importedRecording = .init(fileName: source.lastPathComponent, duration: actualDuration)
        meeting.endedAt = startedAt.addingTimeInterval(actualDuration)
        meeting.lastSavedAt = Date(); meeting.status = .pending
        succeeded = true
        return meeting
    }
}
