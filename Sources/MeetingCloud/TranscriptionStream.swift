import Foundation
import AWSTranscribeStreaming
import AWSSDKIdentity
import AWSSTS
import MeetingCore

public enum TranscriptionUpdate: Sendable {
    case connected
    case partial(id: String, text: String)
    case final(resultID: String, segments: [TranscriptSegment])
    case ended
    case failed(String)
}

public final class TranscriptionStream: @unchecked Sendable {
    public let sessionID = UUID().uuidString
    private let continuation: AsyncThrowingStream<TranscribeStreamingClientTypes.AudioStream, Error>.Continuation
    private let stream: AsyncThrowingStream<TranscribeStreamingClientTypes.AudioStream, Error>
    private var task: Task<Void, Never>?
    private let lifecycleLock = NSLock()
    private var acceptsStart = true

    public init() {
        let pair = AsyncThrowingStream<TranscribeStreamingClientTypes.AudioStream, Error>.makeStream(bufferingPolicy: .bufferingOldest(50))
        stream = pair.stream; continuation = pair.continuation
    }

    public func send(_ data: Data) {
        if case .dropped = continuation.yield(.audioevent(.init(audioChunk: data))) {
            continuation.finish(throwing: TranscriptionError.backpressure)
        }
    }
    public func finish() {
        lifecycleLock.withLock { acceptsStart = false }
        continuation.finish()
    }
    public func cancel() {
        finish()
        currentTask()?.cancel()
    }
    public func waitUntilFinished() async { await currentTask()?.value }
    private func currentTask() -> Task<Void, Never>? { lifecycleLock.withLock { task } }

    public func start(settings: AppSettings, source: AudioSource, offset: TimeInterval,
                      receive: @escaping @Sendable (TranscriptionUpdate) async -> Void) {
        let sessionID = self.sessionID
        let stream = self.stream
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard acceptsStart && task == nil else { return }
        task = Task {
            do {
                try settings.transcriptionVocabulary?.validate(scope: .init(profile: settings.profile, region: settings.transcribeRegion))
                let resolver = ProfileAWSCredentialIdentityResolver(profileName: settings.profile)
                let config = try await TranscribeStreamingClient.TranscribeStreamingClientConfig(
                    awsCredentialIdentityResolver: resolver, maxAttempts: 1, ignoreConfiguredEndpointURLs: true,
                    region: settings.transcribeRegion, clientLogMode: .some(.none))
                let client = TranscribeStreamingClient(config: config)
                var input = Self.makeInput(language: settings.language, source: source, sessionID: sessionID,
                                           vocabulary: settings.transcriptionVocabulary)
                input.audioStream = stream
                let response = try await client.startStreamTranscription(input: input)
                await receive(.connected)
                guard let results = response.transcriptResultStream else { throw TranscriptionError.emptyResponse }
                for try await event in results {
                    try Task.checkCancellation()
                    guard case let .transcriptevent(event) = event else { continue }
                    for result in event.transcript?.results ?? [] {
                        guard let id = result.resultId, let alternative = result.alternatives?.first,
                              let text = alternative.transcript, !text.isEmpty else { continue }
                        if result.isPartial { await receive(.partial(id: id, text: text)) }
                        else {
                            await receive(.final(resultID: id, segments: Self.segments(
                                result, alternative: alternative, source: source, sessionID: sessionID, offset: offset)))
                        }
                    }
                }
                await receive(.ended)
            } catch is CancellationError {
                await receive(.failed("转录收尾已取消；请核对最后的发言。"))
            } catch {
                // SDK error dumps may contain request metadata. Present only a classified, content-free explanation.
                await receive(.failed(Self.userMessage(error)))
            }
        }
    }

    static func makeInput(language: RecognitionLanguage, source: AudioSource, sessionID: String,
                          vocabulary: VocabularySnapshot? = nil) -> StartStreamTranscriptionInput {
        var input = StartStreamTranscriptionInput(mediaEncoding: .pcm, mediaSampleRateHertz: 16_000,
            sessionId: sessionID, showSpeakerLabel: source == .application)
        switch language {
        case .mixed: input.identifyMultipleLanguages = true; input.languageOptions = "zh-CN,en-US"
        case .chinese: input.languageCode = .zhCn
        case .english: input.languageCode = .enUs
        }
        let bindings = vocabulary?.bindings.filter { $0.language.applies(to: language) } ?? []
        if !bindings.isEmpty {
            if language == .mixed { input.vocabularyNames = bindings.map(\.name).joined(separator: ",") }
            else { input.vocabularyName = bindings.first?.name }
        }
        return input
    }

