import Foundation
import CoreFoundation
import CZlib
import MeetingCore

public enum DoubaoResponseMode: String, Sendable { case single, full }

/// Timing and anonymous service labels for explicit protocol audits. Contains no transcript text.
public struct DoubaoSpeakerObservation: Sendable {
    public let start: Double
    public let end: Double?
    public let definite: Bool
    public let speakerID: String?
}

enum DoubaoError: LocalizedError {
    case protocolError, service(UInt32), disconnected, incomplete, timedOut, backlog
    /// Static stage names and numeric frame metadata only; never transcript/credential content.
    case protocolDetails(String)
    case transport(httpStatus: Int?, networkCode: Int?, closeCode: Int?, logID: String?)
    var errorDescription: String? {
        switch self {
        case .protocolError: "豆包返回了无效协议数据；已保留确定原文。"
        case .protocolDetails(let details): "豆包协议解析失败（\(details)）；已保留确定原文。"
        case .service(let code): "豆包拒绝了请求（\(code)）。请检查 API Key、模型开通状态、额度和参数。"
        case .disconnected: "豆包连接中断；请检查网络、API Key 和模型权限，暂停后恢复连接。"
        case .incomplete: "豆包未确认最后的分句，已标记待核对区间。"
        case .timedOut: "豆包转录收尾超时，最后的结果未确认。"
        case .backlog: "豆包音频发送积压超过 5 秒；请检查网络，暂停后恢复连接。"
        case let .transport(http, network, close, logID):
            Self.transportMessage(http: http, network: network, close: close, logID: logID)
        }
    }

    static func transportMessage(http: Int?, network: Int?, close: Int?, logID: String?) -> String {
        let explanation: String
        switch http {
        case 401: explanation = "豆包鉴权失败：API Key 无效或已失效，请在设置中更新。"
        case 403: explanation = "豆包鉴权或资源权限校验未通过：请检查 API Key 是否有效，以及流式语音识别 2.0 小时版是否已开通并授权。"
        case 429: explanation = "豆包请求受限：请检查账户额度及并发限制，稍后重试。"
        case 400, 404: explanation = "豆包 WebSocket 握手被拒绝，请核对接口与请求参数。"
        default:
            switch network {
            case NSURLErrorTimedOut: explanation = "连接豆包超时，请检查网络或代理配置。"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: explanation = "无法解析豆包服务地址，请检查 DNS 或网络配置。"
            case NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
                explanation = "豆包网络连接失败，请检查网络或代理配置。"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                explanation = "豆包 TLS 连接失败，请检查系统时间、证书或网络代理。"
            default: explanation = "豆包 WebSocket 连接失败；请根据下方状态码检查连接。"
            }
        }
        let codes = [http.map { "HTTP \($0)" }, network.map { "URLSession \($0)" }, close.map { "WebSocket \($0)" }].compactMap { $0 }
        let safeLog = logID.flatMap { value -> String? in
            guard !value.isEmpty, value.count <= 128,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
            return value
        }
        return explanation + (codes.isEmpty ? "" : " [" + codes.joined(separator: "; ") + "]")
            + (safeLog.map { " · Log ID: " + $0 } ?? "")
    }

    static func connectionFailure(_ error: Error?, task: URLSessionWebSocketTask, closeCode: Int? = nil) -> DoubaoError {
        let nsError = error as NSError?
        let http = task.response as? HTTPURLResponse
        return .transport(httpStatus: http?.statusCode,
            networkCode: nsError?.domain == NSURLErrorDomain ? nsError?.code : nil,
            closeCode: closeCode ?? (task.closeCode == .invalid ? nil : task.closeCode.rawValue),
            logID: http?.value(forHTTPHeaderField: "X-Tt-Logid"))
    }
}

enum DoubaoProtocol {
    static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    static let resource = "volc.seedasr.sauc.duration"
    static let maximumPayload = 8 * 1024 * 1024
    struct Response { let payload: Data; let isLast: Bool }

