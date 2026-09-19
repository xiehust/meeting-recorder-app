import SwiftUI
import MeetingCore
import MeetingCloud

private let modelKeyChanged = Notification.Name("MeetingRecord.modelKeyChanged")

struct SharedModelSettingsView: View {
    @EnvironmentObject var store: AppStore
    @Binding var correction: ModelConfiguration
    @Binding var summary: ModelConfiguration
    var profile: String? = nil
    @State private var key = ""
    @State private var keySaved = false
    @State private var status: String?
    @State private var keyError: String?
    @State private var checkTask: Task<Void, Never>?
    @State private var checkID = UUID()
    @State private var checking = false
    private var locale: Locale { store.interfaceLocale }
    private var connection: ModelConnection { ModelConnection(correction) }
    private var isProxy: Bool { connection.provider == .responsesProxy }
    private var endpoint: String? { try? ResponsesEndpoint.url(connection.proxyURL).absoluteString }
    private var validModels: Bool {
        (try? AIModelCatalog.resolve(correction)) != nil && (try? AIModelCatalog.resolve(summary)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                Text(L10n.tr("模型服务（校对与总结共用）", locale: locale)).font(.headline)
                Picker(L10n.tr("模型提供方", locale: locale), selection: Binding(
                    get: { connection.provider }, set: { provider in
                        var value = connection; value.provider = provider; applyConnection(value)
                    })) {
                    ForEach(ModelProvider.allCases, id: \.self) { Text(L10n.text($0.title, locale: locale)).tag($0) }
                }
                if isProxy { proxyCredentials }
                else {
                    TextField(L10n.tr("区域", locale: locale), text: Binding(
                        get: { connection.region }, set: { region in
                            var value = connection; value.region = region; applyConnection(value)
                        }))
                    Text(L10n.tr("使用 AWS profile：\(profile ?? store.settings.profile)", locale: locale))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.tr("连接只需配置一次。校对与总结共用提供方和凭证，可分别选择模型及推理强度。", locale: locale))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                ModelSettingsRow(title: L10n.tr("校对模型", locale: locale), configuration: $correction)
                Divider()
                ModelSettingsRow(title: L10n.tr("总结模型", locale: locale), configuration: $summary)
            }.disabled(checking)
            HStack {
                Button(L10n.tr("验证模型调用", locale: locale)) { checkConnection() }
                    .disabled(checking || !validModels || (isProxy && key.isEmpty && !keySaved))
                if checking {
                    ProgressView().controlSize(.small)
                    Button(L10n.tr("停止等待", locale: locale)) {
                        cancelCheck(); status = "已停止等待；已发送的模型请求可能仍会计费。"
                    }
                }
            }
            Text(L10n.tr("检查两阶段的模型；相同模型和推理强度只调用一次。仅发送固定测试文字，会产生少量推理用量。", locale: locale))
                .font(.caption).foregroundStyle(.secondary)
            if let status { Text(L10n.message(status, locale: locale)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .onAppear { applyConnection(connection); refreshKey() }
        .onReceive(NotificationCenter.default.publisher(for: modelKeyChanged)) { _ in cancelCheck(); refreshKey(); status = nil }
        .onChange(of: correction) { _, _ in cancelCheck(); status = nil }
        .onChange(of: summary) { _, _ in cancelCheck(); status = nil }
        .onChange(of: connection) { _, _ in applyConnection(connection); key = ""; refreshKey() }
        .onChange(of: key) { _, _ in status = nil }
        .onChange(of: profile ?? store.settings.profile) { _, _ in cancelCheck(); status = nil }
        .onDisappear { cancelCheck(); key = "" }
    }

    private var proxyCredentials: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Responses API URL", text: Binding(get: { connection.proxyURL }, set: { url in
                var value = connection; value.proxyURL = url; applyConnection(value)
            }), prompt: Text("https://proxy.example.com/openai/v1"))
            if let endpoint { Text(endpoint).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
            Text(L10n.tr("请填写服务提供的完整基础路径（例如 /openai/v1），或完整的 /responses 地址。", locale: locale))
                .font(.caption).foregroundStyle(.secondary)
            SecureField("API Key", text: $key, prompt: Text(L10n.tr("输入后保存或验证", locale: locale)))
            HStack {
                Text(L10n.tr(keySaved ? "API Key 已保存在本机钥匙串" : "尚未配置 API Key", locale: locale)).font(.caption)
                Spacer()
                Button(L10n.tr("保存 API Key", locale: locale)) { saveKey() }.disabled(endpoint == nil || key.isEmpty)
                Button(L10n.tr("移除 API Key", locale: locale)) { deleteKey() }.disabled(endpoint == nil || !keySaved)
            }
            Text(L10n.tr("此 Key 供校对与总结共用，保存在本机钥匙串。输入框留空时使用已保存的 Key；更换地址需单独配置。", locale: locale))
                .font(.caption).foregroundStyle(.secondary)
            if let keyError { Text(L10n.message(keyError, locale: locale)).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func applyConnection(_ connection: ModelConnection) {
        let source = connection.applying(to: correction)
        correction = AIModelCatalog.sharingConnection(from: source, to: correction)
        summary = AIModelCatalog.sharingConnection(from: source, to: summary)
    }
    private func refreshKey() {
        keySaved = false; keyError = nil
        guard isProxy, let endpoint else { return }
        do { keySaved = try ModelAPIKeychain.isConfigured(endpoint: endpoint) }
        catch { keyError = AppStore.aiMessage(error) }
    }
    private func saveKey() {
        guard let endpoint else { return }
        do {
            try ModelAPIKeychain.save(key, endpoint: endpoint); key = ""
            NotificationCenter.default.post(name: modelKeyChanged, object: nil)
        } catch { keyError = AppStore.aiMessage(error) }
    }
    private func deleteKey() {
        guard let endpoint else { return }
        do {
            try ModelAPIKeychain.delete(endpoint: endpoint); key = ""
            NotificationCenter.default.post(name: modelKeyChanged, object: nil)
        } catch { keyError = AppStore.aiMessage(error) }
    }
    private func cancelCheck() { checkID = UUID(); checkTask?.cancel(); checkTask = nil; checking = false }
    private func checkConnection() {
        let correction = correction, summary = summary, awsProfile = profile ?? store.settings.profile
        let entered = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID(); checkID = id; checking = true; status = nil
        checkTask = Task { @MainActor in
            defer { if checkID == id { checking = false; checkTask = nil } }
            do {
                let first = try AIModelCatalog.resolve(correction)
                let second = try AIModelCatalog.resolve(AIModelCatalog.sharingConnection(from: correction, to: summary))
                let sameRequest = first.modelID == second.modelID && first.reasoningEffort == second.reasoningEffort
                let checks = sameRequest ? [("校对与总结", first)] : [("校对", first), ("总结", second)]
                var candidate: String?
                if first.effectiveProvider == .responsesProxy {
                    candidate = entered.isEmpty ? try ModelAPIKeychain.read(endpoint: first.proxyURL ?? "") : entered
                    guard candidate != nil else { throw ModelProviderError.missingKey }
                }
                let client = ResponsesClient(proxy: ProxyResponsesClient(apiKey: candidate))
                var messages: [String] = []
                for (stage, configuration) in checks {
                    try Task.checkCancellation()
                    do {
                        _ = try await client.generate(instructions: "Reply with the word OK.", input: "Connection check. No meeting content.",
                            configuration: configuration, profile: awsProfile, maxOutputTokens: 2_048)
                        messages.append(L10n.tr("\(L10n.text(stage, locale: locale)) · \(configuration.displayModel) 调用成功", locale: locale))
                    } catch {
                        guard !Task.isCancelled, checkID == id else { return }
                        messages.append(L10n.text(stage, locale: locale) + ": " + L10n.message(AppStore.aiMessage(error), locale: locale))
                    }
                    guard !Task.isCancelled, checkID == id else { return }
                    status = messages.joined(separator: "\n")
                }
            } catch {
                guard !Task.isCancelled, checkID == id else { return }
                status = AppStore.aiMessage(error)
            }
        }
    }
}

/// Stage-specific options only; connection and credential controls live above both rows.
struct ModelSettingsRow: View {
    @EnvironmentObject var store: AppStore
    let title: String
    @Binding var configuration: ModelConfiguration
    private var locale: Locale { store.interfaceLocale }
    private var resolved: ModelConfiguration? { try? AIModelCatalog.resolve(configuration) }
    private var validationMessage: String? {
        do { _ = try AIModelCatalog.resolve(configuration); return nil }
        catch { return AppStore.aiMessage(error) }
    }
    private var selection: Binding<String> {
        Binding(get: { configuration.customModelID == nil ? configuration.model.rawValue : "custom" }, set: { choice in
            if let model = ModelChoice(rawValue: choice) {
                configuration.model = model; configuration.customModelID = nil; configuration.modelID = ""
                if !AIModelCatalog.efforts(for: model).contains(configuration.reasoningEffort) { configuration.reasoningEffort = "medium" }
            } else {
                configuration.customModelID = configuration.modelID.isEmpty ? AIModelCatalog.modelID(configuration.model) : configuration.modelID
                configuration.reasoningEffort = ""
            }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if configuration.effectiveProvider == .bedrockRuntime {
                Picker(L10n.tr("模型", locale: locale), selection: selection) {
                    ForEach(ModelChoice.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                    Text(L10n.tr("自定义 Model ID", locale: locale)).tag("custom")
                }
            }
            if configuration.effectiveProvider == .responsesProxy || configuration.customModelID != nil {
                TextField("Model ID", text: Binding(get: { configuration.customModelID ?? "" }, set: { configuration.customModelID = $0 }),
                          prompt: Text(L10n.tr("填写服务支持的完整模型 ID", locale: locale)))
            }
            Picker(L10n.tr("推理强度", locale: locale), selection: $configuration.reasoningEffort) {
                ForEach(configuration.customModelID == nil ? AIModelCatalog.efforts(for: configuration.model) : AIModelCatalog.customEfforts, id: \.self) {
                    Text($0.isEmpty ? L10n.tr("服务默认（不发送 reasoning）", locale: locale) : $0).tag($0)
                }
            }
            if let resolved { Text(resolved.modelID).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
            if let validationMessage { Text(L10n.message(validationMessage, locale: locale)).font(.caption).foregroundStyle(.orange) }
        }
    }
}
