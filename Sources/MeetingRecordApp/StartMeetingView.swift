import SwiftUI
import AVFoundation
import MeetingCore
import MeetingAudio
import MeetingCloud

struct StartMeetingView: View {
    private var interfaceLocale: Locale { store.interfaceLocale }
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var applications: [MeetingApplication] = []
    @State private var microphones: [MicrophoneDevice] = []
    @State private var applicationSelection: MeetingApplicationSelection
    @State private var microphoneID: UInt32 = 0
    @State private var title = ""
    @State private var language: RecognitionLanguage = .mixed
    @State private var useMicrophone = true
    @State private var cloud = true
    @State private var cache = false
    @State private var consent = false
    @State private var summaryTemplate = SummaryTemplate.meeting
    @State private var useVocabulary = false
    @State private var automaticBatch = false

    init(preferredApplication: MeetingApplication? = nil) {
        _applicationSelection = State(initialValue: MeetingApplicationSelection(preferred: preferredApplication))
    }

    var body: some View {
        let interfaceLocale = self.interfaceLocale
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 13) {
                Image(systemName: "record.circle").font(.system(size: 36, weight: .light)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("开始之前，确认记录范围", locale: interfaceLocale)).font(.title2).fontWeight(.semibold)
                    Text(L10n.tr("当前没有采集或上传会议声音。", locale: interfaceLocale)).font(.callout).foregroundStyle(.secondary)
                }
            }
            Form {
                Section(L10n.tr("会议信息", locale: interfaceLocale)) {
                    TextField(L10n.tr("会议标题", locale: interfaceLocale), text: $title)
                    Picker(L10n.tr("识别语言", locale: interfaceLocale), selection: $language) {
                        ForEach(RecognitionLanguage.selectableCases, id: \.self) { Text(L10n.text($0.title, locale: interfaceLocale)).tag($0) }
                    }
                }
                Section(L10n.tr("纪要模板", locale: interfaceLocale)) {
                    SummaryTemplatePicker(selection: $summaryTemplate)
                }
                Section(L10n.tr("音频来源", locale: interfaceLocale)) {
                    Picker(L10n.tr("会议应用", locale: interfaceLocale), selection: Binding(
                        get: { applicationSelection.selected?.id ?? "" },
                        set: { applicationSelection.select(id: $0, applications: applications) }
                    )) {
                        Text(applications.isEmpty ? L10n.tr("请先打开会议应用", locale: interfaceLocale) : L10n.tr("选择应用", locale: interfaceLocale)).tag("")
                        ForEach(applications) { Text($0.name).tag($0.id) }
                    }
                    Text(L10n.tr("支持 \(L10n.text(MeetingApplication.supportedNamesDescription, locale: interfaceLocale)) 的 macOS 客户端。", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                    if let unavailable = applicationSelection.unavailable {
                        Text(L10n.tr("\(unavailable.name) 已不在运行。请打开它后刷新设备，或手动选择其他会议应用。", locale: interfaceLocale))
                            .font(.caption).foregroundStyle(.orange)
                    } else if applicationSelection.selected == nil, applications.count > 1 {
                        Text(L10n.tr("有多个会议应用正在运行，请选择本次要记录的应用。", locale: interfaceLocale))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(L10n.tr("同时采集我的麦克风", locale: interfaceLocale), isOn: $useMicrophone)
                    Picker(L10n.tr("麦克风设备", locale: interfaceLocale), selection: $microphoneID) {
                        Text(L10n.tr("选择麦克风", locale: interfaceLocale)).tag(UInt32(0))
                        ForEach(microphones) { Text($0.name).tag($0.id) }
                    }.disabled(!useMicrophone)
                    HStack {
                        Label(microphonePermission, systemImage: "mic").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.tr("刷新设备", locale: interfaceLocale)) { refresh() }
                    }
                    Text(L10n.tr("系统音频权限在首次开始时由 macOS 请求。只采集选中的应用；麦克风开关与会议软件静音独立。", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("处理与保存", locale: interfaceLocale)) {
                    Toggle(L10n.tr("使用 AWS Transcribe 实时转录", locale: interfaceLocale), isOn: $cloud)
                    Text(cloud ? L10n.tr("两路音频将发送至 AWS（\(store.settings.profile) · \(store.settings.transcribeRegion)），分别计算转录用量。", locale: interfaceLocale) : L10n.tr("仅验证本地音频采集，不会获得实时转录。", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L10n.tr("使用全局自定义词汇表", locale: interfaceLocale), isOn: $useVocabulary).disabled(!cloud && !automaticBatch)
                    if useVocabulary && (cloud || automaticBatch) {
                        Text(L10n.message(store.vocabularyReadiness(language: language), locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                    }
                    VocabularyManagerButton()
                    Toggle(L10n.tr("结束后自动用录音重新转录", locale: interfaceLocale), isOn: $automaticBatch)
                    if automaticBatch {
                        Text(L10n.tr("自动保留录音，结束后上传至 S3（\(store.batchBucket.isEmpty ? L10n.tr("请先在设置填写桶名", locale: interfaceLocale) : store.batchBucket)）并批量转录，产生额外用量。完成后等待你复核、采用，再进行 AI 校对和纪要。", locale: interfaceLocale))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(L10n.tr("保留本地音频缓存", locale: interfaceLocale), isOn: Binding(get: { cache || automaticBatch }, set: { cache = $0 })).disabled(automaticBatch)
                    Text(cache || automaticBatch ? L10n.tr("缓存保留至你删除会议。会后可在“录音复核”中手动提交批量转录。", locale: interfaceLocale) : L10n.tr("不保存音频文件，会后无法重新转录。", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(automaticBatch ? L10n.tr("自动批量模式优先：结束后先重转录并等待复核，不会直接生成 AI 纪要。", locale: interfaceLocale) : (store.settings.automaticallyGenerateMinutes ?? true)
                         ? L10n.tr("结束后自动校对并生成纪要。转录、人物信息、术语和必要备注将发送至 AWS Bedrock：\(store.settings.correction.model.rawValue) / \(store.settings.correction.reasoningEffort) 校对；\(store.settings.summary.model.rawValue) / \(store.settings.summary.reasoningEffort) 总结。", locale: interfaceLocale)
                         : L10n.tr("自动 AI 处理已关闭；会后可以手动校对和生成纪要。", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).frame(height: 430)
            if cloud && !automaticBatch && (store.settings.automaticallyGenerateMinutes ?? true) {
                Text(L10n.tr("会后还会将确定转录与必要备注发送至 AWS Bedrock 校对、生成纪要。", locale: interfaceLocale))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(L10n.tr("我已确认可记录本次会议，并了解所选采集和云端处理范围。", locale: interfaceLocale), isOn: $consent).font(.callout)
            HStack {
                Button(L10n.tr("取消", locale: interfaceLocale)) { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.starting)
                Spacer()
                if store.starting { ProgressView().controlSize(.small) }
                Button(store.starting ? L10n.tr("正在准备…", locale: interfaceLocale) : L10n.tr("开始记录", locale: interfaceLocale)) {
                    guard let application = applicationSelection.selected else { return }
                    Task {
                        await store.start(title: title, application: application,
                            microphone: microphones.first(where: { $0.id == microphoneID }),
                            useMicrophone: useMicrophone, cloud: cloud, cache: cache, language: language,
                            summaryTemplate: summaryTemplate, useVocabulary: useVocabulary, automaticBatch: automaticBatch)
                    }
                }.buttonStyle(.borderedProminent).tint(.teal).keyboardShortcut(.defaultAction)
                    .disabled(!consent || applicationSelection.selected == nil || (useMicrophone && microphoneID == 0) || store.starting)
            }
        }.padding(28).frame(width: 730).interactiveDismissDisabled(store.starting)
            .onAppear {
                refresh(); language = store.settings.language; cache = store.settings.cacheAudio
                summaryTemplate = store.settings.effectiveSummaryTemplate
                useVocabulary = store.vocabularyLibrary.useByDefault
                automaticBatch = store.settings.automaticBatchTranscription ?? false
                title = L10n.tr("会议 · \(Date().formatted(.dateTime.month().day().hour().minute().locale(interfaceLocale)))", locale: interfaceLocale)
            }
    }
    private var microphonePermission: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: L10n.tr("麦克风已授权", locale: interfaceLocale)
        case .notDetermined: L10n.tr("开始后请求麦克风权限", locale: interfaceLocale)
        default: L10n.tr("麦克风未授权，请检查系统设置", locale: interfaceLocale)
        }
    }
    private func refresh() {
        applications = AudioDevices.meetingApplications(); microphones = AudioDevices.microphones()
        applicationSelection.refresh(applications: applications)
        if !microphones.contains(where: { $0.id == microphoneID }) { microphoneID = AudioDevices.defaultInputID() }
    }
}

struct SettingsView: View {
    private var interfaceLocale: Locale { store.interfaceLocale }
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("设置", locale: interfaceLocale)).font(.title2).fontWeight(.semibold)
            Form {
                Section(L10n.tr("界面语言", locale: interfaceLocale)) {
                    Picker(L10n.tr("显示语言", locale: interfaceLocale), selection: $store.interfaceLanguage) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.title(locale: interfaceLocale)).tag($0) }
                    }
                    Text(L10n.tr("立即生效并自动保存。界面语言不改变识别语言、纪要语言或已保存的会议内容。", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("AWS 连接", locale: interfaceLocale)) {
                    TextField("AWS profile", text: $store.settings.profile)
                    TextField(L10n.tr("Transcribe 区域", locale: interfaceLocale), text: $store.settings.transcribeRegion)
                    HStack {
                        Text(L10n.message(store.connectionStatus, locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.tr("检查凭证", locale: interfaceLocale)) { store.checkConnection() }.disabled(store.checkingConnection)
                    }
                    Text(L10n.tr("复用本机 AWS profile，不在会议资料中保存密钥。凭证检查不发送会议内容，也不验证推理权限。", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("默认语言", locale: interfaceLocale)) {
                    Picker(L10n.tr("识别语言", locale: interfaceLocale), selection: $store.settings.language) {
                        ForEach(RecognitionLanguage.selectableCases, id: \.self) { Text(L10n.text($0.title, locale: interfaceLocale)).tag($0) }
                    }
                    Picker(L10n.tr("纪要语言", locale: interfaceLocale), selection: $store.settings.summaryLanguage) {
                        ForEach(SummaryLanguage.allCases, id: \.self) {
                            Text(L10n.text($0.rawValue, locale: interfaceLocale)).tag($0.rawValue)
                        }
                    }
                }
                Section(L10n.tr("全局转录词汇表", locale: interfaceLocale)) {
                    VocabularyManagerButton()
                    Text(L10n.tr("统一维护中文、日文、英文词条，按语言同步到 AWS 后用于新录音的转录。", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("会后用录音重新转录", locale: interfaceLocale)) {
                    Picker(L10n.tr("执行方式", locale: interfaceLocale), selection: Binding(
                        get: { store.settings.automaticBatchTranscription ?? false },
                        set: { store.settings.automaticBatchTranscription = $0 })) {
                        Text(L10n.tr("可选：会后手动触发", locale: interfaceLocale)).tag(false)
                        Text(L10n.tr("默认：结束记录后自动执行", locale: interfaceLocale)).tag(true)
                    }
                    TextField(L10n.tr("录音上传 S3 桶", locale: interfaceLocale), text: Binding(
                        get: { store.settings.batchTranscriptionBucket ?? "" },
                        set: { store.settings.batchTranscriptionBucket = $0 }))
                    Text(L10n.tr("留空时使用全局词汇表的 S3 桶。当前：\(store.batchBucket.isEmpty ? L10n.tr("未配置", locale: interfaceLocale) : store.batchBucket)", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.tr("手动模式需提前保留本地录音。自动模式会为新会议保留录音并上传到同区域 S3，产生额外转录及存储用量；先等待复核，采用后再校对和总结。每场会议开始前可单独调整。", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("新记录的默认纪要模板", locale: interfaceLocale)) {
                    SummaryTemplatePicker(selection: Binding(
                        get: { store.settings.effectiveSummaryTemplate },
                        set: { store.settings.summaryTemplate = $0 }
                    ))
                }
                Section(L10n.tr("AI 校对与纪要", locale: interfaceLocale)) {
                    Toggle(L10n.tr("结束记录后自动校对并生成纪要", locale: interfaceLocale), isOn: Binding(
                        get: { store.settings.automaticallyGenerateMinutes ?? true },
                        set: { store.settings.automaticallyGenerateMinutes = $0 }))
                    if store.settings.automaticBatchTranscription == true {
                        Text(L10n.tr("自动重转录优先，AI 处理将在你复核并采用批量结果后手动继续。", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                    }
                    ModelSettingsRow(title: L10n.tr("校对", locale: interfaceLocale), configuration: $store.settings.correction)
                    ModelSettingsRow(title: L10n.tr("总结", locale: interfaceLocale), configuration: $store.settings.summary)
                    Text(L10n.tr("使用 AWS Bedrock Runtime Responses。接入所选区域，由 AWS 按 global 推理配置跨区域路由。每次请求固定模型与推理强度；重新生成会保存新版本并产生调用用量。", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top) {
                        Text(L10n.message(store.modelConnectionStatus, locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.tr("验证模型调用", locale: interfaceLocale)) { store.checkModelConnection() }.disabled(store.checkingModel)
                    }
                }
                Section(L10n.tr("记录与存储", locale: interfaceLocale)) {
                    Toggle(L10n.tr("会议应用运行时提醒", locale: interfaceLocale), isOn: $store.settings.detectMeetings)
                    Text(L10n.tr("支持 \(L10n.text(MeetingApplication.supportedNamesDescription, locale: interfaceLocale))。", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L10n.tr("默认开启本地音频缓存", locale: interfaceLocale), isOn: $store.settings.cacheAudio)
                    Text(L10n.tr("缓存默认关闭。开启后保留至手动删除会议；自动到期清理尚未启用。", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.tr("在 Finder 中打开资料目录", locale: interfaceLocale)) { NSWorkspace.shared.open(store.directory) }
                }
            }.formStyle(.grouped)
            HStack {
                Text(L10n.tr("记录设置用于新会议；界面语言立即生效。", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("保存并关闭", locale: interfaceLocale)) { store.saveSettings(); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 740, height: 790)
    }
}

struct ModelSettingsRow: View {
    @EnvironmentObject var store: AppStore
    private var interfaceLocale: Locale { store.interfaceLocale }
    let title: String
    @Binding var configuration: ModelConfiguration
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.tr("\(title)模型", locale: interfaceLocale), selection: $configuration.model) {
                ForEach(ModelChoice.allCases, id: \.self) { Text(L10n.text($0.rawValue, locale: interfaceLocale)).tag($0) }
            }
            HStack {
                TextField(L10n.tr("区域", locale: interfaceLocale), text: $configuration.region)
                Picker(L10n.tr("推理强度", locale: interfaceLocale), selection: $configuration.reasoningEffort) {
                    ForEach(AIModelCatalog.efforts(for: configuration.model), id: \.self) { Text($0).tag($0) }
                }.frame(width: 200)
            }
            Text(AIModelCatalog.modelID(configuration.model) + " · Bedrock Runtime Responses").font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of: configuration.model) { _, model in
            configuration.modelID = ""
            if !AIModelCatalog.efforts(for: model).contains(configuration.reasoningEffort) { configuration.reasoningEffort = "medium" }
        }
    }
}
