import Foundation
import AWSTranscribe
import AWSS3
import AWSSDKIdentity
import SmithyStreams
import MeetingCore

public struct AWSBatchTranscriptionRemote: BatchTranscriptionRemote {
    private let transcribe: TranscribeClient
    private let s3: S3Client
    private let scope: VocabularyScope
    public init(scope: VocabularyScope) async throws {
        self.scope = scope
        do {
            let resolver = ProfileAWSCredentialIdentityResolver(profileName: scope.profile)
            transcribe = TranscribeClient(config: try await TranscribeClient.TranscribeClientConfig(
                awsCredentialIdentityResolver: resolver, maxAttempts: 1, ignoreConfiguredEndpointURLs: true,
                region: scope.region, clientLogMode: .some(.none)))
            s3 = S3Client(config: try await S3Client.S3ClientConfig(
                awsCredentialIdentityResolver: resolver, maxAttempts: 1, ignoreConfiguredEndpointURLs: true,
                region: scope.region, clientLogMode: .some(.none)))
        } catch { throw BatchTranscriptionError.invalid(VocabularyDiagnostics.message(error)) }
    }
    private func performing<T>(_ action: String, _ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch {
            if error is CancellationError { throw error }
            throw BatchTranscriptionError.invalid("\(action) · \(scope.profile) · \(scope.region)：\(VocabularyDiagnostics.message(error, action: action))")
        }
    }
    public func checkBucket(_ bucket: String) async throws {
        let response = try await performing("s3:GetBucketLocation") { try await s3.getBucketLocation(input: .init(bucket: bucket)) }
        let region = response.locationConstraint?.rawValue ?? "us-east-1"
        guard (region == "EU" ? "eu-west-1" : region) == scope.region else {
            throw BatchTranscriptionError.invalid("录音 S3 桶必须与批量 Transcribe 位于同一区域。")
        }
    }
    public func state(_ job: BatchTranscriptionJob) async throws -> RemoteBatchState {
        try await performing("transcribe:GetTranscriptionJob") {
            do {
                let result = try await transcribe.getTranscriptionJob(input: .init(transcriptionJobName: job.name))
                switch result.transcriptionJob?.transcriptionJobStatus {
                case .completed: return .completed
                case .failed: return .failed
                default: return .running
                }
            } catch let error as AWSTranscribe.BadRequestException {
                let message = (error.message ?? error.properties.message ?? "").lowercased()
                if message.contains("couldn't be found") || message.contains("could not be found") { return .missing }
                throw error
            } catch is AWSTranscribe.NotFoundException { return .missing }
        }
    }
    public func upload(_ file: URL, job: BatchTranscriptionJob, bucket: String) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        _ = try await performing("s3:PutObject") {
            try await s3.putObject(input: .init(body: .stream(FileStream(fileHandle: handle)), bucket: bucket,
                contentType: "audio/wav", key: job.inputKey))
        }
    }
    static func input(_ job: BatchTranscriptionJob, version: BatchTranscriptionVersion) -> StartTranscriptionJobInput {
        var input = StartTranscriptionJobInput(media: .init(mediaFileUri: "s3://\(version.bucket)/\(job.inputKey)"),
            mediaFormat: .wav, mediaSampleRateHertz: 16_000, outputBucketName: version.bucket, outputKey: job.outputKey,
            settings: .init(maxSpeakerLabels: job.chunk.source == .application ? 10 : nil,
                            showSpeakerLabels: job.chunk.source == .application),
            transcriptionJobName: job.name)
        let bindings = version.settings.transcriptionVocabulary?.bindings.filter { $0.language.applies(to: version.settings.language) } ?? []
        if version.settings.language == .mixed {
            input.identifyMultipleLanguages = true; input.languageOptions = [.zhCn, .enUs]
            if !bindings.isEmpty {
                input.languageIdSettings = Dictionary(uniqueKeysWithValues: bindings.map {
                    ($0.language.rawValue, .init(vocabularyName: $0.name))
                })
            }
        } else {
            input.languageCode = version.settings.language == .chinese ? .zhCn : .enUs
            input.settings?.vocabularyName = bindings.first?.name
        }
        return input
    }
    public func submit(_ job: BatchTranscriptionJob, version: BatchTranscriptionVersion) async throws {
        try await performing("transcribe:StartTranscriptionJob") {
            do { _ = try await transcribe.startTranscriptionJob(input: Self.input(job, version: version)) }
            catch is AWSTranscribe.ConflictException { /* Same durable job ID: resume polling. */ }
        }
    }
    public func result(_ job: BatchTranscriptionJob, bucket: String) async throws -> Data {
        try await performing("s3:GetObject") {
            let response = try await s3.getObject(input: .init(bucket: bucket, key: job.outputKey))
            guard let body = response.body, let data = try await body.readData(), data.count <= 100_000_000 else {
                throw BatchTranscriptionError.invalid("批量转录结果为空或超过本地读取限制。")
            }
            return data
        }
    }
    public func clean(_ job: BatchTranscriptionJob, bucket: String) async throws {
        _ = try await performing("transcribe:DeleteTranscriptionJob") {
            do { _ = try await transcribe.deleteTranscriptionJob(input: .init(transcriptionJobName: job.name)) }
            catch let error as AWSTranscribe.BadRequestException {
                let message = (error.message ?? error.properties.message ?? "").lowercased()
                if !message.contains("couldn't be found") && !message.contains("could not be found") { throw error }
            } catch is AWSTranscribe.NotFoundException {}
        }
        for key in [job.inputKey, job.outputKey] {
            _ = try await performing("s3:DeleteObject") { try await s3.deleteObject(input: .init(bucket: bucket, key: key)) }
        }
    }
}
