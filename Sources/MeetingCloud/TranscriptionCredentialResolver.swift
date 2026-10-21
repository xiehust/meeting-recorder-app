import Foundation
import AWSSDKIdentity
import Smithy
import SmithyIdentity

/// Event-stream signing resolves credentials for every audio packet. A profile backed by
/// credential_process must not launch that process for each 100 ms of captured audio.
actor TranscriptionCredentialResolver: AWSCredentialIdentityResolver {
    private let source: any AWSCredentialIdentityResolver
    private let now: @Sendable () -> Date
    private var cached: AWSCredentialIdentity?
    private var refreshAt = Date.distantPast
    private var pending: Task<AWSCredentialIdentity, Error>?

    init(profile: String) {
        source = ProfileAWSCredentialIdentityResolver(profileName: profile)
        now = { Date() }
    }

    init(source: any AWSCredentialIdentityResolver, now: @escaping @Sendable () -> Date) {
        self.source = source
        self.now = now
    }

    func getIdentity(identityProperties: Attributes?) async throws -> AWSCredentialIdentity {
        if let cached, now() < refreshAt { return cached }
        if let pending { return try await pending.value }
        let task = Task { [source, now] in
            let identity = try await source.getIdentity(identityProperties: identityProperties)
            guard identity.expiration.map({ $0 > now() }) ?? true else {
                throw AWSCredentialIdentityResolverError.failedToResolveAWSCredentials("AWS credentials have expired.")
            }
            return identity
        }
        pending = task
        defer { pending = nil }
        let identity = try await task.value
        cached = identity
        // Bound both profile changes and credential expiry; credentials stay in memory only.
        refreshAt = min(now().addingTimeInterval(300), identity.expiration ?? .distantFuture)
        return identity
    }
}
