import Foundation
import MeetingCore

protocol DoubaoSocket: Sendable {
    func open(apiKey: String, sessionID: String) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

actor URLSessionDoubaoSocket: DoubaoSocket {
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var handshake: DoubaoHandshake?
    func open(apiKey: String, sessionID: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let handshake = DoubaoHandshake()
        let session = URLSession(configuration: configuration, delegate: handshake, delegateQueue: nil)
        let socket = session.webSocketTask(with: Self.request(apiKey: apiKey, sessionID: sessionID))
        socket.maximumMessageSize = DoubaoProtocol.maximumPayload + 128
        self.session = session; self.socket = socket; self.handshake = handshake
        socket.resume()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await handshake.wait() }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw DoubaoError.transport(httpStatus: nil, networkCode: NSURLErrorTimedOut, closeCode: nil, logID: nil)
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch { close(); throw error }
    }
    static func request(apiKey: String, sessionID: String) -> URLRequest {
        var request = URLRequest(url: DoubaoProtocol.endpoint)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(DoubaoProtocol.resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(sessionID, forHTTPHeaderField: "X-Api-Connect-Id")
        return request
    }
    func send(_ data: Data) async throws {
        guard let socket else { throw DoubaoError.disconnected }
        do { try await socket.send(.data(data)) }
        catch { throw DoubaoError.connectionFailure(error, task: socket) }
    }
    func receive() async throws -> Data {
        guard let socket else { throw DoubaoError.disconnected }
        do {
            switch try await socket.receive() {
            case .data(let data): return data
            case .string(let text): throw DoubaoError.protocolDetails("websocket-text; bytes=\(text.utf8.count)")
            @unknown default: throw DoubaoError.protocolError
            }
        } catch let error as DoubaoError { throw error }
        catch { throw DoubaoError.connectionFailure(error, task: socket) }
    }
    func close() {
        handshake?.resolve(.failure(CancellationError())); handshake = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
}

/// `resume()` only starts a connection attempt. Wait for the actual WebSocket upgrade.
final class DoubaoHandshake: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result) }
                else { self.continuation = continuation; lock.unlock() }
            }
        } onCancel: { resolve(.failure(CancellationError())) }
    }
    func resolve(_ value: Result<Void, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let waiting = continuation; continuation = nil
        lock.unlock()
        waiting?.resume(with: value)
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        resolve(.success(()))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let task = task as? URLSessionWebSocketTask else { return }
        resolve(.failure(DoubaoError.connectionFailure(error, task: task)))
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        resolve(.failure(DoubaoError.connectionFailure(nil, task: webSocketTask, closeCode: closeCode.rawValue)))
    }
}

public final class DoubaoTranscriptionStream: StreamingTranscribing, @unchecked Sendable {
    public let sessionID = UUID().uuidString
    private let apiKey: String
    private let socket: any DoubaoSocket
    private let drainTimeout: Duration
    private let diagnostics: (@Sendable (String) async -> Void)?
    private let responseMode: DoubaoResponseMode
    private let speakerObserver: (@Sendable ([DoubaoSpeakerObservation]) async -> Void)?
    private let input: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var acceptsStart = true
    private var pendingBytes = 0
    private var drainExpired = false
    private var terminalError: DoubaoError?

