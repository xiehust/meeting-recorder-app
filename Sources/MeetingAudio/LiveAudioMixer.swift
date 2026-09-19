import Foundation
import MeetingCore

public struct TimedPCM: Sendable {
    public let data: Data
    /// Monotonic host-clock time of the first sample, in seconds.
    public let start: TimeInterval
    public init(data: Data, start: TimeInterval) { self.data = data; self.start = start }
}

enum AudioMixError: Error { case invalidPacket, overflow, lateAudio }

/// Fixed-size rings align independently clocked inputs. Missing samples contribute silence.
struct TimestampedAudioMixer {
    static let rate = 16_000
    private let capacity = 64_000
    private var samples = Array(repeating: Array(repeating: Int16(0), count: 64_000), count: 2)
    private var tags = Array(repeating: Array(repeating: Int64(-1), count: 64_000), count: 2)
    private(set) var origin: Double?
    private var cursor: Int64 = 0
    private(set) var lastEnd: Double?

    mutating func append(_ packet: TimedPCM, source: AudioSource) throws {
        guard packet.start.isFinite, packet.start >= 0, packet.data.count % 2 == 0,
              packet.data.count <= capacity * 2, source != .mixed else { throw AudioMixError.invalidPacket }
        guard !packet.data.isEmpty else { return }
        if origin == nil { origin = packet.start }
        if let oldOrigin = origin, packet.start < oldOrigin, cursor == 0 {
            let delta = (oldOrigin - packet.start) * Double(Self.rate)
            guard delta < Double(capacity) else { throw AudioMixError.overflow }
            let shift = Int(delta.rounded())
            for channel in 0..<2 {
                var movedSamples = Array(repeating: Int16(0), count: capacity)
                var movedTags = Array(repeating: Int64(-1), count: capacity)
                for slot in 0..<capacity where tags[channel][slot] >= 0 {
                    let position = tags[channel][slot] + Int64(shift)
                    guard position < Int64(capacity) else { throw AudioMixError.overflow }
                    movedSamples[Int(position)] = samples[channel][slot]; movedTags[Int(position)] = position
                }
                samples[channel] = movedSamples; tags[channel] = movedTags
            }
            origin = packet.start
        }
        let position = (packet.start - origin!) * Double(Self.rate)
        guard position.isFinite, abs(position) < Double(Int64.max / 2) else { throw AudioMixError.invalidPacket }
        let first = Int64(position.rounded()), count = packet.data.count / 2
        guard first + Int64(count) <= cursor + Int64(capacity) else { throw AudioMixError.overflow }
        guard first + Int64(count) > cursor else { throw AudioMixError.lateAudio }
        let channel = source == .application ? 0 : 1
        let bytes = [UInt8](packet.data)
        for index in 0..<count {
            let absolute = first + Int64(index)
            guard absolute >= cursor else { continue }
            let slot = Int(absolute % Int64(capacity))
            samples[channel][slot] = Int16(bitPattern: UInt16(bytes[2 * index]) | UInt16(bytes[2 * index + 1]) << 8)
            tags[channel][slot] = absolute
        }
        lastEnd = max(lastEnd ?? 0, packet.start + Double(count) / Double(Self.rate))
    }

    mutating func render(until time: Double, flush: Bool = false) -> [TimedPCM] {
        guard let origin, time.isFinite, time > origin else { return [] }
        let requested = min((time - origin) * Double(Self.rate), Double(cursor) + Double(capacity))
        let end = Int64(requested.rounded(flush ? .toNearestOrAwayFromZero : .down))
        var output: [TimedPCM] = []
        while cursor < end {
            let count = min(3_200, Int(end - cursor))
            if count < 3_200 && !flush { break }
            let start = origin + Double(cursor) / Double(Self.rate)
            var bytes = [UInt8](); bytes.reserveCapacity(count * 2)
            for absolute in cursor..<(cursor + Int64(count)) {
                let slot = Int(absolute % Int64(capacity))
                let a = tags[0][slot] == absolute ? Int32(samples[0][slot]) : 0
                let b = tags[1][slot] == absolute ? Int32(samples[1][slot]) : 0
                // Fixed gain prevents clipping and avoids pumping when speakers alternate.
                let value = UInt16(bitPattern: Int16((a + b) / 2))
                bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(truncatingIfNeeded: value >> 8))
            }
            cursor += Int64(count)
            output.append(.init(data: Data(bytes), start: start))
        }
        return output
    }
}

public final class LiveAudioMixer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "meetingrecord.mixer", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 40)
    private var mixer = TimestampedAudioMixer()
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var failed = false
    private let onData: @Sendable (TimedPCM) -> Void
    private let onFailure: @Sendable () -> Void

    public init(onData: @escaping @Sendable (TimedPCM) -> Void, onFailure: @escaping @Sendable () -> Void) {
        self.onData = onData; self.onFailure = onFailure
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, !self.failed else { return }
            for packet in self.mixer.render(until: ProcessInfo.processInfo.systemUptime - 0.35) { self.onData(packet) }
        }
        self.timer = timer; timer.resume()
    }
    public func send(_ packet: TimedPCM, source: AudioSource) {
        guard slots.wait(timeout: .now()) == .success else { onFailure(); return }
        queue.async { [self] in
            defer { slots.signal() }
            guard !stopped, !failed else { return }
            do { try mixer.append(packet, source: source) }
            catch { failed = true; onFailure() }
        }
    }
    public func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true; timer?.cancel(); timer = nil
            if !failed, let end = mixer.lastEnd {
                for packet in mixer.render(until: end, flush: true) { onData(packet) }
            }
        }
    }
    deinit { timer?.cancel() }
}
