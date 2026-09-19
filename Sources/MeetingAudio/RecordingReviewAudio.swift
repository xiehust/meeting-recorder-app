import Foundation
import AVFoundation
import MeetingCore

public enum RecordingReviewAudio {
    public static func plan(meeting: Meeting, directory: URL) throws -> RecordingAudioPlan {
        let inputs = try meeting.audioChunks.map { chunk in
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: BatchAudioPreparer.sourceURL(chunk, meetingID: meeting.id, directory: directory))
            return RecordingAudioInput(chunk: chunk, frames: file.length, sampleRate: file.processingFormat.sampleRate)
        }
        return try RecordingAudioPlan(inputs: inputs)
    }

    private struct Track {
        let url: URL
        let start: Int64
        let frames: Int64
        var reader: AVAudioFile?
        var end: Int64 { start + frames }
    }

    /// Offline mixing uses a fixed buffer and a stable meeting-time offset for each output job.
    public static func prepare(_ slice: RecordingAudioSlice, meetingID: UUID, directory: URL, output: URL) throws -> URL? {
        guard slice.duration > 0, slice.duration <= 14_400 + 1 / 16000 else { throw BatchTranscriptionError.invalid("录音切片时间范围无效。") }
        let count = Int64((slice.duration * 16000).rounded())
        guard count > 0 else { return nil }
        let temporary = output.deletingLastPathComponent().appendingPathComponent("mix-inputs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        var tracks: [Track] = []
        for input in slice.inputs {
            try Task.checkCancellation()
            let original = try AVAudioFile(forReading: BatchAudioPreparer.sourceURL(input.chunk, meetingID: meetingID, directory: directory))
            guard original.length == input.frames, original.processingFormat.sampleRate == input.sampleRate else {
                throw BatchTranscriptionError.invalid("录音文件已变化，请重新准备复核任务和费用估算。")
            }
            let from = max(slice.start, input.start), to = min(slice.end, input.end)
            guard to > from else { continue }
            let url = temporary.appendingPathComponent("\(input.chunk.id).wav")
            guard let normalized = try BatchAudioPreparer.prepare(input.chunk, meetingID: meetingID, directory: directory,
                output: url, sourceStart: from - input.start, sourceDuration: to - from) else { continue }
            tracks.append(.init(url: normalized, start: Int64(((from - slice.start) * 16000).rounded()),
                                frames: Int64(((to - from) * 16000).rounded())))
        }
        guard !tracks.isEmpty else { return nil }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw BatchTranscriptionError.invalid("无法转换录音格式。")
        }
        let writer = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        let gainDivisor: Int64 = Set(slice.inputs.map { $0.chunk.source }).count > 1 ? 2 : 1
        var cursor: Int64 = 0
        while cursor < count {
            try Task.checkCancellation()
            let length = Int(min(8192, count - cursor))
            var mixed = [Int64](repeating: 0, count: length)
            for index in tracks.indices {
                let from = max(cursor, tracks[index].start), to = min(cursor + Int64(length), tracks[index].end)
                guard to > from else {
                    if cursor >= tracks[index].end { tracks[index].reader = nil }
                    continue
                }
                if tracks[index].reader == nil {
                    tracks[index].reader = try AVAudioFile(forReading: tracks[index].url, commonFormat: .pcmFormatInt16, interleaved: true)
                }
                let reader = tracks[index].reader!
                let position = from - tracks[index].start
                let available = max(0, min(to - from, reader.length - position))
                guard to - from - available <= 2 else { throw BatchTranscriptionError.invalid("转换后的录音长度与预计切片不一致。") }
                if available > 0 {
                    reader.framePosition = position
                    try reader.read(into: inputBuffer, frameCount: AVAudioFrameCount(available))
                    guard inputBuffer.frameLength == available, let samples = inputBuffer.int16ChannelData?[0] else {
                        throw BatchTranscriptionError.invalid("转换后的录音长度与预计切片不一致。")
                    }
                    for sample in 0..<Int(inputBuffer.frameLength) { mixed[Int(from - cursor) + sample] += Int64(samples[sample]) }
                }
            }
            buffer.frameLength = AVAudioFrameCount(length)
            guard let samples = buffer.int16ChannelData?[0] else { throw BatchTranscriptionError.invalid("无法转换录音格式。") }
            for index in 0..<length { samples[index] = Int16(clamping: mixed[index] / gainDivisor) }
            try writer.write(from: buffer)
            cursor += Int64(length)
        }
        return output
    }
}
