import SwiftUI
import AVFoundation
import MeetingCore
import MeetingAudio
import MeetingCloud

struct StartMeetingView: View {
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
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 13) {
                Image(systemName: "record.circle").font(.system(size: 36, weight: .light)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始之前，确认记录范围").font(.title2).fontWeight(.semibold)
                    Text("当前没有采集或上传会议声音。").font(.callout).foregroundStyle(.secondary)
                }
            }
            Form {
                Section("会议信息") {
                    TextField("会议标题", text: $title)
                    Picker("识别语言", selection: $language) {
                        ForEach(RecognitionLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section("纪要模板") {
                    SummaryTemplatePicker(selection: $summaryTemplate)
                }
                Section("音频来源") {
                    Picker("会议应用", selection: Binding(
                        get: { applicationSelection.selected?.id ?? "" },
                        set: { applicationSelection.select(id: $0, applications: applications) }
                    )) {
                        Text(applications.isEmpty ? "请先打开会议应用" : "选择应用").tag("")
                        ForEach(applications) { Text($0.name).tag($0.id) }
                    }
                    Text("支持 \(MeetingApplication.supportedNamesDescription) 的 macOS 客户端。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let unavailable = applicationSelection.unavailable {
                        Text("\(unavailable.name) 已不在运行。请打开它后刷新设备，或手动选择其他会议应用。")
                            .font(.caption).foregroundStyle(.orange)
                    } else if applicationSelection.selected == nil, applications.count > 1 {
                        Text("有多个会议应用正在运行，请选择本次要记录的应用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("同时采集我的麦克风", isOn: $useMicrophone)
                    Picker("麦克风设备", selection: $microphoneID) {
                        Text("选择麦克风").tag(UInt32(0))
                        ForEach(microphones) { Text($0.name).tag($0.id) }
                    }.disabled(!useMicrophone)
                    HStack {
                        Label(microphonePermission, systemImage: "mic").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("刷新设备") { refresh() }
                    }
                    Text("系统音频权限在首次开始时由 macOS 请求。只采集选中的应用；麦克风开关与会议软件静音独立。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("处理与保存") {
                    Toggle("使用 AWS Transcribe 实时转录", isOn: $cloud)
                    Text(cloud ? "两路音频将发送至 AWS（\(store.settings.profile) · \(store.settings.transcribeRegion)），分别计算转录用量。" : "仅验证本地音频采集，不会获得实时转录。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("使用全局自定义词汇表", isOn: $useVocabulary).disabled(!cloud && !automaticBatch)
                    if useVocabulary && (cloud || automaticBatch) {
                        Text(store.vocabularyReadiness(language: language)).font(.caption).foregroundStyle(.secondary)
                    }
                    VocabularyManagerButton()
                    Toggle("结束后自动用录音重新转录", isOn: $automaticBatch)
                    if automaticBatch {
                        Text("自动保留录音，结束后上传至 S3（\(store.batchBucket.isEmpty ? "请先在设置填写桶名" : store.batchBucket)）并批量转录，产生额外用量。完成后等待你复核、采用，再进行 AI 校对和纪要。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("保留本地音频缓存", isOn: Binding(get: { cache || automaticBatch }, set: { cache = $0 })).disabled(automaticBatch)
                    Text(cache || automaticBatch ? "缓存保留至你删除会议。会后可在“录音复核”中手动提交批量转录。" : "不保存音频文件，会后无法重新转录。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(automaticBatch ? "自动批量模式优先：结束后先重转录并等待复核，不会直接生成 AI 纪要。" : (store.settings.automaticallyGenerateMinutes ?? true)
                         ? "结束后自动校对并生成纪要。转录、人物信息、术语和必要备注将发送至 AWS Bedrock：\(store.settings.correction.model.rawValue) / \(store.settings.correction.reasoningEffort) 校对；\(store.settings.summary.model.rawValue) / \(store.settings.summary.reasoningEffort) 总结。"
                         : "自动 AI 处理已关闭；会后可以手动校对和生成纪要。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).frame(height: 430)
            if cloud && !automaticBatch && (store.settings.automaticallyGenerateMinutes ?? true) {
                Text("会后还会将确定转录与必要备注发送至 AWS Bedrock 校对、生成纪要。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("我已确认可记录本次会议，并了解所选采集和云端处理范围。", isOn: $consent).font(.callout)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.starting)
                Spacer()
                if store.starting { ProgressView().controlSize(.small) }
                Button(store.starting ? "正在准备…" : "开始记录") {
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
        }.padding(28).frame(width: 610).interactiveDismissDisabled(store.starting)
            .onAppear {
                refresh(); language = store.settings.language; cache = store.settings.cacheAudio
                summaryTemplate = store.settings.effectiveSummaryTemplate
                useVocabulary = store.vocabularyLibrary.useByDefault
                automaticBatch = store.settings.automaticBatchTranscription ?? false
                title = "会议 · \(Date().formatted(.dateTime.month().day().hour().minute()))"
            }
    }
    private var microphonePermission: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "麦克风已授权"
        case .notDetermined: "开始后请求麦克风权限"
        default: "麦克风未授权，请检查系统设置"
        }
    }
    private func refresh() {
        applications = AudioDevices.meetingApplications(); microphones = AudioDevices.microphones()
        applicationSelection.refresh(applications: applications)
        if !microphones.contains(where: { $0.id == microphoneID }) { microphoneID = AudioDevices.defaultInputID() }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.title2).fontWeight(.semibold)
            Form {
                Section("AWS 连接") {
                    TextField("AWS profile", text: $store.settings.profile)
                    TextField("Transcribe 区域", text: $store.settings.transcribeRegion)
                    HStack {
                        Text(store.connectionStatus).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("检查凭证") { store.checkConnection() }.disabled(store.checkingConnection)
                    }
                    Text("复用本机 AWS profile，不在会议资料中保存密钥。凭证检查不发送会议内容，也不验证推理权限。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("默认语言") {
                    Picker("识别语言", selection: $store.settings.language) {
                        ForEach(RecognitionLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("纪要语言", selection: $store.settings.summaryLanguage) {
                        Text("中文").tag("中文"); Text("English").tag("English")
                    }
                }
                Section("全局转录词汇表") {
                    VocabularyManagerButton()
                    Text("统一维护中文、英文词条，同步到 AWS 后用于新录音的实时转录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("会后用录音重新转录") {
                    Picker("执行方式", selection: Binding(
                        get: { store.settings.automaticBatchTranscription ?? false },
                        set: { store.settings.automaticBatchTranscription = $0 })) {
                        Text("可选：会后手动触发").tag(false)
                        Text("默认：结束记录后自动执行").tag(true)
                    }
                    TextField("录音上传 S3 桶", text: Binding(
                        get: { store.settings.batchTranscriptionBucket ?? "" },
                        set: { store.settings.batchTranscriptionBucket = $0 }))
                    Text("留空时使用全局词汇表的 S3 桶。当前：\(store.batchBucket.isEmpty ? "未配置" : store.batchBucket)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("手动模式需提前保留本地录音。自动模式会为新会议保留录音并上传到同区域 S3，产生额外转录及存储用量；先等待复核，采用后再校对和总结。每场会议开始前可单独调整。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("新记录的默认纪要模板") {
                    SummaryTemplatePicker(selection: Binding(
                        get: { store.settings.effectiveSummaryTemplate },
                        set: { store.settings.summaryTemplate = $0 }
                    ))
                }
                Section("AI 校对与纪要") {
                    Toggle("结束记录后自动校对并生成纪要", isOn: Binding(
                        get: { store.settings.automaticallyGenerateMinutes ?? true },
                        set: { store.settings.automaticallyGenerateMinutes = $0 }))
                    if store.settings.automaticBatchTranscription == true {
                        Text("自动重转录优先，AI 处理将在你复核并采用批量结果后手动继续。").font(.caption).foregroundStyle(.secondary)
                    }
                    ModelSettingsRow(title: "校对", configuration: $store.settings.correction)
                    ModelSettingsRow(title: "总结", configuration: $store.settings.summary)
                    Text("使用 AWS Bedrock Runtime Responses。接入所选区域，由 AWS 按 global 推理配置跨区域路由。每次请求固定模型与推理强度；重新生成会保存新版本并产生调用用量。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top) {
                        Text(store.modelConnectionStatus).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("验证模型调用") { store.checkModelConnection() }.disabled(store.checkingModel)
                    }
                }
                Section("记录与存储") {
                    Toggle("会议应用运行时提醒", isOn: $store.settings.detectMeetings)
                    Text("支持 \(MeetingApplication.supportedNamesDescription)。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("默认开启本地音频缓存", isOn: $store.settings.cacheAudio)
                    Text("缓存默认关闭。开启后保留至手动删除会议；自动到期清理尚未启用。").font(.caption).foregroundStyle(.secondary)
                    Button("在 Finder 中打开资料目录") { NSWorkspace.shared.open(store.directory) }
                }
            }.formStyle(.grouped)
            HStack {
                Text("设置变更只用于下一次记录。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存并关闭") { store.saveSettings(); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 640, height: 740)
    }
}

struct ModelSettingsRow: View {
    let title: String
    @Binding var configuration: ModelConfiguration
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("\(title)模型", selection: $configuration.model) {
                ForEach(ModelChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            HStack {
                TextField("区域", text: $configuration.region)
                Picker("推理强度", selection: $configuration.reasoningEffort) {
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
