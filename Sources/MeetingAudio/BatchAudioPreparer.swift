import AVFoundation
import MeetingCore

public enum BatchAudioPreparer {
    public static func sourceURL(_ chunk: AudioChunk, meetingID: UUID, directory: URL) throws -> URL {
        let root = directory.appendingPathComponent("Audio/\(meetingID.uuidString)").resolvingSymlinksInPath()
        let url = directory.appendingPathComponent(chunk.relativePath).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else {
            throw BatchTranscriptionError.invalid("录音文件缺失或路径不属于本会议，已停止重转录。")
        }
        return url
    }

    /// Converts bounded buffers, never loading an entire meeting into memory. Returns nil for a cache with no frames.
    public static func prepare(_ chunk: AudioChunk, meetingID: UUID, directory: URL, output: URL,
                               sourceStart: Double = 0, sourceDuration: Double? = nil) throws -> URL? {
        let input = try AVAudioFile(forReading: sourceURL(chunk, meetingID: meetingID, directory: directory))
        guard input.length > 0 else { return nil }
        let rate = input.processingFormat.sampleRate
        let duration = sourceDuration ?? Double(input.length) / rate
        guard sourceStart.isFinite, sourceStart >= 0, duration.isFinite, duration >= 0,
              sourceStart <= Double(input.length) / rate else {
            throw BatchTranscriptionError.invalid("录音切片时间范围无效。")
        }
        guard duration <= 14_400 + 1 / 16000 else {
            throw BatchTranscriptionError.invalid("单段录音超过 AWS 批量转录的 4 小时上限，暂不支持此录音。")
        }
        input.framePosition = Int64((sourceStart * rate).rounded())
        let endFrame = min(input.length, input.framePosition + Int64((duration * rate).rounded()))
        guard endFrame > input.framePosition else { return nil }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8_192),
              let target = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
            throw BatchTranscriptionError.invalid("无法转换录音格式。")
        }
        let file = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        while true {
            try Task.checkCancellation()
            var readError: Error?
            var conversionError: NSError?
            let status = converter.convert(to: target, error: &conversionError) { requested, state in
                do {
                    if input.framePosition >= endFrame { state.pointee = .endOfStream; return nil }
                    try input.read(into: source, frameCount: AVAudioFrameCount(min(Int64(requested), Int64(source.frameCapacity), endFrame - input.framePosition)))
                    state.pointee = source.frameLength == 0 ? .endOfStream : .haveData
                    return source.frameLength == 0 ? nil : source
                } catch {
                    readError = error; state.pointee = .endOfStream; return nil
                }
            }
            if readError != nil || conversionError != nil || status == .error {
                let code = (readError as NSError?)?.code ?? conversionError?.code ?? 0
                throw BatchTranscriptionError.invalid("读取或转换录音失败（音频错误 \(code)）；原录音已保留。")
            }
            if target.frameLength > 0 { try file.write(from: target) }
            if status == .endOfStream { break }
        }
        return output
    }
}
