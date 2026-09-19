import Foundation
import Testing
import MeetingCore
import SmithyIdentity
@testable import MeetingCloud

private func proxyConfig(_ path: String = "success") -> ModelConfiguration {
    var config = ModelConfiguration()
    config.provider = .responsesProxy; config.customModelID = "vendor/custom-model"
    config.proxyURL = "https://proxy.example.com/\(path)/responses"; config.reasoningEffort = ""
    config.region = "not-an-aws-region"
    return config
}

@Test func customBedrockModelBypassesPresetCatalogWithoutRewritingIDOrRegion() async throws {
    var config = ModelConfiguration(); config.customModelID = "us.vendor.model-v2:0"
    config.region = "us-east-1"; config.reasoningEffort = ""
    let resolved = try AIModelCatalog.resolve(config)
    #expect(resolved.modelID == "us.vendor.model-v2:0")
    #expect(try AIModelCatalog.resolve(resolved) == resolved)
    let body = try BedrockResponsesClient.requestBody(instructions: "rules", input: "test", configuration: resolved, maxOutputTokens: 200)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["reasoning"] == nil)
    #expect(object["model"] as? String == config.customModelID)
    let request = try await BedrockResponsesClient.signedRequest(body: body, configuration: resolved,
        identity: AWSCredentialIdentity(accessKey: "TEST", secret: "test-only"))
    #expect(request.url?.absoluteString == "https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("/us-east-1/bedrock/aws4_request") == true)
}

@Test func customProxyModelRequiresExplicitModelAndUsesOptionalReasoning() throws {
    var config = proxyConfig()
    let resolved = try AIModelCatalog.resolve(config)
    #expect(resolved.modelID == "vendor/custom-model")
    #expect(resolved.endpoint == "responses")
    #expect(try AIModelCatalog.resolve(resolved) == resolved)
    config.customModelID = " "
    #expect(throws: AIError.self) { try AIModelCatalog.resolve(config) }
    config.customModelID = "model"; config.reasoningEffort = "high"
    let object = try JSONSerialization.jsonObject(with: BedrockResponsesClient.requestBody(instructions: "rules", input: "test",
        configuration: AIModelCatalog.resolve(config), maxOutputTokens: 200)) as? [String: Any]
    #expect((object?["reasoning"] as? [String: String])?["effort"] == "high")
}

@Test func proxyKeyIsBoundToCanonicalEndpointAndNeverAddsAWSHeaders() throws {
    #expect(try ModelAPIKeychain.account(for: "https://proxy.example.com/v1/") == ModelAPIKeychain.account(for: "https://PROXY.example.com:443/v1/responses"))
    #expect(try ModelAPIKeychain.account(for: "https://a.example.com/v1") != ModelAPIKeychain.account(for: "https://b.example.com/v1"))
    #expect(try ModelAPIKeychain.account(for: "https://a.example.com/one") != ModelAPIKeychain.account(for: "https://a.example.com/two"))
    let request = try ProxyResponsesClient.request(body: Data("{}".utf8), endpoint: ResponsesEndpoint.url("https://proxy.example.com"), apiKey: "test-key")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(request.value(forHTTPHeaderField: "x-amz-security-token") == nil)
    #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") == nil)
    #expect(throws: ModelProviderError.self) { try ModelAPIKeychain.validatedKey("key\r\nInjected: true") }
}

private actor ProviderSpy: AITextGenerating {
    private(set) var calls: [ModelConfiguration] = []
    var replies: [String]
    init(_ reply: String = "OK") { self.replies = [reply] }
    init(_ replies: [String]) { self.replies = replies }
    func generate(instructions: String, input: String, configuration: ModelConfiguration, profile: String, maxOutputTokens: Int) async throws -> AITextResponse {
        calls.append(configuration)
        let reply = replies.count > 1 ? replies.removeFirst() : (replies.first ?? "OK")
        return .init(text: reply, invocation: .init(responseID: "test", model: configuration.modelID,
            endpoint: configuration.destination, startedAt: Date(), durationSeconds: 0, inputTokens: 1, outputTokens: 1))
    }
}

