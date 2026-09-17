import Foundation

public struct CaptureWatchdog: Sendable {
    public enum Action: Equatable, Sendable { case none, waitForApplicationAudio, stopUnavailableMicrophone }
    public private(set) var lastFrameAt: Date
    public private(set) var awaitingFrames = false
    public init(startedAt: Date) { lastFrameAt = startedAt }
    public mutating func frameArrived(at date: Date) {
        lastFrameAt = date
        awaitingFrames = false
    }
    public mutating func poll(source: AudioSource, now: Date) -> Action {
        guard now.timeIntervalSince(lastFrameAt) > 8, !awaitingFrames else { return .none }
        awaitingFrames = true
        // A process tap may legitimately stay idle before that application starts audio IO.
        return source == .application ? .waitForApplicationAudio : .stopUnavailableMicrophone
    }
}
