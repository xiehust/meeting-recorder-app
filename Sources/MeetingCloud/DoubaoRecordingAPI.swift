import Foundation
import CoreFoundation
import MeetingCore

public enum DoubaoRecordingResult: Sendable { case missing, running, completed(Data) }
public protocol DoubaoRecordingAPI: Sendable {
    func submit(id: String, audioURL: URL, settings: AppSettings) async throws
    func query(id: String) async throws -> DoubaoRecordingResult
}

public struct DoubaoRecordingClient: DoubaoRecordingAPI {
    static let resource = "volc.seedasr.auc"
    private let apiKey: String
    private let session: URLSession
    public init(apiKey: String) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    static func submissionBody(id: String, audioURL: URL, settings: AppSettings) throws -> Data {
        try settings.validateReviewConfiguration()
        guard audioURL.scheme == "https" else { throw BatchTranscriptionError.invalid("临时音频链接必须使用 HTTPS。") }
        var audio: [String: Any] = ["url": audioURL.absoluteString, "format": "wav", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1]
        if settings.language == .japanese { audio["language"] = "ja-JP" }
        var request: [String: Any] = ["model_name": "bigmodel", "show_utterances": true,
            "enable_speaker_info": true, "enable_itn": true, "enable_punc": true, "enable_ddc": false]
        if settings.language != .japanese { request["ssd_version"] = "200" }
        let hotwords = settings.effectiveReviewSettings.hotwords
        if !hotwords.isEmpty {
            let context = try JSONSerialization.data(withJSONObject: ["hotwords": hotwords.prefix(5000).map { ["word": $0] }])
            request["corpus"] = ["context": String(decoding: context, as: UTF8.self)]
        }
        return try JSONSerialization.data(withJSONObject: ["user": ["uid": id], "audio": audio, "request": request], options: [.sortedKeys])
    }

