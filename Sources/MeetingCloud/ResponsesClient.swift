import Foundation
import MeetingCore

/// Select authentication before any credentials are resolved. Proxy calls do not access AWS profiles.
public struct ResponsesClient: AITextGenerating {
    private let bedrock: any AITextGenerating
    private let proxy: any AITextGenerating
    public init(bedrock: any AITextGenerating = BedrockResponsesClient(),
                proxy: any AITextGenerating = ProxyResponsesClient()) {
        self.bedrock = bedrock; self.proxy = proxy
    }
    public func generate(instructions: String, input: String, configuration: ModelConfiguration,
                         profile: String, maxOutputTokens: Int = 16_384) async throws -> AITextResponse {
        let resolved = try AIModelCatalog.resolve(configuration)
        let client = resolved.effectiveProvider == .bedrockRuntime ? bedrock : proxy
        return try await client.generate(instructions: instructions, input: input, configuration: resolved,
                                         profile: profile, maxOutputTokens: maxOutputTokens)
    }
}

public final class ProxyResponsesClient: AITextGenerating, @unchecked Sendable {
    private let session: URLSession
    private let keyReader: @Sendable (String) throws -> String?
    public convenience init(apiKey: String? = nil) {
        self.init(sessionConfiguration: .ephemeral, keyReader: { endpoint in
            if let apiKey { return apiKey }
            return try ModelAPIKeychain.read(endpoint: endpoint)
        })
    }
    init(sessionConfiguration: URLSessionConfiguration, keyReader: @escaping @Sendable (String) throws -> String?) {
        sessionConfiguration.timeoutIntervalForRequest = 300
        sessionConfiguration.timeoutIntervalForResource = 360
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        session = URLSession(configuration: sessionConfiguration, delegate: NoRedirects(), delegateQueue: nil)
        self.keyReader = keyReader
    }
    deinit { session.invalidateAndCancel() }

    static func request(body: Data, endpoint: URL, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try ModelAPIKeychain.validatedKey(apiKey))", forHTTPHeaderField: "Authorization")
        return request
    }
    public func generate(instructions: String, input: String, configuration: ModelConfiguration,
                         profile: String, maxOutputTokens: Int = 16_384) async throws -> AITextResponse {
        let resolved = try AIModelCatalog.resolve(configuration)
        guard resolved.effectiveProvider == .responsesProxy else { throw AIError.configuration("此调用需要第三方 Responses API 配置。") }
        let endpoint = try ResponsesEndpoint.url(resolved.proxyURL ?? "")
        try Task.checkCancellation()
        guard let key = try keyReader(endpoint.absoluteString) else { throw ModelProviderError.missingKey }
        let body = try BedrockResponsesClient.requestBody(instructions: instructions, input: input,
            configuration: resolved, maxOutputTokens: maxOutputTokens)
        let request = try Self.request(body: body, endpoint: endpoint, apiKey: key)
        let started = Date()
        try Task.checkCancellation()
        // Neither redirects nor automatic inference retries may send data/keys to another destination.
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AIError.invalidOutput("模型服务未返回 HTTP 响应。") }
        guard (200..<300).contains(response.statusCode) else {
            let reason: String
            switch response.statusCode {
            case 401, 403: reason = "请检查此代理地址的 API Key 和模型访问权限。"
            case 404: reason = "请检查代理 Responses API 地址和 Model ID。"
            case 400, 422: reason = "模型或参数被拒绝。请检查 Model ID，并尝试将推理强度设为服务默认。"
            case 429: reason = "调用配额或限流，请稍后手动重试。"
            case 300..<400: reason = "代理返回了重定向。请填写最终 Responses API 地址。"
            default: reason = "模型服务暂时不可用；已保留现有资料，可从失败阶段重试。"
            }
            // Do not persist remote error bodies: proxies may echo the request, URL or credentials.
            throw AIError.service(response.statusCode, reason)
        }
        return try BedrockResponsesClient.decode(data, model: resolved.modelID, endpoint: endpoint.absoluteString, startedAt: started)
    }
}
