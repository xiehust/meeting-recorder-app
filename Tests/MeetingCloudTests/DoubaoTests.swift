import Foundation
import Testing
import MeetingCore
@testable import MeetingCloud

private func response(_ object: Any, last: Bool = false) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: object)
    let n = UInt32(payload.count)
    return Data([0x11, last ? 0x93 : 0x91, 0x10, 0, 0, 0, 0, 1,
                 UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                 UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]) + payload
}
private func result(_ text: String, definite: Bool, speaker: String = "1") -> [String: Any] {
    ["result": ["text": text, "utterances": [["text": text, "definite": definite,
        "start_time": 100, "end_time": 800, "additions": ["speaker": speaker]]]]]
}

@Test func doubaoRequestSelectsTwoPassASR2AndPreservesSpeech() throws {
    var settings = AppSettings(); settings.speechProvider = .doubao
    let data = try DoubaoProtocol.configuration(settings: settings, source: .mixed, sessionID: "test")
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let request = try #require(object["request"] as? [String: Any])
    let audio = try #require(object["audio"] as? [String: Any])
    #expect(DoubaoProtocol.resource == "volc.seedasr.sauc.duration")
    #expect(DoubaoProtocol.endpoint.lastPathComponent == "bigmodel_async")
    #expect(request["enable_nonstream"] as? Bool == true)
    #expect(request["enable_speaker_info"] as? Bool == true)
    #expect(request["ssd_version"] as? String == "200")
    #expect(request["enable_ddc"] as? Bool == false)
    #expect(audio["channel"] as? Int == 1 && audio["language"] == nil)
}

@Test func doubaoOnlyCommitsDefiniteSentencesAndDeduplicatesReplays() throws {
    var parser = DoubaoTranscriptParser(sessionID: "s", source: .mixed, offset: 60)
    #expect(try parser.parse(JSONSerialization.data(withJSONObject: result("不确定的文字", definite: false))).isEmpty)
    #expect(parser.partial == "不确定的文字")
    let final = try JSONSerialization.data(withJSONObject: result("确认后的文字", definite: true))
    let segments = try parser.parse(final)
    #expect(segments.count == 1 && parser.partial.isEmpty)
    #expect(segments[0].start == 60.1 && segments[0].end == 60.8)
    #expect(segments[0].source == .mixed && segments[0].originalSpeakerID == "s:1")
    #expect(try parser.parse(final).isEmpty)
    #expect(throws: MeetingError.self) { try parser.parse(JSONSerialization.data(withJSONObject: result("改写确定原文", definite: true))) }
}

@Test func doubaoBinaryFramesEnforceSizeFlagsAndDoNotLeakServiceMessages() throws {
    let last = DoubaoProtocol.frame(Data([1, 2]), last: true)
    #expect(Array(last.prefix(8)) == [0x11, 0x22, 0, 0, 0, 0, 0, 2])
    let valid = try response(result("测试", definite: true), last: true)
    #expect(try DoubaoProtocol.decode(valid).isLast)
    #expect(throws: DoubaoError.self) { try DoubaoProtocol.decode(valid.dropLast()) }
    #expect(throws: DoubaoError.self) { try DoubaoProtocol.decode(Data([0x11, 0x90])) }
    let error = Data([0x11, 0xf0, 0x10, 0, 0x02, 0xae, 0xa5, 0x41, 0, 0, 0, 0])
    #expect(throws: DoubaoError.self) { try DoubaoProtocol.decode(error) }
}

