import Foundation
import Testing
@testable import MeetingCore

@Test func legacyModelConfigurationDecodesWithoutProviderAndKeepsHistoricalFields() throws {
    let data = Data(#"{"model":"GPT-6 Astra","reasoningEffort":"medium","modelID":"openai.gpt-6-astra","region":"us-west-2","endpoint":"mantle"}"#.utf8)
    let config = try JSONDecoder().decode(ModelConfiguration.self, from: data)
    #expect(config.effectiveProvider == .bedrockRuntime)
    #expect(config.customModelID == nil)
    #expect(config.endpoint == "mantle")
    #expect(config.modelID == "openai.gpt-6-astra")
    #expect(try JSONDecoder().decode(ModelConfiguration.self, from: JSONEncoder().encode(config)) == config)
}

@Test func responsesEndpointNormalizesBaseAndFullAddressesWithoutDuplicatingPath() throws {
    let cases = [
        " https://PROXY.example.com:443/ ": "https://proxy.example.com/v1/responses",
        "https://proxy.example.com/v1/": "https://proxy.example.com/v1/responses",
        "https://proxy.example.com/openai/v1/responses/": "https://proxy.example.com/openai/v1/responses",
        "https://proxy.example.com/gateway": "https://proxy.example.com/gateway/responses",
        "http://localhost:8080/v1": "http://localhost:8080/v1/responses",
        "http://127.0.0.1:8080/responses": "http://127.0.0.1:8080/responses"
    ]
    for (input, expected) in cases {
        #expect(try ResponsesEndpoint.url(input).absoluteString == expected)
        #expect(try ResponsesEndpoint.url(expected).absoluteString == expected)
    }
}

@Test func responsesEndpointRejectsSecretsInURLsAndInsecureRemoteAddresses() {
    for input in ["", "proxy.example.com", "file:///tmp/test", "http://proxy.example.com/v1", "https://user:secret@proxy.example.com/v1",
                  "https://proxy.example.com/v1?api_key=secret", "https://proxy.example.com/v1#secret", "https://proxy.example.com:99999", "https://proxy.example.com/a b"] {
        #expect(throws: ModelProviderError.self) { try ResponsesEndpoint.url(input) }
    }
}

@Test func proxyConfigurationAndVersionExportPreserveCustomModelAndDestination() throws {
    var config = ModelConfiguration()
    config.provider = .responsesProxy; config.customModelID = "vendor/my-model"; config.modelID = "vendor/my-model"
    config.proxyURL = "https://proxy.example.com/v1/responses"; config.endpoint = "responses"; config.reasoningEffort = ""
    var meeting = Meeting(title: "Test", applicationName: "Test", bundleID: "test", microphoneName: "Mic", settings: .init())
    meeting.settings.summary = config
    let input = AIInputSnapshot(meeting: meeting)
    let version = MinutesVersion(input: input, correctionVersionID: nil, configuration: config, profile: "unused",
        minutes: .init(overview: "Test", topics: [], decisions: [], actions: [], questions: [], limitations: []), invocation: nil)
    meeting.minuteVersions = [version]
    let data = try JSONEncoder().encode(meeting)
    let restored = try JSONDecoder().decode(Meeting.self, from: data)
    #expect(restored.settings.summary == config)
    #expect(restored.minuteVersions?.first?.configuration == config)
    let encoded = String(decoding: data, as: UTF8.self)
    #expect(!encoded.contains("apiKey"))
    #expect(!encoded.contains("Authorization"))
    #expect(version.configuration.displayModel == "vendor/my-model")
    let exported = MeetingExport.minutes(version, format: .markdown)
    #expect(exported.contains("vendor/my-model"))
    #expect(exported.contains("https://proxy.example.com/v1/responses"))
}