    private func call(_ operation: String, id: String, body: Data) async throws -> (Data, HTTPURLResponse) {
        guard !apiKey.isEmpty else { throw SpeechConfigurationError.missingKey }
        var request = URLRequest(url: URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/\(operation)")!)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(Self.resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(id, forHTTPHeaderField: "X-Api-Request-Id")
        if operation == "submit" { request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, data.count <= 100_000_000 else { throw BatchTranscriptionError.invalid("豆包录音文件响应无效或过大。") }
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as BatchTranscriptionError { throw error }
        catch {
            throw BatchTranscriptionError.invalid("豆包录音文件请求未完成。已保存任务 ID；继续任务时先查询，不会自动重复提交。")
        }
    }
    static func isMissingTask(_ response: HTTPURLResponse) -> Bool {
        let message = (response.value(forHTTPHeaderField: "X-Api-Message") ?? "").lowercased()
        return message.contains("cannot find task")
            || ((message.contains("task") || message.contains("request_id") || message.contains("request id"))
            && (message.contains("not exist") || message.contains("not found")))
            || (message.contains("任务") && message.contains("不存在"))
    }
    static func failure(_ response: HTTPURLResponse) -> BatchTranscriptionError {
        let code = response.value(forHTTPHeaderField: "X-Api-Status-Code").flatMap(Int.init)
        let suffix = "HTTP \(response.statusCode)" + (code.map { "; API \($0)" } ?? "")
        if [401, 403].contains(response.statusCode) {
            return .invalid("豆包录音文件识别请求被拒绝（\(suffix)）。请检查 API Key、录音文件识别 2.0 服务权限和配额；该资源与流式服务分别开通。")
        }
        return .invalid("豆包录音文件请求未成功（\(suffix)）。请检查请求参数、任务状态或服务配额；此响应不能单独判断为 API Key 或服务权限问题。")
    }
    public func submit(id: String, audioURL: URL, settings: AppSettings) async throws {
        let (_, response) = try await call("submit", id: id, body: Self.submissionBody(id: id, audioURL: audioURL, settings: settings))
        guard response.statusCode == 200, response.value(forHTTPHeaderField: "X-Api-Status-Code") == "20000000" else { throw Self.failure(response) }
    }
    public func query(id: String) async throws -> DoubaoRecordingResult {
        let (data, response) = try await call("query", id: id, body: Data("{}".utf8))
        return try Self.queryResult(data, response: response)
    }
    static func queryResult(_ data: Data, response: HTTPURLResponse) throws -> DoubaoRecordingResult {
        if [200, 400, 404].contains(response.statusCode), isMissingTask(response) { return .missing }
        guard response.statusCode == 200 else { throw failure(response) }
        switch response.value(forHTTPHeaderField: "X-Api-Status-Code") {
        case "20000000": return .completed(data)
        case "20000001", "20000002": return .running
        case "20000003": return .completed(Data(#"{"result":{"text":"","utterances":[]}}"#.utf8))
        default:
            if isMissingTask(response) { return .missing }
            throw failure(response)
        }
    }
    public func checkAccess() async throws {
        _ = try await query(id: UUID().uuidString.lowercased())
    }
}

public actor DoubaoBatchTranscriptionRemote: BatchTranscriptionRemote {
    private let api: any DoubaoRecordingAPI
    private let storage: any ReviewAudioStorage
    private var results: [String: Data] = [:]
    private var downloadURLs: [String: URL] = [:]
    public init(api: any DoubaoRecordingAPI, storage: any ReviewAudioStorage) { self.api = api; self.storage = storage }
    public func checkBucket(_ bucket: String) async throws { try await storage.checkBucket(bucket) }
    public func state(_ job: BatchTranscriptionJob) async throws -> RemoteBatchState {
        guard let id = job.requestID else { throw BatchTranscriptionError.invalid("豆包任务缺少已保存的请求 ID。") }
        switch try await api.query(id: id) {
        case .running: return .running
        case .completed(let data): results[id] = data; return .completed
        case .missing:
            guard job.submission == nil else {
                throw BatchTranscriptionError.invalid("已提交的豆包任务无法查询，可能尚未可见或已过期。请稍后继续查询；不会自动重提，重新识别请创建新版本并确认费用。")
            }
            return .missing
        }
    }
    public func upload(_ file: URL, job: BatchTranscriptionJob, bucket: String) async throws {
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes < 512_000_000 else { throw BatchTranscriptionError.invalid("混音文件为空或超过豆包 512 MB 上限。") }
        try await storage.upload(file, bucket: bucket, key: job.inputKey)
    }
    public func prepareSubmission(_ job: BatchTranscriptionJob, version: BatchTranscriptionVersion) async throws {
        guard let id = job.requestID else { throw BatchTranscriptionError.invalid("豆包任务缺少已保存的请求 ID。") }
        downloadURLs[id] = try await storage.downloadURL(bucket: version.bucket, key: job.inputKey)
    }
    public func submit(_ job: BatchTranscriptionJob, version: BatchTranscriptionVersion) async throws {
        guard let id = job.requestID, let url = downloadURLs.removeValue(forKey: id) else {
            throw BatchTranscriptionError.invalid("临时音频下载地址尚未准备完成，未提交识别。")
        }
        try await api.submit(id: id, audioURL: url, settings: version.settings)
    }
    public func result(_ job: BatchTranscriptionJob, bucket: String) async throws -> Data {
        guard let id = job.requestID else { throw BatchTranscriptionError.invalid("豆包任务缺少已保存的请求 ID。") }
        if let data = results.removeValue(forKey: id) { return data }
        guard case .completed(let data) = try await api.query(id: id) else { throw BatchTranscriptionError.invalid("豆包录音文件结果尚未完成。") }
        return data
    }
    public func clean(_ job: BatchTranscriptionJob, bucket: String) async throws { try await storage.remove(bucket: bucket, key: job.inputKey) }
    public func parseResult(_ data: Data, job: BatchTranscriptionJob) throws -> [TranscriptSegment] {
        try DoubaoRecordingParser.parse(data, job: job)
    }
}

enum DoubaoRecordingParser {
    static func parse(_ data: Data, job: BatchTranscriptionJob) throws -> [TranscriptSegment] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw BatchTranscriptionError.invalid("豆包录音文件结果格式无效。") }
        let results = (root["result"] as? [String: Any]).map { [$0] } ?? (root["result"] as? [[String: Any]]) ?? []
        guard !results.isEmpty else { throw BatchTranscriptionError.invalid("豆包录音文件结果缺少正文。") }
        var output: [TranscriptSegment] = []
        for result in results {
            let utterances = result["utterances"] as? [[String: Any]] ?? []
            if utterances.isEmpty, !(result["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw BatchTranscriptionError.invalid("豆包录音文件结果缺少分句时间戳。")
            }
            for utterance in utterances {
                guard let text = utterance["text"] as? String else { throw BatchTranscriptionError.invalid("豆包录音文件结果缺少分句正文。") }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                func time(_ value: Any?) -> Double? {
                    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
                    return (value as? String).flatMap(Double.init)
                }
                let start = utterance["start_time"] == nil && output.isEmpty ? 0 : time(utterance["start_time"])
                guard let start, let end = time(utterance["end_time"]), start.isFinite, end.isFinite,
                      start >= 0, end >= start, end / 1000 <= (job.mixedAudio?.duration ?? 14_400) + 1 else {
                    throw BatchTranscriptionError.invalid("豆包录音文件结果的时间戳无效。")
                }
                let additions = utterance["additions"] as? [String: Any]
                let label = additions?["speaker_id"] ?? additions?["speaker"] ?? utterance["speaker_id"]
                let speaker = (label as? String) ?? (label as? NSNumber)?.stringValue ?? "unknown"
                let offset = job.chunk.audioStart ?? job.chunk.start
                output.append(.init(sessionID: job.name, resultID: "\(output.count)", source: .mixed,
                    start: offset + start / 1000, end: offset + end / 1000, text: text,
                    speakerID: "batch/\(job.name)/\(speaker)"))
            }
        }
        return output
    }
}
