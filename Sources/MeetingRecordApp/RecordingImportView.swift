import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeetingCore

struct RecordingImportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var source: URL?
    @State private var title = ""
    @State private var startedAt = Date()
    @State private var language = RecognitionLanguage.mixed
    @State private var transcribe = true
    @State private var provider = RecordingReviewProvider.transcribe
    @State private var bucket = ""
    @State private var vocabulary = false
    private var busy: Bool { store.importTask != nil }

    var body: some View {
        let locale = store.interfaceLocale
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.tr("导入录音", locale: locale), systemImage: "square.and.arrow.down").font(.title2)
            Text(L10n.tr("导入已有录音，转录后复核并采用，即可继续校对和生成纪要。", locale: locale)).foregroundStyle(.secondary)
            GroupBox {
                HStack {
                    Image(systemName: "waveform").foregroundStyle(.teal)
                    Text(source?.lastPathComponent ?? L10n.tr("尚未选择录音", locale: locale)).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button(L10n.tr("选择文件…", locale: locale)) { chooseFile() }.disabled(busy)
                }.padding(10)
            }
            Text(L10n.tr("支持 M4A、MP3、WAV、CAF、AIFF，最长 4 小时。原文件保留；应用内副本遵循录音缓存清理设置。", locale: locale))
                .font(.caption).foregroundStyle(.secondary)
            Group {
                TextField(L10n.tr("会议标题", locale: locale), text: $title)
                DatePicker(L10n.tr("录音开始时间", locale: locale), selection: $startedAt)
                Picker(L10n.tr("识别语言", locale: locale), selection: $language) {
                    ForEach(RecognitionLanguage.selectableCases, id: \.self) { Text(L10n.text($0.title, locale: locale)).tag($0) }
                }
                Toggle(L10n.tr("导入后立即上传并转录", locale: locale), isOn: $transcribe)
                if transcribe {
                    Picker(L10n.tr("本次录音复核服务", locale: locale), selection: $provider) {
                        ForEach(RecordingReviewProvider.allCases, id: \.self) { Text(L10n.text($0.title, locale: locale)).tag($0) }
                    }
                    TextField(L10n.tr("录音上传 S3 桶", locale: locale), text: $bucket)
                    Toggle(L10n.tr("使用当前全局词汇表", locale: locale), isOn: $vocabulary)
                    Text(L10n.tr("音频将上传到配置的 S3 桶并交给所选识别服务处理，产生识别、存储和流量费用。结果保存后自动尝试清理临时云端文件。", locale: locale))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L10n.tr("仅保存到本地，稍后在“录音复核”中上传并转录。", locale: locale)).font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(busy)
            if busy { ProgressView(L10n.tr("正在导入录音…", locale: locale)) }
            if let error = store.recordingImportError { Text(L10n.message(error, locale: locale)).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button(L10n.tr("取消", locale: locale)) {
                    if busy { store.importTask?.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(transcribe ? L10n.tr("导入并转录", locale: locale) : L10n.tr("导入到本地", locale: locale)) { startImport() }
                    .buttonStyle(.borderedProminent).disabled(source == nil || busy).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 610)
            .interactiveDismissDisabled(busy)
            .onAppear {
                language = store.settings.language.forNewRecording
                provider = store.settings.effectiveReviewProvider; bucket = store.batchBucket
                vocabulary = store.vocabularyLibrary.useByDefault; store.recordingImportError = nil
            }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url; title = url.deletingPathExtension().lastPathComponent
    }

    private func startImport() {
        guard let source else { return }
        do {
            var configuration = store.settings
            configuration.language = language
            if transcribe {
                try CustomVocabularyLibrary.validateBucket(bucket.trimmingCharacters(in: .whitespacesAndNewlines))
                let draft = Meeting(title: title, applicationName: "", bundleID: "", microphoneName: "", settings: configuration)
                configuration = try store.batchConfiguration(for: draft, useVocabulary: vocabulary, provider: provider)
            }
            store.importRecording(source: source, title: title, startedAt: startedAt, configuration: configuration,
                transcribe: transcribe, bucket: bucket)
        } catch { store.recordingImportError = error.localizedDescription }
    }
}
