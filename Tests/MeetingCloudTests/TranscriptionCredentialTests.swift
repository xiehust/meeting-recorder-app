import Foundation
import Testing
import AWSSDKIdentity
import Smithy
import SmithyIdentity
@testable import MeetingCloud

private final class CredentialClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private actor CountingCredentialSource: AWSCredentialIdentityResolver {
    var calls = 0
    let expiration: Date?
    let failFirst: Bool
    init(expiration: Date? = nil, failFirst: Bool = false) {
        self.expiration = expiration; self.failFirst = failFirst
    }
    func getIdentity(identityProperties: Attributes?) async throws -> AWSCredentialIdentity {
        calls += 1
        let call = calls
        try await Task.sleep(for: .milliseconds(10))
        if failFirst && call == 1 {
            throw AWSCredentialIdentityResolverError.failedToResolveAWSCredentials("Test failure")
        }
        return AWSCredentialIdentity(accessKey: "fixture-\(call)", secret: "fixture", expiration: expiration)
    }
}

@Test func streamingPacketsReuseCredentialsAndCoalesceConcurrentFetches() async throws {
    let clock = CredentialClock()
    let source = CountingCredentialSource()
    let resolver = TranscriptionCredentialResolver(source: source, now: { clock.now() })
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<20 {
            group.addTask { _ = try await resolver.getIdentity(identityProperties: nil) }
        }
        try await group.waitForAll()
    }
    for _ in 0..<100 { _ = try await resolver.getIdentity(identityProperties: nil) }
    #expect(await source.calls == 1)
    clock.advance(300)
    _ = try await resolver.getIdentity(identityProperties: nil)
    #expect(await source.calls == 2)
}

@Test func streamingCredentialsNeverRemainCachedPastExpiration() async throws {
    let clock = CredentialClock()
    let source = CountingCredentialSource(expiration: clock.now().addingTimeInterval(30))
    let resolver = TranscriptionCredentialResolver(source: source, now: { clock.now() })
    _ = try await resolver.getIdentity(identityProperties: nil)
    clock.advance(29)
    _ = try await resolver.getIdentity(identityProperties: nil)
    #expect(await source.calls == 1)
    clock.advance(1)
    await #expect(throws: (any Error).self) { _ = try await resolver.getIdentity(identityProperties: nil) }
    #expect(await source.calls == 2)
}

@Test func streamingCredentialFailureCanBeRetriedWithoutCachingTheFailure() async throws {
    let clock = CredentialClock()
    let source = CountingCredentialSource(failFirst: true)
    let resolver = TranscriptionCredentialResolver(source: source, now: { clock.now() })
    await #expect(throws: (any Error).self) { _ = try await resolver.getIdentity(identityProperties: nil) }
    _ = try await resolver.getIdentity(identityProperties: nil)
    _ = try await resolver.getIdentity(identityProperties: nil)
    #expect(await source.calls == 2)
}
