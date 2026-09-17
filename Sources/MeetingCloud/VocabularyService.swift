import Foundation
import AWSTranscribe
import AWSS3
import AWSSDKIdentity
import MeetingCore

public struct RemoteVocabularyStatus: Sendable {
    public let language: VocabularyLanguage?
    public let state: VocabularyState
    public let failure: String?
    public init(language: VocabularyLanguage?, state: VocabularyState, failure: String? = nil) {
        self.language = language; self.state = state; self.failure = failure
    }
}

public protocol VocabularyRemoteAPI: Sendable {
    func bucketRegion(_ bucket: String) async throws -> String
    func upload(_ plan: VocabularyPlan, bucket: String) async throws
    func get(_ name: String) async throws -> RemoteVocabularyStatus?
    func submit(_ plan: VocabularyPlan, bucket: String, replaceFailed: Bool) async throws
    func delete(_ deployment: VocabularyDeployment) async throws
}

public struct AWSVocabularyRemote: VocabularyRemoteAPI {
    private let transcribe: TranscribeClient
    private let s3: S3Client
    private let scope: VocabularyScope
    public init(scope: VocabularyScope) async throws {
        self.scope = scope
        do {
            let resolver = ProfileAWSCredentialIdentityResolver(profileName: scope.profile)
            transcribe = TranscribeClient(config: try await TranscribeClient.TranscribeClientConfig(awsCredentialIdentityResolver: resolver,
                maxAttempts: 1, ignoreConfiguredEndpointURLs: true, region: scope.region, clientLogMode: .some(.none)))
            s3 = S3Client(config: try await S3Client.S3ClientConfig(awsCredentialIdentityResolver: resolver,
                maxAttempts: 1, ignoreConfiguredEndpointURLs: true, region: scope.region, clientLogMode: .some(.none)))
        } catch {
            if error is CancellationError { throw error }
            throw VocabularyOperationError(operation: .configure, scope: scope, underlying: error)
        }
    }

    private func performing<T>(_ operation: VocabularyOperation, _ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch {
            if error is CancellationError { throw error }
            throw VocabularyOperationError(operation: operation, scope: scope, underlying: error)
        }
    }

    public func bucketRegion(_ bucket: String) async throws -> String {
        let output = try await performing(.bucketRegion) { try await s3.getBucketLocation(input: .init(bucket: bucket)) }
        let region = output.locationConstraint?.rawValue ?? "us-east-1"
        return region == "EU" ? "eu-west-1" : region
    }

    public func upload(_ plan: VocabularyPlan, bucket: String) async throws {
        _ = try await performing(.upload) {
            try await s3.putObject(input: .init(body: .data(plan.table), bucket: bucket,
                contentType: "text/plain; charset=utf-8", key: plan.key))
        }
    }

    public func get(_ name: String) async throws -> RemoteVocabularyStatus? {
        try await performing(.lookup) {
            let output: GetVocabularyOutput
            do { output = try await transcribe.getVocabulary(input: .init(vocabularyName: name)) }
            catch {
                if Self.isMissingVocabulary(error) { return nil }
                throw error
            }
            let state: VocabularyState
            switch output.vocabularyState {
            case .ready: state = .ready
            case .failed: state = .failed
            default: state = .pending
            }
            return .init(language: output.languageCode.flatMap { VocabularyLanguage(rawValue: $0.rawValue) },
                         state: state, failure: output.failureReason)
        }
    }

    static func isMissingVocabulary(_ error: Error) -> Bool {
        if error is AWSTranscribe.NotFoundException { return true }
        // GetVocabulary returns BadRequestException for a missing vocabulary in the live API.
        guard let error = error as? AWSTranscribe.BadRequestException else { return false }
        let message = (error.message ?? error.properties.message ?? "").lowercased()
        return message.contains("the requested vocabulary couldn't be found")
            || message.contains("the requested vocabulary could not be found")
    }

    public func submit(_ plan: VocabularyPlan, bucket: String, replaceFailed: Bool) async throws {
        let uri = "s3://\(bucket)/\(plan.key)"
        let language = TranscribeClientTypes.LanguageCode(rawValue: plan.binding.language.rawValue)
        if replaceFailed {
            _ = try await performing(.rebuild) {
                try await transcribe.updateVocabulary(input: .init(languageCode: language,
                    vocabularyFileUri: uri, vocabularyName: plan.binding.name))
            }
        } else {
            try await performing(.create) {
                do {
                    _ = try await transcribe.createVocabulary(input: .init(languageCode: language,
                        vocabularyFileUri: uri, vocabularyName: plan.binding.name))
                } catch is AWSTranscribe.ConflictException {
                    // A previous request may have succeeded before a connection was lost; poll the same immutable name.
                }
            }
        }
    }