private actor FakeDoubaoSocket: DoubaoSocket {
    let omitFinal: Bool
    let openFailure: DoubaoError?
    init(omitFinal: Bool = false, openFailure: DoubaoError? = nil) {
        self.omitFinal = omitFinal; self.openFailure = openFailure
    }
    var opens = 0
    var audioBytes = 0
    var finalRequests = 0
    var configurationFrames = 0
    var receivedKey: String?
    var didClose = false
    private var messages: [Data] = []
    private var waiting: CheckedContinuation<Data, Error>?
    private var closed = false
    func open(apiKey: String, sessionID: String) throws {
        opens += 1; receivedKey = apiKey
        if let openFailure { throw openFailure }
    }
    func send(_ data: Data) throws {
        if data[1] == 0x10 { configurationFrames += 1; push(try response([:])) }
        else if data[1] == 0x22 {
            finalRequests += 1
            if !omitFinal { push(try response(result("最终发言", definite: true), last: true)) }
        } else {
            audioBytes += data.count - 8
            push(try response(result("临时发", definite: false)))
        }
    }
    private func push(_ data: Data) {
        if let waiter = waiting { waiting = nil; waiter.resume(returning: data) }
        else { messages.append(data) }
    }
    func receive() async throws -> Data {
        if !messages.isEmpty { return messages.removeFirst() }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func close() { didClose = true; closed = true; waiting?.resume(throwing: CancellationError()); waiting = nil }
}
private actor DoubaoEvents {
    var segments: [TranscriptSegment] = []
    var seconds = 0.0
    var ended = false
    var failures: [String] = []
    func receive(_ event: TranscriptionUpdate) {
        switch event {
        case .final(_, let values): segments += values
        case .usage(let value): seconds += value
        case .ended: ended = true
        case .failed(let message): failures.append(message)
        default: break
        }
    }
}

@Test func doubaoStreamingDrainsFinalAudioUsesOneConnectionAndRecordsUsage() async throws {
    let socket = FakeDoubaoSocket(), events = DoubaoEvents()
    let stream = DoubaoTranscriptionStream(apiKey: "test-only", socket: socket)
    var settings = AppSettings(); settings.speechProvider = .doubao
    stream.start(settings: settings, source: .mixed, offset: 0) { await events.receive($0) }
    stream.start(settings: settings, source: .mixed, offset: 10) { await events.receive($0) }
    stream.send(Data(repeating: 0, count: 6400)); stream.finish()
    await stream.waitUntilFinished()
    #expect(await socket.opens == 1)
    #expect(await socket.finalRequests == 1)
    #expect(await socket.audioBytes == 6400)
    #expect(await events.failures.isEmpty)
    #expect(await events.ended)
    #expect(await events.segments.count == 1)
    #expect(await events.seconds == 0.2)
}

@Test func doubaoFinishBeforeFirstAudioDoesNotOpenAConnection() async {
    let socket = FakeDoubaoSocket()
    let stream = DoubaoTranscriptionStream(apiKey: "test-only", socket: socket)
    stream.finish(); stream.start(settings: .init(), source: .mixed, offset: 0) { _ in }
    await stream.waitUntilFinished()
    #expect(await socket.opens == 0)
}

@Test func doubaoDrainTimeoutPreservesPartialInsteadOfInventingFinalText() async {
    let socket = FakeDoubaoSocket(omitFinal: true), events = DoubaoEvents()
    let stream = DoubaoTranscriptionStream(apiKey: "test-only", socket: socket, drainTimeout: .milliseconds(20))
    var settings = AppSettings(); settings.speechProvider = .doubao
    stream.start(settings: settings, source: .mixed, offset: 0) { await events.receive($0) }
    stream.send(Data(repeating: 0, count: 3200)); stream.finish()
    await stream.waitUntilFinished()
    #expect(await events.segments.isEmpty)
    #expect(await events.failures.contains { $0.contains("收尾超时") })
    #expect(await !events.ended)
}

@Test func doubaoBackpressureStopsWithoutSendingAnUnboundedPacket() async {
    let socket = FakeDoubaoSocket(), events = DoubaoEvents()
    let stream = DoubaoTranscriptionStream(apiKey: "test-only", socket: socket)
    var settings = AppSettings(); settings.speechProvider = .doubao
    stream.start(settings: settings, source: .mixed, offset: 0) { await events.receive($0) }
    stream.send(Data(repeating: 0, count: 160_002))
    await stream.waitUntilFinished()
    #expect(await socket.audioBytes == 0)
    #expect(await events.failures.contains { $0.contains("积压") })
}

@Test func doubaoDecoderAcceptsGzipResponses() throws {
    let compressed = Data(base64Encoded: "H4sIAAAAAAAC/6tWKkotLs0pUbKqVipJrQDSSkq1tQC4FWdxFgAAAA==")!
    var frame = Data([0x11, 0x93, 0x11, 0, 0, 0, 0, 1, 0, 0, 0, UInt8(compressed.count)])
    frame.append(compressed)
    let decoded = try DoubaoProtocol.decode(frame)
    #expect(decoded.isLast)
    #expect(String(decoding: decoded.payload, as: UTF8.self) == #"{"result":{"text":""}}"#)
}

@Test func credentialCheckUsesAnAuthenticatedHandshakeWithoutAudioOrConfiguration() async throws {
    let socket = FakeDoubaoSocket()
    try await DoubaoCredentialCheck.check(apiKey: " test-only ", socket: socket)
    #expect(await socket.opens == 1)
    #expect(await socket.receivedKey == "test-only")
    #expect(await socket.audioBytes == 0)
    #expect(await socket.configurationFrames == 0)
    #expect(await socket.finalRequests == 0)
    #expect(await socket.didClose)
}

@Test func credentialCheckRejectsInvalidKeyBeforeConnectingAndPreservesForbiddenStatus() async {
    let invalid = FakeDoubaoSocket()
    await #expect(throws: SpeechConfigurationError.self) {
        try await DoubaoCredentialCheck.check(apiKey: "invalid\nheader", socket: invalid)
    }
    #expect(await invalid.opens == 0)
    let forbidden = FakeDoubaoSocket(openFailure: .transport(httpStatus: 403, networkCode: -1011, closeCode: nil, logID: "TEST_LOG_123"))
    do {
        try await DoubaoCredentialCheck.check(apiKey: "test-only", socket: forbidden)
        Issue.record("Forbidden credentials must not pass")
    } catch {
        #expect(error.localizedDescription.contains("HTTP 403"))
        #expect(error.localizedDescription.contains("TEST_LOG_123"))
    }
    #expect(await forbidden.didClose)
}

