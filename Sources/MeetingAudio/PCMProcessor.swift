import AVFoundation
import MeetingCore

/// Owns conversion and optional cache writing on one serial worker. Capture callbacks never perform disk I/O.
final class PCMProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "meetingrecord.pcm", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 32)
    private let lock = NSLock()
    private var accepting = true
    private var reportedFailure = false
    private let format: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter
    private var cache: AVAudioFile?
    private var pending = Data()
    private var pendingStart: TimeInterval?
    private let onTimedData: (@Sendable (TimedPCM) -> Void)?
    private var lastMeterTime = 0.0
    private let onData: @Sendable (Data) -> Void
    private let onLevel: @Sendable (Float) -> Void
    private let onFailure: @Sendable (Error) -> Void

    init(format: AVAudioFormat, cacheURL: URL?, onData: @escaping @Sendable (Data) -> Void,
         onLevel: @escaping @Sendable (Float) -> Void, onFailure: @escaping @Sendable (Error) -> Void,
         onTimedData: (@Sendable (TimedPCM) -> Void)? = nil) throws {
        guard format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: output) else { throw CaptureError.invalidFormat }
        self.format = format; self.output = output; self.converter = converter
        self.onData = onData; self.onLevel = onLevel; self.onFailure = onFailure
        self.onTimedData = onTimedData
        if let cacheURL {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            cache = try AVAudioFile(forWriting: cacheURL, settings: format.settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        }
    }

    func consume(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval? = nil) {
        let timestamp = hostTime ?? ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / format.sampleRate
        lock.lock(); let enabled = accepting; lock.unlock()
        guard enabled else { return }
        guard buffer.format == format else { fail(CaptureError.invalidFormat); return }
        guard slots.wait(timeout: .now()) == .success else { fail(CaptureError.overloaded); return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            slots.signal(); fail(CaptureError.invalidFormat); return
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        queue.async { [self] in
            defer { slots.signal() }
            do { try cache?.write(from: copy) }
            catch { cache = nil; fail(CaptureError.cacheFailed) }
            let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * output.sampleRate / format.sampleRate) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return copy
            }
            if error != nil { fail(CaptureError.invalidFormat); return }
            pendingStart = timestamp - Double(pending.count) / 32_000
            emit(converted)
        }
    }

    private func emit(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.int16ChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        pending.append(Data(bytes: samples, count: count * 2))
        // Uniform 100 ms chunks satisfy Transcribe's PCM streaming recommendations.
        while pending.count >= 3_200 {
            let data = Data(pending.prefix(3_200))
            onData(data)
            if let start = pendingStart { onTimedData?(.init(data: data, start: start)); pendingStart = start + 0.1 }
            pending.removeFirst(3_200)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if count > 0 && now - lastMeterTime > 0.1 {
            var sum: Float = 0
            for index in 0..<count { let sample = Float(samples[index]) / 32768; sum += sample * sample }
            onLevel(min(1, sqrt(sum / Float(count)) * 5)); lastMeterTime = now
        }
    }

    func stop() {
        lock.lock(); accepting = false; lock.unlock()
        queue.sync {
            // Resampling retains a filter tail (240 output samples in the 48 kHz -> 16 kHz regression).
            // Drain it before ending the network stream, otherwise the last phoneme can be clipped.
            if let tail = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 2_048) {
                for _ in 0..<8 {
                    tail.frameLength = 0
                    var error: NSError?
                    let status = converter.convert(to: tail, error: &error) { _, status in
                        status.pointee = .endOfStream; return nil
                    }
                    if error != nil || status == .error { fail(CaptureError.invalidFormat); break }
                    emit(tail)
                    if status == .endOfStream || tail.frameLength == 0 { break }
                }
            }
            // This is previously captured audio, not new audio collected after pause/stop.
            if !pending.isEmpty {
                onData(pending)
                if let start = pendingStart { onTimedData?(.init(data: pending, start: start)) }
                pending.removeAll()
            }
            cache = nil
        }
    }
    private func fail(_ error: Error) {
        lock.lock()
        let shouldReport = !reportedFailure
        reportedFailure = true
        lock.unlock()
        if shouldReport { onFailure(error) }
    }
}
