import SwiftUI
import MeetingCore
import MeetingCloud

private let modelKeyChanged = Notification.Name("MeetingRecord.modelKeyChanged")

struct ModelSettingsRow: View {
    @EnvironmentObject var store: AppStore
    let title: String
    @Binding var configuration: ModelConfiguration
    var profile: String? = nil
    @State private var key = ""
    @State private var keySaved = false
    @State private var status: String?
    @State private var keyError: String?
    @State private var checkTask: Task<Void, Never>?
    @State private var checkID = UUID()
    @State private var checking = false
    private var locale: Locale { store.interfaceLocale }
    private var isProxy: Bool { configuration.effectiveProvider == .responsesProxy }
    private var resolved: ModelConfiguration? { try? AIModelCatalog.resolve(configuration) }
    private var endpoint: String? { try? ResponsesEndpoint.url(configuration.proxyURL ?? "").absoluteString }
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
            Group {
                Picker(L10n.tr("模型提供方", locale: locale), selection: Binding(
                    get: { configuration.effectiveProvider }, set: { provider in
                        configuration.provider = provider
                        configuration.endpoint = provider == .bedrockRuntime ? "runtime" : "responses"
                        if provider == .responsesProxy && configuration.customModelID == nil {
                            configuration.customModelID = ""; configuration.reasoningEffort = ""
                        }
                    })) {
                    ForEach(ModelProvider.allCases, id: \.self) { Text(L10n.text($0.title, locale: locale)).tag($0) }
                }
                if isProxy {
                    TextField("Responses API URL", text: Binding(get: { configuration.proxyURL ?? "" }, set: { configuration.proxyURL = $0 }),
                              prompt: Text("https://proxy.example.com/v1"))
                    if let endpoint { Text(endpoint).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                    SecureField("API Key", text: $key, prompt: Text(L10n.tr("输入后保存或验证", locale: locale)))
                    HStack {
                        Text(L10n.tr(keySaved ? "API Key 已保存在本机钥匙串" : "尚未配置 API Key", locale: locale)).font(.caption)
                        Spacer()
                        Button(L10n.tr("保存 API Key", locale: locale)) { saveKey() }.disabled(endpoint == nil || key.isEmpty)
                        Button(L10n.tr("移除 API Key", locale: locale)) { deleteKey() }.disabled(endpoint == nil || !keySaved)
                    }
                    Text(L10n.tr("Key 按 API 地址保存在本机钥匙串；同一地址可共用。切换地址需单独配置。", locale: locale))
                        .font(.caption).foregroundStyle(.secondary)
                    if let keyError { Text(L10n.message(keyError, locale: locale)).font(.caption).foregroundStyle(.orange) }
                } else {
                    TextField(L10n.tr("区域", locale: locale), text: $configuration.region)
                    Text(L10n.tr("使用 AWS profile：\(profile ?? store.settings.profile)", locale: locale)).font(.caption).foregroundStyle(.secondary)
                    Picker(L10n.tr("模型", locale: locale), selection: selection) {
                        ForEach(ModelChoice.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                        Text(L10n.tr("自定义 Model ID", locale: locale)).tag("custom")
                    }
                }
                if configuration.customModelID != nil {
                    TextField("Model ID", text: Binding(get: { configuration.customModelID ?? "" }, set: { configuration.customModelID = $0 }),
                              prompt: Text(L10n.tr("填写服务支持的完整模型 ID", locale: locale)))
                }
                Picker(L10n.tr("推理强度", locale: locale), selection: $configuration.reasoningEffort) {
                    ForEach(configuration.customModelID == nil ? AIModelCatalog.efforts(for: configuration.model) : AIModelCatalog.customEfforts, id: \.self) {
                        Text($0.isEmpty ? L10n.tr("服务默认（不发送 reasoning）", locale: locale) : $0).tag($0)
                    }
                }
                if let resolved {
                    Text(resolved.modelID + " · " + L10n.text(resolved.effectiveProvider.title, locale: locale))
                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let validationMessage { Text(L10n.message(validationMessage, locale: locale)).font(.caption).foregroundStyle(.orange) }
            }.disabled(checking)
            HStack {
                Button(L10n.tr("验证模型调用", locale: locale)) { checkConnection() }
                    .disabled(checking || resolved == nil || (isProxy && key.isEmpty && !keySaved))
                if checking {
                    ProgressView().controlSize(.small)
                    Button(L10n.tr("停止等待", locale: locale)) { cancelCheck(); status = "已停止等待；已发送的模型请求可能仍会计费。" }
                }
            }
            Text(isProxy
                 ? L10n.tr("验证只发送固定测试文字，会产生少量推理用量。输入框留空时使用已保存的 Key。", locale: locale)
                 : L10n.tr("验证只发送固定测试文字，会产生少量推理用量。", locale: locale))
                .font(.caption).foregroundStyle(.secondary)
            if let status { Text(L10n.message(status, locale: locale)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .onAppear { refreshKey() }
        .onReceive(NotificationCenter.default.publisher(for: modelKeyChanged)) { _ in refreshKey(); status = nil }
        .onChange(of: configuration) { _, _ in cancelCheck(); status = nil }
        .onChange(of: configuration.effectiveProvider) { _, _ in key = ""; refreshKey() }
        .onChange(of: configuration.proxyURL) { _, _ in key = ""; refreshKey() }
        .onChange(of: key) { _, _ in status = nil }
        .onChange(of: profile ?? store.settings.profile) { _, _ in cancelCheck(); status = nil }
        .onDisappear { cancelCheck(); key = "" }
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
        let snapshot = configuration, awsProfile = profile ?? store.settings.profile
        let entered = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID(); checkID = id; checking = true; status = nil
        checkTask = Task { @MainActor in
            defer { if checkID == id { checking = false; checkTask = nil } }
            do {
                let proxy = ProxyResponsesClient(apiKey: entered.isEmpty ? nil : entered)
                _ = try await ResponsesClient(proxy: proxy).generate(instructions: "Reply with the word OK.",
                    input: "Connection check. No meeting content.", configuration: snapshot, profile: awsProfile, maxOutputTokens: 2_048)
                guard !Task.isCancelled, checkID == id else { return }
                status = "\(snapshot.displayModel) 调用成功"
            } catch {
                guard !Task.isCancelled, checkID == id else { return }
                status = AppStore.aiMessage(error)
            }
        }
    }
}