@Test func handshakeCompletionHandlesEarlyCallbacksAndCancellationWithoutHanging() async throws {
    let opened = DoubaoHandshake()
    opened.resolve(.success(()))
    opened.resolve(.failure(DoubaoError.disconnected))
    try await opened.wait()
    let pending = DoubaoHandshake()
    let task = Task { try await pending.wait() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func connectionDiagnosticsAreSpecificWithoutEchoingUntrustedErrorText() throws {
    let request = URLSessionDoubaoSocket.request(apiKey: "test-only", sessionID: "test-session")
    #expect(request.url == DoubaoProtocol.endpoint)
    #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-only")
    #expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.seedasr.sauc.duration")
    let forbidden = DoubaoError.transportMessage(http: 403, network: -1011, close: nil, logID: "https://example.test/?secret=value")
    #expect(forbidden.contains("HTTP 403"))
    #expect(!forbidden.contains("secret") && !forbidden.contains("example.test"))
    #expect(DoubaoError.transportMessage(http: nil, network: NSURLErrorTimedOut, close: nil, logID: nil).contains("超时"))
    var parser = DoubaoTranscriptParser(sessionID: "s", source: .mixed, offset: 0)
    #expect(throws: DoubaoError.self) { try parser.parse(Data("not-json".utf8)) }
}

@Test func doubaoHandlesOmittedZeroStartAndNumericStringTimestamps() throws {
    var parser = DoubaoTranscriptParser(sessionID: "s", source: .mixed, offset: 10)
    let first = #"{"result":{"utterances":[{"text":"第一句","definite":true,"end_time":800,"additions":{"speaker":"1"}}]}}"#
    let values = try parser.parse(Data(first.utf8))
    #expect(values.first?.start == 10)
    #expect(values.first?.end == 10.8)
    #expect(try parser.parse(Data(first.utf8)).isEmpty)
    let second = #"{"result":{"utterances":[{"text":"第二句","definite":true,"start_time":"1200","end_time":"2000"}]}}"#
    #expect(try parser.parse(Data(second.utf8)).first?.start == 11.2)
    let missingLaterStart = #"{"result":{"utterances":[{"text":"不能猜起点","definite":true,"end_time":3000}]}}"#
    #expect(throws: DoubaoError.self) { try parser.parse(Data(missingLaterStart.utf8)) }
}

@Test func doubaoStillRejectsNullBooleanAndInvalidTimeRanges() throws {
    for times in [#""start_time":null,"end_time":100"#, #""start_time":false,"end_time":100"#,
                  #""start_time":100,"end_time":50"#, #""start_time":0,"end_time":"NaN"#,
                  #""start_time":0,"end_time":1e100"#] {
        var parser = DoubaoTranscriptParser(sessionID: "s", source: .mixed, offset: 0)
        let json = "{\"result\":{\"utterances\":[{\"text\":\"test\",\"definite\":true," + times + "}]}}"
        #expect(throws: DoubaoError.self) { try parser.parse(Data(json.utf8)) }
    }
}

@Test func doubaoReadsASR2SpeakerIDsAndKeepsDifferentPeopleSeparate() throws {
    var parser = DoubaoTranscriptParser(sessionID: "s", source: .mixed, offset: 0)
    let response = #"{"result":{"utterances":[{"text":"first speaker","definite":true,"end_time":800,"additions":{"speaker_id":"0"}},{"text":"second speaker","definite":true,"start_time":1200,"end_time":2000,"additions":{"speaker_id":1}}]}}"#
    let values = try parser.parse(Data(response.utf8))
    #expect(values.map(\.originalSpeakerID) == ["s:0", "s:1"])
    #expect(try parser.parse(Data(response.utf8)).isEmpty)
    let schema = try #require(DoubaoProtocol.speakerSchema(Data(response.utf8)))
    #expect(schema.contains("speaker_id"))
    #expect(!schema.contains("first speaker") && !schema.contains("second speaker"))
}

@Test func speakerAuditChangesOnlyTheResponseModeAndObservesRawLabels() throws {
    var settings = AppSettings(); settings.speechProvider = .doubao
    var single = try #require(JSONSerialization.jsonObject(with: DoubaoProtocol.configuration(settings: settings,
        source: .mixed, sessionID: "same", responseMode: .single)) as? [String: Any])
    let full = try #require(JSONSerialization.jsonObject(with: DoubaoProtocol.configuration(settings: settings,
        source: .mixed, sessionID: "same", responseMode: .full)) as? [String: Any])
    var request = try #require(single["request"] as? [String: Any])
    request["result_type"] = "full"; single["request"] = request
    #expect(NSDictionary(dictionary: single).isEqual(to: full))
    let payload = #"{"result":{"utterances":[{"text":"hidden text","end_time":800,"definite":false,"additions":{"speaker_id":"-1"}},{"text":"hidden text","start_time":0,"end_time":800,"definite":true,"additions":{"speaker_id":"0"}}]}}"#
    let values = DoubaoProtocol.speakerObservations(Data(payload.utf8))
    #expect(values.map(\.speakerID) == ["-1", "0"])
    #expect(values.map(\.definite) == [false, true])
    #expect(values.map(\.start) == [0, 0])
}
