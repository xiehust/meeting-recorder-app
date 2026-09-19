import SwiftUI
import MeetingCore
import MeetingCloud

struct SpeechSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    private var locale: Locale { store.interfaceLocale }
    var body: some View {
        Section(L10n.tr("实时转录引擎", locale: locale)) {
            Picker(L10n.tr("识别服务", locale: locale), selection: Binding(
                get: { store.settings.effectiveSpeechProvider }, set: { store.settings.speechProvider = $0 })) {
                ForEach(SpeechProvider.allCases, id: \.self) { Text(L10n.text($0.title, locale: locale)).tag($0) }
            }
            if store.settings.effectiveSpeechProvider == .doubao {
                Picker(L10n.tr("音频发送方式", locale: locale), selection: Binding(
                    get: { store.settings.effectiveDoubao.audioMode },
                    set: { var value = store.settings.effectiveDoubao; value.audioMode = $0; store.settings.doubao = value })) {
                    ForEach(DoubaoAudioMode.allCases, id: \.self) { Text(L10n.text($0.title, locale: locale)).tag($0) }
                }
                Text(L10n.tr("按 \(store.settings.effectiveDoubao.pricePerHour.formatted(.currency(code: "CNY").locale(locale)))／音频小时估算。单路混音发送一条音频；双路分别累计时长。", locale: locale)).font(.caption).foregroundStyle(.secondary)
                Text(L10n.tr("实时出字后逐句确认并分离说话人。混音中的人物先标为 A/B，可在人物页将自己改名为“我”。耳机场景更适合混音；外放回声与同时讲话可能影响识别。", locale: locale)).font(.caption).foregroundStyle(.secondary)
                if !store.settings.supportedRecognitionLanguages.contains(store.settings.language) {
                    Text(L10n.message(SpeechConfigurationError.unsupportedLanguage.localizedDescription, locale: locale)).foregroundStyle(.orange)
                }
            }
        }
    }
}

struct DoubaoCredentialSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    @State private var key = ""
    @State private var keySaved = false
    @State private var error: String?
    @State private var checking = false
    @State private var checkStatus: String?
    @State private var checkTask: Task<Void, Never>?
    @State private var checkID = UUID()
    private var locale: Locale { store.interfaceLocale }
    private var canCheck: Bool { !checking && (keySaved || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    var body: some View {
        Section(L10n.tr("豆包凭证", locale: locale)) {
            SecureField("API Key", text: $key).disabled(checking)
            HStack {
                Text(L10n.tr(keySaved ? "API Key 已保存在本机钥匙串" : "尚未配置 API Key", locale: locale)).font(.caption)
                Spacer()
                Button(L10n.tr("保存 API Key", locale: locale)) {
                    do { try DoubaoKeychain.save(key); key = ""; keySaved = true; error = nil; checkStatus = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(checking || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L10n.tr("移除 API Key", locale: locale)) {
                    do { try DoubaoKeychain.delete(); key = ""; keySaved = false; error = nil; checkStatus = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(checking || !keySaved)
            }
            HStack {
                Button(L10n.tr("检查流式连接", locale: locale)) { checkCredentials(recording: false) }.disabled(!canCheck)
                Button(L10n.tr("检查录音文件连接", locale: locale)) { checkCredentials(recording: true) }.disabled(!canCheck)
                if checking {
                    ProgressView().controlSize(.small)
                    Button(L10n.tr("取消检查", locale: locale)) { cancelCheck() }
                }
            }
            Text(L10n.tr("实时转录与录音复核共用此 Key，但模型服务需分别开通。优先检查输入框中的 Key；留空时读取已保存的 Key。连接检查不发送音频。", locale: locale)).font(.caption).foregroundStyle(.secondary)
            if let checkStatus { Text(L10n.message(checkStatus, locale: locale)).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(L10n.message(error, locale: locale)).foregroundStyle(.orange) }
        }.onAppear {
            do { keySaved = try DoubaoKeychain.isConfigured() }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: key) { _, _ in checkStatus = nil; error = nil }
        .onDisappear { cancelCheck() }
    }
    private func cancelCheck() { checkID = UUID(); checkTask?.cancel(); checkTask = nil; checking = false }
    private func checkCredentials(recording: Bool) {
        let entered = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = UUID(); checkID = requestID
        checking = true; checkStatus = nil; error = nil
        checkTask = Task { @MainActor in
            defer { if checkID == requestID { checking = false; checkTask = nil } }
            do {
                let candidate: String?
                if entered.isEmpty { candidate = try DoubaoKeychain.read() } else { candidate = entered }
                guard let candidate, !candidate.isEmpty else { throw SpeechConfigurationError.missingKey }
                if recording { try await DoubaoCredentialCheck.checkRecording(apiKey: candidate) }
                else { try await DoubaoCredentialCheck.check(apiKey: candidate) }
                guard !Task.isCancelled, checkID == requestID else { return }
                checkStatus = recording ? "录音文件查询连接已通过；未提交音频，识别权限将在实际提交时验证。" : "凭证检查通过：豆包流式 2.0 WebSocket 握手成功。"
            } catch {
                guard !Task.isCancelled, checkID == requestID else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

struct SpeechUsageView: View {
    @EnvironmentObject private var store: AppStore
    let meeting: Meeting
    var body: some View {
        if let usage = meeting.speechUsage {
            let locale = store.interfaceLocale
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("豆包已发送音频 \(TimeLabel.format(usage.submittedSeconds)) · 预计识别费 \(usage.costDescription(locale: locale))", locale: locale))
                Text(L10n.tr("按 \(usage.pricePerHour.formatted(.currency(code: "CNY").locale(locale)))／音频小时估算；以平台账单为准，不含文字校对和纪要费用。", locale: locale))
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}