    public convenience init(apiKey: String, diagnostics: (@Sendable (String) async -> Void)? = nil,
                            responseMode: DoubaoResponseMode = .single,
                            speakerObserver: (@Sendable ([DoubaoSpeakerObservation]) async -> Void)? = nil) {
        self.init(apiKey: apiKey, socket: URLSessionDoubaoSocket(), diagnostics: diagnostics,
                  responseMode: responseMode, speakerObserver: speakerObserver)
    }
    init(apiKey: String, socket: any DoubaoSocket, drainTimeout: Duration = .seconds(30),
         diagnostics: (@Sendable (String) async -> Void)? = nil, responseMode: DoubaoResponseMode = .single,
         speakerObserver: (@Sendable ([DoubaoSpeakerObservation]) async -> Void)? = nil) {
        self.apiKey = apiKey; self.socket = socket; self.drainTimeout = drainTimeout
        self.diagnostics = diagnostics
        self.responseMode = responseMode; self.speakerObserver = speakerObserver
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(50))
        input = pair.stream; continuation = pair.continuation
    }
    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        let action = lock.withLock { () -> Int in
            guard acceptsStart else { return 0 }
            guard pendingBytes + data.count <= 160_000 else { return 2 }
            pendingBytes += data.count; return 1
        }
        if action == 0 { return }
        if action == 2 { failBacklog(); return }
        if case .dropped = continuation.yield(data) { failBacklog() }
    }
    private func failBacklog() {
        lock.withLock { terminalError = .backlog; acceptsStart = false }
        continuation.finish(throwing: DoubaoError.backlog)
        Task { [socket] in await socket.close() }
    }
    public func finish() {
        lock.withLock { acceptsStart = false }
        continuation.finish()
    }
    public func cancel() {
        finish(); currentTask()?.cancel()
    }
    public func waitUntilFinished() async { await currentTask()?.value }
    private func currentTask() -> Task<Void, Never>? { lock.withLock { task } }

    public func start(settings: AppSettings, source: AudioSource, offset: TimeInterval,
                      receive: @escaping @Sendable (TranscriptionUpdate) async -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard acceptsStart, task == nil else { return }
        task = Task { [self] in
            var timeout: Task<Void, Never>?
            do {
                guard !apiKey.isEmpty else { throw SpeechConfigurationError.missingKey }
                let configuration = try DoubaoProtocol.configuration(settings: settings, source: source, sessionID: sessionID, responseMode: responseMode)
                try await withTaskCancellationHandler {
                    try await socket.open(apiKey: apiKey, sessionID: sessionID)
                    try await socket.send(DoubaoProtocol.frame(configuration, configuration: true))
                    await receive(.connected)
                    try await withThrowingTaskGroup(of: Bool.self) { group in
                        group.addTask { [self] in
                            for try await data in input {
                                try Task.checkCancellation()
                                try await socket.send(DoubaoProtocol.frame(data))
                                lock.withLock { pendingBytes -= data.count }
                                await receive(.usage(seconds: Double(data.count) / 32_000))
                            }
                            try Task.checkCancellation()
                            try await socket.send(DoubaoProtocol.frame(Data(), last: true))
                            return false
                        }
                        group.addTask { [self] in
                            var parser = DoubaoTranscriptParser(sessionID: sessionID, source: source, offset: offset)
                            while true {
                                try Task.checkCancellation()
                                let response = try DoubaoProtocol.decode(await socket.receive())
                                if let diagnostics, let schema = DoubaoProtocol.speakerSchema(response.payload) { await diagnostics(schema) }
                                if let speakerObserver { await speakerObserver(DoubaoProtocol.speakerObservations(response.payload)) }
                                let segments = try parser.parse(response.payload)
                                if !segments.isEmpty { await receive(.final(resultID: "live", segments: segments)) }
                                await receive(.partial(id: "live", text: parser.partial))
                                if response.isLast {
                                    guard parser.partial.isEmpty else { throw DoubaoError.incomplete }
                                    return true
                                }
                            }
                        }
                        do {
                            while let receivedLast = try await group.next() {
                                if receivedLast {
                                    group.cancelAll(); continuation.finish(); await socket.close()
                                    break
                                }
                                timeout = Task { [self] in
                                    do {
                                        try await Task.sleep(for: drainTimeout)
                                        lock.withLock { drainExpired = true }
                                        await socket.close()
                                    }
                                    catch { }
                                }
                            }
                        } catch {
                            group.cancelAll(); continuation.finish(); await socket.close(); throw error
                        }
                    }
                } onCancel: { [socket, continuation] in
                    continuation.finish()
                    Task { await socket.close() }
                }
                timeout?.cancel()
                await receive(.ended)
            } catch {
                timeout?.cancel(); continuation.finish(); await socket.close()
                // Never surface transport errors that may contain headers, URLs, audio or transcript data.
                let message: String
                if let recorded = lock.withLock({ terminalError }) { message = recorded.localizedDescription }
                else if lock.withLock({ drainExpired }) { message = DoubaoError.timedOut.localizedDescription }
                else if let error = error as? DoubaoError { message = error.localizedDescription }
                else if let error = error as? SpeechConfigurationError { message = error.localizedDescription }
                else if error is MeetingError { message = MeetingError.conflictingResult.localizedDescription }
                else { message = DoubaoError.disconnected.localizedDescription }
                await receive(.failed(message))
            }
        }
    }
}
