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
    @State private var applicationID = ""
    @State private var microphoneID: UInt32 = 0
    @State private var title = ""
    @State private var language: RecognitionLanguage = .mixed
    @State private var useMicrophone = true
    @State private var cloud = true
    @State private var cache = false
    @State private var consent = false
    @State private var summaryTemplate = SummaryTemplate.meeting

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
                    Picker("会议应用", selection: $applicationID) {
                        Text(applications.isEmpty ? "请先打开会议应用" : "选择应用").tag("")
                        ForEach(applications) { Text($0.name).tag($0.id) }
                    }
                    Text("支持 \(MeetingApplication.supportedNamesDescription) 的 macOS 客户端。")
                        .font(.caption).foregroundStyle(.secondary)
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
                    Toggle("保留本地音频缓存", isOn: $cache)
                    Text(cache ? "缓存保留至你删除会议，不自动到期清理。断网补转尚未接入，音频会明确标为待处理。" : "不保存音频文件。转录失败的区间无法从本机音频补回。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text((store.settings.automaticallyGenerateMinutes ?? true)
                         ? "结束后自动校对并生成纪要。转录、人物信息、术语和必要备注将发送至 AWS Bedrock：\(store.settings.correction.model.rawValue) / \(store.settings.correction.reasoningEffort) 校对；\(store.settings.summary.model.rawValue) / \(store.settings.summary.reasoningEffort) 总结。"
                         : "自动 AI 处理已关闭；会后可以手动校对和生成纪要。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).frame(height: 430)
            if cloud && (store.settings.automaticallyGenerateMinutes ?? true) {
                Text("会后还会将确定转录与必要备注发送至 AWS Bedrock 校对、生成纪要。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("我已确认可记录本次会议，并了解所选采集和云端处理范围。", isOn: $consent).font(.callout)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.starting)
                Spacer()
                if store.starting { ProgressView().controlSize(.small) }
                Button(store.starting ? "正在准备…" : "开始记录") {
                    guard let application = applications.first(where: { $0.id == applicationID }) else { return }
                    Task {
                        await store.start(title: title, application: application,
                            microphone: microphones.first(where: { $0.id == microphoneID }),
                            useMicrophone: useMicrophone, cloud: cloud, cache: cache, language: language, summaryTemplate: summaryTemplate)
                    }
                }.buttonStyle(.borderedProminent).tint(.teal).keyboardShortcut(.defaultAction)
                    .disabled(!consent || applicationID.isEmpty || (useMicrophone && microphoneID == 0) || store.starting)
            }
        }.padding(28).frame(width: 610).interactiveDismissDisabled(store.starting)
            .onAppear {
                refresh(); language = store.settings.language; cache = store.settings.cacheAudio
                summaryTemplate = store.settings.effectiveSummaryTemplate
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
        if !applications.contains(where: { $0.id == applicationID }) { applicationID = applications.first?.id ?? "" }
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
                    ModelSettingsRow(title: "校对", configuration: $store.settings.correction)
                    ModelSettingsRow(title: "总结", configuration: $store.settings.summary)
                    Text("使用 AWS Bedrock Mantle。每次请求固定模型与推理强度，不自动切换模型或区域。重新生成会形成新版本并产生调用用量。")
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
            Text(AIModelCatalog.modelID(configuration.model) + " · Bedrock Mantle").font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of: configuration.model) { _, model in
            configuration.modelID = ""
            if !AIModelCatalog.efforts(for: model).contains(configuration.reasoningEffort) { configuration.reasoningEffort = "medium" }
        }
    }
}