private final class ProxyStub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "proxy.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let path = request.url!.path
        let code = path.contains("denied") ? 401 : path.contains("limited") ? 429 : path.contains("redirect") ? 307 : 200
        let body: String
        if code != 200 { body = #"{"error":{"message":"Authorization: Bearer test-key; private transcript"}}"# }
        else if path.contains("incomplete") { body = #"{"status":"incomplete","output":[]}"# }
        else { body = #"{"id":"resp-test","model":"actual-vendor-model","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}],"usage":{"input_tokens":7,"output_tokens":2}}"# }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "Location": "https://another.example.com/responses"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func count(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url?.path == "/\(path)/responses" }.count
    }
}

private func stubProxy(key: String? = "test-key") -> ProxyResponsesClient {
    let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [ProxyStub.self]
    return ProxyResponsesClient(sessionConfiguration: session, keyReader: { _ in key })
}

@Test func proxyResponsesRequestRunsWithoutAWSAndParsesActualModelAndUsage() async throws {
    let bedrock = ProviderSpy()
    let router = ResponsesClient(bedrock: bedrock, proxy: stubProxy())
    let reply = try await router.generate(instructions: "rules", input: "fixture", configuration: proxyConfig(), profile: "does-not-exist")
    #expect(reply.text == "OK")
    #expect(reply.invocation.model == "actual-vendor-model")
    #expect(reply.invocation.inputTokens == 7)
    #expect(reply.invocation.endpoint == "https://proxy.example.com/success/responses")
    #expect(await bedrock.calls.isEmpty)
    #expect(ProxyStub.count("success") == 1)
}

@Test func proxyErrorsNeverRetryFallbackOrExposeRemoteBody() async throws {
    let bedrock = ProviderSpy()
    let router = ResponsesClient(bedrock: bedrock, proxy: stubProxy())
    for path in ["denied", "limited", "redirect", "incomplete"] {
        do {
            _ = try await router.generate(instructions: "rules", input: "fixture", configuration: proxyConfig(path), profile: "unused")
            Issue.record("Expected failure for \(path)")
        } catch {
            #expect(!error.localizedDescription.contains("test-key"))
            #expect(!error.localizedDescription.contains("private transcript"))
        }
        #expect(ProxyStub.count(path) == 1)
    }
    #expect(await bedrock.calls.isEmpty)
    do {
        _ = try await stubProxy(key: nil).generate(instructions: "rules", input: "fixture", configuration: proxyConfig("missing-key"), profile: "unused")
        Issue.record("Missing key must fail before networking")
    } catch { #expect(error is ModelProviderError) }
    #expect(ProxyStub.count("missing-key") == 0)
}

private actor WorkflowCapture {
    var meeting: Meeting
    init(_ meeting: Meeting) { self.meeting = meeting }
    func receive(_ event: AIWorkflowEvent) throws { try meeting.applyAIEvent(event) }
}

@Test func summaryWorkflowUsesTheCorrectionVersionShownByTheSharedSourceSelector() async throws {
    var meeting = Meeting(title: "Test", applicationName: "Test", bundleID: "test", microphoneName: "Mic", settings: .init())
    try meeting.ingest(.init(sessionID: "s", resultID: "r", source: .application, start: 0, end: 2, text: "测试会议", speakerID: "one"))
    let input = AIInputSnapshot(meeting: meeting)
    var older = CorrectionVersion(input: input, configuration: .init(), profile: "default", chunkCount: 1)
    older.completedChunks = [0]
    var newest = CorrectionVersion(input: input, configuration: .init(), profile: "default", chunkCount: 1)
    newest.completedChunks = [0]
    let incomplete = CorrectionVersion(input: input, configuration: .init(), profile: "default", chunkCount: 2)
    meeting.correctionVersions = [older, newest, incomplete]
    let advertised = try #require(meeting.reusableCorrectionVersion)
    #expect(meeting.correctionVersionNumber(for: advertised.id) == 2)
    let client = ProviderSpy(#"{"overview":"测试会议","topics":[],"decisions":[],"actions":[],"questions":[],"limitations":[]}"#)
    let capture = WorkflowCapture(meeting)
    try await MeetingAIWorkflow(client: client).run(meeting: meeting, operation: .summary) {
        try await capture.receive($0)
    }
    let result = await capture.meeting
    #expect(result.minuteVersions?.last?.correctionVersionID == advertised.id)
    #expect(result.correctionVersions?.count == 3)
    #expect(await client.calls.count == 1)
}

@Test func correctionAndSummaryShareOneConnectionAndFreezeTheirOwnModelConfigurations() async throws {
    let bedrock = ProviderSpy()
    let proxy = ProviderSpy([#"{"changes":[],"warnings":[]}"#, #"{"overview":"测试会议","topics":[],"decisions":[],"actions":[],"questions":[],"limitations":[]}"#])
    var meeting = Meeting(title: "Test", applicationName: "Test", bundleID: "test", microphoneName: "Mic", settings: .init())
    try meeting.ingest(.init(sessionID: "s", resultID: "r", source: .application, start: 0, end: 2, text: "测试会议", speakerID: "one"))
    meeting.settings.correction = proxyConfig()
    meeting.settings.summary.customModelID = "summary-model"
    meeting.settings.summary.reasoningEffort = "high"
    let capture = WorkflowCapture(meeting)
    try await MeetingAIWorkflow(client: ResponsesClient(bedrock: bedrock, proxy: proxy)).run(meeting: meeting, operation: .full) {
        try await capture.receive($0)
    }
    #expect(await bedrock.calls.isEmpty)
    #expect(await proxy.calls.count == 2)
    let result = await capture.meeting
    #expect(result.correctionVersions?.last?.configuration.effectiveProvider == .responsesProxy)
    #expect(result.minuteVersions?.last?.configuration.effectiveProvider == .responsesProxy)
    #expect(result.minuteVersions?.last?.configuration.modelID == "summary-model")
    #expect(result.minuteVersions?.last?.configuration.reasoningEffort == "high")
    #expect(result.minuteVersions?.last?.configuration.proxyURL == result.correctionVersions?.last?.configuration.proxyURL)
    #expect(result.segments == meeting.segments)
}