    static func segments(_ result: TranscribeStreamingClientTypes.Result,
            alternative: TranscribeStreamingClientTypes.Alternative, source: AudioSource,
            sessionID: String, offset: TimeInterval) -> [TranscriptSegment] {
        guard let resultID = result.resultId else { return [] }
        let items = alternative.items ?? []
        let speakers = Set(items.compactMap(\.speaker))
        if source == .microphone || speakers.count <= 1 {
            return [TranscriptSegment(sessionID: sessionID, resultID: resultID, source: source,
                start: offset + result.startTime, end: offset + result.endTime,
                text: alternative.transcript ?? "",
                speakerID: source == .microphone ? "me" : "\(sessionID):\(speakers.first ?? "unknown")",
                serviceTranscript: alternative.transcript)]
        }
        // One AWS result can contain multiple speakers. Partition contiguous items; never label the entire result as the first speaker.
        var groups: [(speaker: String, items: [TranscribeStreamingClientTypes.Item])] = []
        for item in items {
            let speaker = item.speaker ?? groups.last?.speaker ?? "unknown"
            if groups.last?.speaker == speaker { groups[groups.count - 1].items.append(item) }
            else { groups.append((speaker, [item])) }
        }
        return groups.enumerated().compactMap { index, group in
            let text = joined(group.items.compactMap(\.content))
            guard !text.isEmpty else { return nil }
            let timedItems = group.items.filter { $0.type != .punctuation && $0.endTime >= $0.startTime }
            return TranscriptSegment(sessionID: sessionID, resultID: "\(resultID):\(index)", source: source,
                start: offset + (timedItems.first?.startTime ?? result.startTime),
                end: offset + (timedItems.last?.endTime ?? result.endTime),
                text: text, speakerID: "\(sessionID):\(group.speaker)", serviceTranscript: alternative.transcript)
        }
    }

    private static func joined(_ tokens: [String]) -> String {
        tokens.reduce("") { text, token in
            guard !text.isEmpty else { return token }
            let punctuation = token.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
            let cjk = { (character: Character?) in character?.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) } ?? false }
            return text + (punctuation || cjk(text.last) || cjk(token.first) ? "" : " ") + token
        }
    }

    public static func checkCredentials(settings: AppSettings) async throws {
        let resolver = ProfileAWSCredentialIdentityResolver(profileName: settings.profile)
        let config = try await STSClient.STSClientConfig(awsCredentialIdentityResolver: resolver, maxAttempts: 1,
            ignoreConfiguredEndpointURLs: true, region: settings.transcribeRegion, clientLogMode: .some(.none))
        _ = try await STSClient(config: config).getCallerIdentity(input: .init())
    }

    public static func userMessage(_ error: Error) -> String {
        if let error = error as? VocabularyError { return error.localizedDescription }
        let type = String(describing: Swift.type(of: error)).lowercased()
        if type.contains("credential") || type.contains("token") || type.contains("accessdenied") {
            return "AWS 凭证失效或权限不足。请刷新所选 profile，然后暂停／恢复以重建转录会话。"
        }
        if type.contains("badrequest") { return "Transcribe 拒绝了当前语言或说话人参数组合。请验证区域与服务能力；应用未自动切换配置。" }
        if type.contains("limit") || type.contains("throttl") { return "Transcribe 配额或限流，请稍后手动恢复；未无限重试。" }
        if let error = error as? TranscriptionError { return error.localizedDescription }
        return "Transcribe 连接中断或不可用。已标记可能缺失的区间；请检查网络和 AWS profile。"
    }
}

enum TranscriptionError: LocalizedError {
    case backpressure, emptyResponse
    var errorDescription: String? {
        switch self {
        case .backpressure: "上传积压超过 5 秒，已停止此路转录并标记缺口。音频缓存按当前设置继续。"
        case .emptyResponse: "Transcribe 未返回结果流。请核对服务区域和权限。"
        }
    }
}
