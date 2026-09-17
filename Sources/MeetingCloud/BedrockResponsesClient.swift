import Foundation
import AWSSDKIdentity
import AWSSDKHTTPAuth
import Smithy
import SmithyHTTPAPI
import SmithyHTTPAuthAPI
import SmithyIdentity
import ClientRuntime
import MeetingCore

public enum AIError: LocalizedError {
    case configuration(String), service(Int, String), invalidOutput(String), noTranscript, staleCorrection, locationRestricted
    public var errorDescription: String? {
        switch self {
        case .configuration(let message), .invalidOutput(let message): message
        case .service(let code, let message): "Bedrock 请求失败（HTTP \(code)）：\(message)"
        case .noTranscript: "没有可处理的确定转录。请先完成一次记录。"
        case .staleCorrection: "校对稿与当前转录版本不一致，请重新校对，或明确选择跳过校对。"
        case .locationRestricted: "Bedrock 不允许从当前访问国家或地区使用 OpenAI 模型。请在符合服务支持范围的环境中使用；应用不会自动更换模型或绕过限制。"
        }
    }
}

public enum AIModelCatalog {
    public static func modelID(_ model: ModelChoice) -> String {
        switch model {
        case .astra: "global.openai.gpt-6-astra"
        case .sol: "global.openai.gpt-5.6-sol"
        case .terra: "global.openai.gpt-5.6-terra"
        case .luna: "global.openai.gpt-5.6-luna"
        }
    }
    public static func efforts(for model: ModelChoice) -> [String] {
        model == .astra ? ["low", "medium", "high", "xhigh", "max"] : ["medium"]
    }
    public static func resolve(_ configuration: ModelConfiguration) throws -> ModelConfiguration {
        // Legacy meeting settings are upgraded for new calls only. Historical version metadata remains intact.
        guard ["runtime", "mantle"].contains(configuration.endpoint) else {
            throw AIError.configuration("当前接入 Bedrock Runtime Responses，请重新选择模型配置。")
        }
        guard configuration.region.range(of: #"^[a-z]{2}-[a-z]+-[0-9]+$"#, options: .regularExpression) != nil,
              !configuration.region.hasPrefix("cn-") else { throw AIError.configuration("Bedrock 区域格式无效或尚未支持。") }
        guard configuration.model != .astra || configuration.region == "us-west-2" else {
            throw AIError.configuration("Astra 当前只开放已验证的 us-west-2 区域；请在设置中明确选择该区域。")
        }
        guard efforts(for: configuration.model).contains(configuration.reasoningEffort) else {
            throw AIError.configuration("此模型的 \(configuration.reasoningEffort) 档位尚未开放验证；请在设置中选择支持的档位。")
        }
        let id = modelID(configuration.model)
        let legacyID = String(id.dropFirst("global.".count))
        guard configuration.modelID.isEmpty || configuration.modelID == id || configuration.modelID == legacyID else {
            throw AIError.configuration("模型显示名与实际 model ID 不一致，请重新选择模型。")
        }
        var result = configuration; result.modelID = id; result.endpoint = "runtime"
        return result
    }
}

public struct AITextResponse: Sendable {
    public let text: String
    public let invocation: AIInvocation
    public init(text: String, invocation: AIInvocation) { self.text = text; self.invocation = invocation }
}

public protocol BedrockTextGenerating: Sendable {
    func generate(instructions: String, input: String, configuration: ModelConfiguration,
                  profile: String, maxOutputTokens: Int) async throws -> AITextResponse
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class BedrockResponsesClient: BedrockTextGenerating, @unchecked Sendable {
    private let session: URLSession
    public init() {
        ClientRuntime.initialize()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 360
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    static func requestBody(instructions: String, input: String, configuration: ModelConfiguration, maxOutputTokens: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": configuration.modelID,
            "instructions": instructions,
            "input": input,
            "reasoning": ["effort": configuration.reasoningEffort],
            "max_output_tokens": maxOutputTokens,
            "store": false,
            "stream": false
        ], options: [.sortedKeys])
    }

