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
    public init(scope: VocabularyScope) async throws {
        let resolver = ProfileAWSCredentialIdentityResolver(profileName: scope.profile)
        transcribe = TranscribeClient(config: try await TranscribeClient.TranscribeClientConfig(awsCredentialIdentityResolver: resolver,
            maxAttempts: 1, ignoreConfiguredEndpointURLs: true, region: scope.region, clientLogMode: .some(.none)))
        s3 = S3Client(config: try await S3Client.S3ClientConfig(awsCredentialIdentityResolver: resolver,
            maxAttempts: 1, ignoreConfiguredEndpointURLs: true, region: scope.region, clientLogMode: .some(.none)))
    }

    public func bucketRegion(_ bucket: String) async throws -> String {
        let output = try await s3.getBucketLocation(input: .init(bucket: bucket))
        let region = output.locationConstraint?.rawValue ?? "us-east-1"
        return region == "EU" ? "eu-west-1" : region
    }

    public func upload(_ plan: VocabularyPlan, bucket: String) async throws {
        _ = try await s3.putObject(input: .init(body: .data(plan.table), bucket: bucket,
            contentType: "text/plain; charset=utf-8", key: plan.key))
    }

    public func get(_ name: String) async throws -> RemoteVocabularyStatus? {
        do {
            let output = try await transcribe.getVocabulary(input: .init(vocabularyName: name))
            let state: VocabularyState
            switch output.vocabularyState {
            case .ready: state = .ready
            case .failed: state = .failed
            default: state = .pending
            }
            return .init(language: output.languageCode.flatMap { VocabularyLanguage(rawValue: $0.rawValue) },
                         state: state, failure: output.failureReason)
        } catch is AWSTranscribe.NotFoundException { return nil }
    }

    public func submit(_ plan: VocabularyPlan, bucket: String, replaceFailed: Bool) async throws {
        let uri = "s3://\(bucket)/\(plan.key)"
        let language = TranscribeClientTypes.LanguageCode(rawValue: plan.binding.language.rawValue)
        if replaceFailed {
            _ = try await transcribe.updateVocabulary(input: .init(languageCode: language,
                vocabularyFileUri: uri, vocabularyName: plan.binding.name))
        } else {
            do {
                _ = try await transcribe.createVocabulary(input: .init(languageCode: language,
                    vocabularyFileUri: uri, vocabularyName: plan.binding.name))
            } catch is AWSTranscribe.ConflictException {
                // A previous request may have succeeded before a connection was lost; poll the same immutable name.
            }
        }
    }

    public func delete(_ deployment: VocabularyDeployment) async throws {
        do { _ = try await transcribe.deleteVocabulary(input: .init(vocabularyName: deployment.binding.name)) }
        catch is AWSTranscribe.NotFoundException {}
        _ = try await s3.deleteObject(input: .init(bucket: deployment.bucket, key: deployment.key))
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
        if let error = error as? VocabularyError { return error.localizedDescription }
        if error is CancellationError { return "同步已取消；已提交的 AWS 构建可能继续，稍后可再次同步检查。"}
        let type = String(describing: Swift.type(of: error)).lowercased()
        if type.contains("credential") || type.contains("token") || type.contains("accessdenied") || type.contains("forbidden") {
            return "AWS 凭证或权限不足。请检查所选 profile 的 Transcribe 词汇表和 S3 读写权限。"
        }
        if type.contains("nosuchbucket") { return "S3 桶不存在，请填写已有的同区域桶名。"}
        if type.contains("limit") || type.contains("throttl") { return "AWS 词汇表配额或请求频率受限，请清理旧版本或稍后再试。"}
        return "词汇表同步失败，请检查 AWS profile、区域、S3 桶权限及词条格式。"
    }
}