    /// Schema names only for explicit integration probes. Never include text, field values or credentials.
    static func speakerSchema(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = (root["result"] as? [String: Any]) ?? (root["result"] as? [[String: Any]])?.first,
              let utterance = (result["utterances"] as? [[String: Any]])?.first else { return nil }
        let words = utterance["words"] as? [[String: Any]] ?? []
        let word = words.first(where: { $0["additions"] != nil || $0["speaker"] != nil || $0["speaker_id"] != nil }) ?? words.first ?? [:]
        let paths: [(String, Any?)] = [
            ("root", root), ("result", result), ("result.additions", result["additions"]),
            ("utterance", utterance), ("utterance.additions", utterance["additions"]),
            ("word", word), ("word.additions", word["additions"])
        ]
        return paths.map { path, value in
            let object = value as? [String: Any] ?? [:]
            let kind = value is [String: Any] ? "object" : value is String ? "string" : value == nil ? "missing" : "other"
            let names = object.keys.filter { key in
                !key.isEmpty && key.count <= 40 && key.utf8.allSatisfy { (97...122).contains($0) || $0 == 95 }
            }.sorted().prefix(30)
            return path + ":" + kind + "=[" + names.joined(separator: ",") + "]"
        }.joined(separator: "; ")
    }

    static func speakerObservations(_ data: Data) -> [DoubaoSpeakerObservation] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let results = (root["result"] as? [String: Any]).map { [$0] } ?? (root["result"] as? [[String: Any]]) ?? []
        func time(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init) }
        return results.flatMap { $0["utterances"] as? [[String: Any]] ?? [] }.map { utterance in
            let additions = utterance["additions"] as? [String: Any]
            let label = additions?["speaker_id"] ?? additions?["speaker"] ?? utterance["speaker_id"] ?? utterance["speaker"]
            return .init(start: time(utterance["start_time"]) ?? 0, end: time(utterance["end_time"]),
                definite: utterance["definite"] as? Bool == true,
                speakerID: (label as? String) ?? (label as? NSNumber)?.stringValue)
        }
    }

    static func configuration(settings: AppSettings, source: AudioSource, sessionID: String,
                              responseMode: DoubaoResponseMode = .single) throws -> Data {
        try settings.validateSpeechConfiguration()
        var request: [String: Any] = [
            "model_name": "bigmodel", "enable_nonstream": true,
            "enable_speaker_info": source != .microphone, "ssd_version": "200",
            "show_utterances": true, "enable_itn": true, "enable_punc": true,
            "enable_ddc": false, "result_type": responseMode.rawValue, "end_window_size": 800
        ]
        if !settings.effectiveDoubao.hotwords.isEmpty {
            let context = try JSONSerialization.data(withJSONObject: ["hotwords": settings.effectiveDoubao.hotwords.map { ["word": $0] }])
            request["corpus"] = ["context": String(decoding: context, as: UTF8.self)]
        }
        return try JSONSerialization.data(withJSONObject: [
            "user": ["uid": sessionID],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": request
        ], options: [.sortedKeys])
    }

    static func frame(_ payload: Data, configuration: Bool = false, last: Bool = false) -> Data {
        var bytes: [UInt8] = [0x11, configuration ? 0x10 : (last ? 0x22 : 0x20), configuration ? 0x10 : 0x00, 0]
        let size = UInt32(payload.count)
        bytes += [UInt8(truncatingIfNeeded: size >> 24), UInt8(truncatingIfNeeded: size >> 16),
                  UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)]
        return Data(bytes) + payload
    }

    static func decode(_ data: Data) throws -> Response {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] >> 4 == 1 else { throw DoubaoError.protocolDetails("header; bytes=\(bytes.count)") }
        let header = Int(bytes[0] & 0x0f) * 4
        guard header >= 4, header <= bytes.count - 4 else { throw DoubaoError.protocolDetails("header-size=\(header); bytes=\(bytes.count)") }
        let kind = bytes[1] >> 4, flags = bytes[1] & 0x0f
        guard kind == 9 || kind == 15 else { throw DoubaoError.protocolDetails("type=\(kind); flags=\(flags)") }
        var position = header
        func integer() throws -> UInt32 {
            guard position + 4 <= bytes.count else { throw DoubaoError.protocolDetails("integer; offset=\(position); bytes=\(bytes.count)") }
            let value = bytes[position..<(position + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            position += 4; return value
        }
        if kind == 15 { throw DoubaoError.service(try integer()) }
        if flags & 1 != 0 { _ = try integer() }
        let length = Int(try integer())
        guard length <= maximumPayload, length == bytes.count - position,
              bytes[2] >> 4 == 1 else {
            throw DoubaoError.protocolDetails("length=\(length); remaining=\(bytes.count - position); encoding=\(bytes[2] >> 4); flags=\(flags)")
        }
        var payload = Data(bytes[position...])
        switch bytes[2] & 0x0f {
        case 0: break
        case 1:
            do { payload = try gunzip(payload) }
            catch { throw DoubaoError.protocolDetails("gzip; bytes=\(payload.count)") }
        default: throw DoubaoError.protocolDetails("compression=\(bytes[2] & 0x0f)")
        }
        return .init(payload: payload, isLast: flags & 2 != 0)
    }

    private static func gunzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw DoubaoError.protocolError
        }
        defer { inflateEnd(&stream) }
        return try input.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
                    stream.next_out = raw.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(raw.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                guard result.count + count <= maximumPayload else { throw DoubaoError.protocolError }
                result.append(contentsOf: buffer.prefix(count))
                if status == Z_STREAM_END { return result }
                guard status == Z_OK, count > 0 else { throw DoubaoError.protocolError }
            }
        }
    }
}