    public func generate(instructions: String, input: String, configuration: ModelConfiguration,
                         profile: String, maxOutputTokens: Int = 16_384) async throws -> AITextResponse {
        let configuration = try AIModelCatalog.resolve(configuration)
        let started = Date()
        let body = try Self.requestBody(instructions: instructions, input: input, configuration: configuration, maxOutputTokens: maxOutputTokens)
        let identity = try await ProfileAWSCredentialIdentityResolver(profileName: profile).getIdentity(identityProperties: nil)
        var urlRequest = try await Self.signedRequest(body: body, configuration: configuration, identity: identity)
        guard let endpoint = urlRequest.url?.absoluteString else { throw AIError.configuration("Bedrock 请求地址无效。") }
        urlRequest.timeoutInterval = 300
        try Task.checkCancellation()
        // No automatic inference retries: a timed-out request may already have incurred charges.
        let (data, response) = try await session.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else { throw AIError.invalidOutput("Bedrock 未返回 HTTP 响应。") }
        guard (200..<300).contains(response.statusCode) else {
            if Self.isLocationRestricted(data) { throw AIError.locationRestricted }
            let reason: String
            switch response.statusCode {
            case 401, 403: reason = "请检查 profile 凭证，以及推理配置、目标模型和默认 project 的 bedrock:InvokeModel 权限。"
            case 404: reason = "该区域的模型或 Responses 端点不可用。"
            case 429: reason = "调用配额或限流，请稍后手动重试。"
            case 400: reason = "模型或推理参数被拒绝；请检查模型、区域和档位。"
            default: reason = "服务暂时不可用；已保留现有资料，可从失败阶段重试。"
            }
            throw AIError.service(response.statusCode, reason)
        }
        return try Self.decode(data, model: configuration.modelID, endpoint: endpoint, startedAt: started)
    }

    static func isLocationRestricted(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let message = (object["error"] as? [String: Any])?["message"] as? String ?? object["message"] as? String ?? ""
        return message.localizedCaseInsensitiveContains("unsupported countries")
            || message.localizedCaseInsensitiveContains("unsupported_country_region_territory")
    }

    static func signedRequest(body: Data, configuration: ModelConfiguration, identity: AWSCredentialIdentity) async throws -> URLRequest {
        ClientRuntime.initialize()
        let host = "bedrock-runtime.\(configuration.region).amazonaws.com"
        let request = HTTPRequestBuilder().withMethod(.post).withHost(host).withPath("/openai/v1/responses")
            .withHeader(name: "Host", value: host)
            .withHeader(name: "Content-Type", value: "application/json").withBody(.data(body))
        var signing = Attributes()
        signing.set(key: SigningPropertyKeys.bidirectionalStreaming, value: false)
        signing.set(key: SigningPropertyKeys.unsignedBody, value: false)
        signing.set(key: SigningPropertyKeys.signingName, value: "bedrock")
        signing.set(key: SigningPropertyKeys.signingRegion, value: configuration.region)
        signing.set(key: SigningPropertyKeys.signingAlgorithm, value: .sigv4)
        signing.set(key: SigningPropertyKeys.signedBodyHeader, value: .contentSha256)
        let signed = try await AWSSigV4Signer().signRequest(requestBuilder: request, identity: identity, signingProperties: signing)
        return try await HTTPRequest.makeURLRequest(from: signed.build())
    }

    static func decode(_ data: Data, model: String, endpoint: String, startedAt: Date) throws -> AITextResponse {
        guard data.count < 8_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "completed" else {
            throw AIError.invalidOutput("模型未完成输出，可能已达到输出上限。已保留之前完成的结果，请重试。")
        }
        var text = ""
        for output in object["output"] as? [[String: Any]] ?? [] where output["type"] as? String == "message" {
            for content in output["content"] as? [[String: Any]] ?? [] {
                if content["type"] as? String == "refusal" { throw AIError.invalidOutput("模型拒绝处理此内容。原始记录已保留。") }
                if content["type"] as? String == "output_text" { text += content["text"] as? String ?? "" }
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidOutput("模型没有返回可用文本。") }
        let usage = object["usage"] as? [String: Any]
        return .init(text: text, invocation: .init(responseID: object["id"] as? String ?? "",
            model: object["model"] as? String ?? model, endpoint: endpoint, startedAt: startedAt, durationSeconds: Date().timeIntervalSince(startedAt),
            inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int))
    }
}