    public func delete(_ deployment: VocabularyDeployment) async throws {
        try await performing(.deleteVocabulary) {
            do { _ = try await transcribe.deleteVocabulary(input: .init(vocabularyName: deployment.binding.name)) }
            catch { if !Self.isMissingVocabulary(error) { throw error } }
        }
        _ = try await performing(.deleteObject) {
            try await s3.deleteObject(input: .init(bucket: deployment.bucket, key: deployment.key))
        }
    }
}

public struct VocabularyService: Sendable {
    private let remote: any VocabularyRemoteAPI
    private let pollLimit: Int
    private let pollDelay: Duration
    public init(remote: any VocabularyRemoteAPI, pollLimit: Int = 60, pollDelay: Duration = .seconds(3)) {
        self.remote = remote; self.pollLimit = pollLimit; self.pollDelay = pollDelay
    }

    public func synchronize(plans: [VocabularyPlan], scope: VocabularyScope, bucket: String,
                            previous: [VocabularyDeployment] = [],
                            receive: @Sendable (VocabularyDeployment) async throws -> Void) async throws {
        try CustomVocabularyLibrary.validateBucket(bucket)
        guard !plans.isEmpty else { throw VocabularyError.invalid("请先添加并启用至少一个词条。") }
        guard try await remote.bucketRegion(bucket) == scope.region else {
            throw VocabularyError.invalid("S3 桶与 Transcribe 必须在同一区域，请修改桶名或区域。")
        }
        for plan in plans {
            try Task.checkCancellation()
            var deployment = previous.first { $0.scope == scope && $0.binding == plan.binding }
                ?? .init(plan: plan, scope: scope, bucket: bucket, state: .pending)
            let existing = try await remote.get(plan.binding.name)
            if let existing, existing.language != plan.binding.language {
                throw VocabularyError.invalid("云端词汇表语言不匹配，已停止同步。")
            }
            if existing?.state == .ready {
                deployment.state = .ready; deployment.failure = nil; deployment.checkedAt = Date()
                try await receive(deployment)
                continue
            }
            if existing == nil || existing?.state == .failed {
                deployment = .init(plan: plan, scope: scope, bucket: bucket, state: .pending)
                // Save the object location before any remote mutation so an interrupted sync can resume.
                try await receive(deployment)
                try await remote.upload(plan, bucket: bucket)
                try Task.checkCancellation()
                try await remote.submit(plan, bucket: bucket, replaceFailed: existing?.state == .failed)
            } else {
                deployment.state = .pending; deployment.failure = nil; deployment.checkedAt = Date()
                try await receive(deployment)
            }
            var ready = false
            for _ in 0..<pollLimit {
                try Task.checkCancellation()
                if let result = try await remote.get(plan.binding.name) {
                    guard result.language == plan.binding.language else { throw VocabularyError.invalid("云端词汇表语言不匹配。") }
                    deployment.state = result.state; deployment.failure = result.failure; deployment.checkedAt = Date()
                    try await receive(deployment)
                    if result.state == .ready { ready = true; break }
                    if result.state == .failed { throw VocabularyError.invalid(result.failure ?? "AWS 词汇表构建失败，请检查词条格式。") }
                }
                try await Task.sleep(for: pollDelay)
            }
            guard ready else { throw VocabularyError.invalid("AWS 仍在处理词汇表。稍后再次点击同步即可继续检查，不会创建重复版本。") }
        }
    }

    public func verifyReady(_ snapshot: VocabularySnapshot) async throws {
        for binding in snapshot.bindings {
            guard let result = try await remote.get(binding.name),
                  result.state == .ready, result.language == binding.language else {
                throw VocabularyError.invalid("\(binding.language.title)词汇表在 AWS 不存在或尚未就绪，请重新同步后开始记录。")
            }
        }
    }

    public static func userMessage(_ error: Error) -> String {
        VocabularyDiagnostics.message(error)
    }
}
