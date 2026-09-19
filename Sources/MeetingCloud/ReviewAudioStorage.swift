import Foundation
import AWSS3
import AWSSDKIdentity
import SmithyStreams
import MeetingCore

public protocol ReviewAudioStorage: Sendable {
    func checkBucket(_ bucket: String) async throws
    func upload(_ file: URL, bucket: String, key: String) async throws
    func downloadURL(bucket: String, key: String) async throws -> URL
    func remove(bucket: String, key: String) async throws
}

public struct S3ReviewAudioStorage: ReviewAudioStorage {
    private let client: S3Client
    private let scope: VocabularyScope
    public init(scope: VocabularyScope) async throws {
        self.scope = scope
        let resolver = ProfileAWSCredentialIdentityResolver(profileName: scope.profile)
        client = try S3Client(config: await S3Client.S3ClientConfig(awsCredentialIdentityResolver: resolver,
            maxAttempts: 1, ignoreConfiguredEndpointURLs: true, region: scope.region, clientLogMode: .some(.none)))
    }
    private func perform<T>(_ action: String, _ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch is CancellationError { throw CancellationError() }
        catch { throw BatchTranscriptionError.invalid(VocabularyDiagnostics.message(error, action: action)) }
    }
    public func checkBucket(_ bucket: String) async throws {
        let response = try await perform("s3:GetBucketLocation") { try await client.getBucketLocation(input: .init(bucket: bucket)) }
        let region = response.locationConstraint?.rawValue ?? "us-east-1"
        guard (region == "EU" ? "eu-west-1" : region) == scope.region else {
            throw BatchTranscriptionError.invalid("临时录音 S3 桶与配置的 AWS / S3 区域不一致。")
        }
    }
    public func upload(_ file: URL, bucket: String, key: String) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        _ = try await perform("s3:PutObject") {
            try await client.putObject(input: .init(body: .stream(FileStream(fileHandle: handle)),
                bucket: bucket, contentType: "audio/wav", key: key))
        }
    }
    public func downloadURL(bucket: String, key: String) async throws -> URL {
        _ = try await perform("s3:GetObject") {
            let response = try await client.getObject(input: .init(bucket: bucket, key: key, range: "bytes=0-0"))
            guard let body = response.body, let data = try await body.readData(), data.count == 1 else {
                throw BatchTranscriptionError.invalid("无法验证临时音频的读取权限。")
            }
        }
        let url = try await perform("S3 presign") {
            try await client.presignedURLForGetObject(input: .init(bucket: bucket, key: key), expiration: 7200)
        }
        guard url.scheme == "https" else { throw BatchTranscriptionError.invalid("无法生成安全的临时录音下载链接。") }
        return url
    }
    public func remove(bucket: String, key: String) async throws {
        _ = try await perform("s3:DeleteObject") { try await client.deleteObject(input: .init(bucket: bucket, key: key)) }
    }
}
