import Foundation

public enum ModelProvider: String, Codable, CaseIterable, Sendable {
    case bedrockRuntime, responsesProxy
    public var title: String {
        switch self {
        case .bedrockRuntime: "AWS Bedrock Runtime"
        case .responsesProxy: "第三方 Responses API"
        }
    }
}

public enum ModelProviderError: LocalizedError {
    case invalidURL, invalidKey, missingKey, keychain(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "请填写有效的 HTTPS Responses API 地址，不包含用户名、密码、查询参数或片段。本机代理可使用 HTTP localhost。"
        case .invalidKey: "API Key 不能为空，也不能包含空格或控制字符。"
        case .missingKey: "此 Responses API 地址尚未配置 API Key，请在模型设置中保存。"
        case .keychain(let status): "模型 API Key 钥匙串操作失败（\(status)）。请检查系统授权。"
        }
    }
}

public enum ResponsesEndpoint {
    /// Accept an origin, a versioned/gateway base URL, or the complete Responses endpoint.
    public static func url(_ value: String) throws -> URL {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(where: \.isWhitespace),
              var components = URLComponents(string: raw),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw ModelProviderError.invalidURL }
        let scheme = components.scheme?.lowercased()
        let local = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && local),
              components.port == nil || (1...65535).contains(components.port!) else { throw ModelProviderError.invalidURL }
        components.scheme = scheme; components.host = host
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) { components.port = nil }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/v1/responses" }
        else if !path.hasSuffix("/responses") { path += "/responses" }
        components.percentEncodedPath = path
        guard let url = components.url else { throw ModelProviderError.invalidURL }
        return url
    }
}
