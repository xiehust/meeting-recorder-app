import AVFoundation
import Foundation

enum ApplicationCaptureFormat {
    /// The IOProc receives the aggregate input stream, not the process tap's pre-aggregation format.
    static func resolve(tap: AVAudioFormat, input: AVAudioFormat) throws -> AVAudioFormat {
        guard input.sampleRate.isFinite, input.sampleRate > 0,
              input.channelCount == tap.channelCount, input.commonFormat == tap.commonFormat else {
            throw CaptureError.invalidFormat
        }
        return input
    }
}

/// Stops accepting buffers immediately when the HAL announces a format change, before the UI stops capture.
final class CaptureFormatState: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var acceptsAudio: Bool { lock.withLock { valid } }
    func invalidate() -> Bool {
        lock.withLock {
            guard valid else { return false }
            valid = false
            return true
        }
    }
}