struct DoubaoTranscriptParser {
    let sessionID: String
    let source: AudioSource
    let offset: TimeInterval
    private var confirmed: [String: TranscriptSegment] = [:]
    private(set) var partial = ""
    init(sessionID: String, source: AudioSource, offset: TimeInterval) {
        self.sessionID = sessionID; self.source = source; self.offset = offset
    }

    private func milliseconds(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let string = value as? String, string.count <= 32 { return Double(string) }
        return nil
    }

    mutating func parse(_ data: Data) throws -> [TranscriptSegment] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw DoubaoError.protocolDetails("json; bytes=\(data.count)") }
        if let code = root["code"] as? NSNumber, code.uint32Value != 0 && code.uint32Value != 20000000 {
            throw DoubaoError.service(code.uint32Value)
        }
        guard let value = root["result"] else { return [] } // Configuration acknowledgment.
        let results: [[String: Any]]
        if let single = value as? [String: Any] { results = [single] }
        else if let array = value as? [[String: Any]] { results = array }
        else { throw DoubaoError.protocolDetails(value is NSNull ? "result=null" : "result-type") }
        var output: [TranscriptSegment] = [], temporary: [String] = []
        for result in results {
            guard let utterances = result["utterances"] as? [[String: Any]] else {
                if let text = result["text"] as? String, !text.isEmpty { temporary.append(text) }
                continue
            }
            for utterance in utterances {
                guard let text = utterance["text"] as? String else { throw DoubaoError.protocolDetails("utterance.text") }
                if text.isEmpty { continue }
                guard utterance["definite"] as? Bool == true else { temporary.append(text); continue }
                // The service may omit the zero start of the first utterance. Do not
                // use this default for unrelated later utterances or an explicit null.
                let start: Double?
                if utterance["start_time"] == nil {
                    start = confirmed.isEmpty || confirmed["u0"]?.originalText == text ? 0 : nil
                } else { start = milliseconds(utterance["start_time"]) }
                guard let start, let end = milliseconds(utterance["end_time"]) else {
                    throw DoubaoError.protocolDetails("utterance-time-types")
                }
                guard start.isFinite, end.isFinite, start >= 0, end >= start,
                      end < Double(Int64.max), offset.isFinite, offset >= 0 else {
                    throw DoubaoError.protocolDetails("utterance-time-range")
                }
                let id = "u\(Int64(start))"
                let additions = utterance["additions"] as? [String: Any]
                let speaker = additions?["speaker_id"] ?? additions?["speaker"]
                    ?? utterance["speaker_id"] ?? utterance["speaker"]
                let speakerID = (speaker as? String) ?? (speaker as? NSNumber)?.stringValue ?? "unknown"
                let segment = TranscriptSegment(sessionID: sessionID, resultID: id, source: source,
                    start: offset + start / 1000, end: offset + end / 1000,
                    text: text, speakerID: source == .microphone ? "me" : "\(sessionID):\(speakerID)")
                if let previous = confirmed[id] {
                    guard previous == segment else { throw MeetingError.conflictingResult }
                } else { confirmed[id] = segment; output.append(segment) }
            }
        }
        partial = temporary.joined(separator: " ")
        return output
    }
}
