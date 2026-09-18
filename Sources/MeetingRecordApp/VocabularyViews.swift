import SwiftUI
import MeetingCore

struct VocabularyManagerButton: View {
    private var interfaceLocale: Locale { store.interfaceLocale }
    @EnvironmentObject var store: AppStore
    @State private var managing = false
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        Button { managing = true } label: { Label(L10n.tr("全局词汇表", locale: interfaceLocale), systemImage: "text.book.closed") }
            .sheet(isPresented: $managing) { VocabularyManagerView().environmentObject(store) }
    }
}

struct VocabularyManagerView: View {
    private var interfaceLocale: Locale { store.interfaceLocale }
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var search = ""
    @State private var selectedID: UUID?
    @State private var editing: VocabularyEntry?
    @State private var importing = false
    @State private var deleting = false
    @State private var cleaning = false
    @State private var bucket = ""
    var selected: VocabularyEntry? { store.vocabularyLibrary.entries.first { $0.id == selectedID } }
    var entries: [VocabularyEntry] {
        store.vocabularyLibrary.entries.filter {
            search.isEmpty || ($0.phrase + " " + $0.displayAs + " " + $0.note).localizedCaseInsensitiveContains(search)
        }
    }
    var locked: Bool { store.vocabularyBusy || store.vocabularyLibraryError != nil }

    var body: some View {
        let interfaceLocale = self.interfaceLocale
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("全局转录词汇表", locale: interfaceLocale)).font(.title2).fontWeight(.semibold)
            Text(L10n.tr("用于 AWS Transcribe 识别人名、产品名和专业术语。中文、日文、英文分别同步；混合识别使用中英或英日对应的词汇表。", locale: interfaceLocale))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField(L10n.tr("搜索词条、输出写法或备注", locale: interfaceLocale), text: $search).textFieldStyle(.roundedBorder)
                Spacer()
                Button(L10n.tr("新增词条", locale: interfaceLocale)) { editing = VocabularyEntry() }.disabled(locked)
                Button(L10n.tr("批量添加", locale: interfaceLocale)) { importing = true }.disabled(locked)
                Button(L10n.tr("编辑", locale: interfaceLocale)) { editing = selected }.disabled(locked || selected == nil)
                Button(L10n.tr("删除", locale: interfaceLocale), role: .destructive) { deleting = true }.disabled(locked || selected == nil)
            }
            Table(entries, selection: $selectedID) {
                TableColumn(L10n.tr("启用", locale: interfaceLocale)) { entry in
                    Toggle(L10n.tr("启用 \(entry.phrase)", locale: interfaceLocale), isOn: Binding(get: { entry.enabled }, set: { enabled in
                        var changed = entry; changed.enabled = enabled
                        do { try store.saveVocabularyEntry(changed) } catch { store.vocabularyError = error.localizedDescription }
                    })).labelsHidden().toggleStyle(.checkbox).disabled(locked)
                }.width(75)
                TableColumn(L10n.tr("语言", locale: interfaceLocale)) { Text(L10n.text($0.language.title, locale: interfaceLocale)) }.width(85)
                TableColumn(L10n.tr("词条", locale: interfaceLocale)) { Text($0.phrase).help($0.phrase) }
                TableColumn(L10n.tr("输出写法", locale: interfaceLocale)) { Text($0.displayAs.isEmpty ? L10n.tr("默认", locale: interfaceLocale) : $0.displayAs) }
                TableColumn(L10n.tr("本地备注", locale: interfaceLocale)) { Text($0.note).foregroundStyle(.secondary).help($0.note) }
            }.frame(minHeight: 210)
            Text(L10n.tr("例：A.W.S. → AWS；Amazon-Bedrock → Amazon Bedrock。词条中的空格会转为连字符，数字请写读音，输出写法可以保留数字和符号。", locale: interfaceLocale))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            configuration
            deploymentStatus
            if let error = store.vocabularyLibraryError ?? store.vocabularyError {
                Text(L10n.message(error, locale: interfaceLocale)).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(4).help(L10n.message(error, locale: interfaceLocale))
            }
            HStack {
                Text(L10n.tr("本地 \(store.vocabularyLibrary.entries.count) 条 · 启用 \(store.vocabularyLibrary.entries.filter(\.enabled).count) 条", locale: interfaceLocale))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("关闭", locale: interfaceLocale)) { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.vocabularyBusy)
            }
        }
        .padding(24).frame(width: 900, height: 770)
        .interactiveDismissDisabled(store.vocabularyBusy)
        .onAppear { bucket = store.vocabularyLibrary.bucket }
        .sheet(item: $editing) { VocabularyEntryEditor(entry: $0).environmentObject(store) }
        .sheet(isPresented: $importing) { VocabularyBulkEditor().environmentObject(store) }
        .confirmationDialog(L10n.tr("删除选中的本地词条？", locale: interfaceLocale), isPresented: $deleting, titleVisibility: .visible) {
            Button(L10n.tr("删除词条", locale: interfaceLocale), role: .destructive) { if let selectedID { store.deleteVocabularyEntry(selectedID) } }
        } message: { Text(L10n.tr("下一次同步后不再加入新录音。历史词汇表版本和转录保持不变。", locale: interfaceLocale)) }
        .confirmationDialog(L10n.tr("清理 \(store.vocabularyCleanupCandidates.count) 个云端旧版本？", locale: interfaceLocale), isPresented: $cleaning, titleVisibility: .visible) {
            Button(L10n.tr("清理旧版本及对应 S3 文件", locale: interfaceLocale), role: .destructive) { store.cleanOldVocabularyVersions() }
        } message: { Text(L10n.tr("只清理本应用创建、当前词条不再使用且没有本地会议引用的版本。", locale: interfaceLocale)) }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("同步目标：\(store.settings.profile) · \(store.settings.transcribeRegion)", locale: interfaceLocale)).font(.callout)
                Spacer()
                Toggle(L10n.tr("新录音默认使用", locale: interfaceLocale), isOn: Binding(
                    get: { store.vocabularyLibrary.useByDefault },
                    set: { store.setVocabularyOptions(useByDefault: $0) })).disabled(locked)
            }
            HStack {
                TextField(L10n.tr("同区域 S3 桶名", locale: interfaceLocale), text: $bucket).textFieldStyle(.roundedBorder).disabled(locked)
                Button(L10n.tr("保存桶名", locale: interfaceLocale)) { store.setVocabularyOptions(bucket: bucket) }.disabled(locked)
                Button(L10n.tr("同步到 AWS", locale: interfaceLocale)) { store.synchronizeVocabulary(bucket: bucket) }
                    .buttonStyle(.borderedProminent).disabled(locked)
            }
            Text(L10n.tr("使用已有的同区域 S3 桶保存词汇表文本。保存词条只存本机；同步会上传词条和输出写法，备注不上传。请在设置中更改 profile／区域。", locale: interfaceLocale))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.tr("仅 READY 版本用于新录音。已有会议保留原词汇表快照；此表不会替代“术语与备注”的 AI 校对上下文。", locale: interfaceLocale))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var deploymentStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if store.vocabularyBusy { ProgressView().controlSize(.small) }
                Text(L10n.message(store.vocabularyStatus, locale: interfaceLocale)).font(.caption)
                Spacer()
                if store.vocabularyBusy { Button(L10n.tr("取消同步", locale: interfaceLocale)) { store.vocabularyTask?.cancel() } }
                Button(L10n.tr("清理旧版本（\(store.vocabularyCleanupCandidates.count)）", locale: interfaceLocale)) { cleaning = true }
                    .disabled(locked || store.starting || store.vocabularyCleanupCandidates.isEmpty)
            }
            if let plans = try? store.vocabularyLibrary.plans() {
                HStack(spacing: 22) {
                    ForEach(plans, id: \.binding.name) { plan in
                        let deployment = store.vocabularyLibrary.deployments.last {
                            $0.scope == store.vocabularyScope && $0.binding == plan.binding
                        }
                        Text(L10n.tr("\(L10n.text(plan.binding.language.title, locale: interfaceLocale)) \(plan.binding.entryCount) 条 · \(L10n.text(deployment?.state.title ?? "未同步", locale: interfaceLocale))", locale: interfaceLocale))
                            .font(.caption).foregroundStyle(deployment?.state == .ready ? .green : .secondary)
                            .help(plan.binding.name)
                    }
                }
            }
        }
    }
}

private struct VocabularyEntryEditor: View {
    private var interfaceLocale: Locale { store.interfaceLocale }
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var entry: VocabularyEntry
    @State private var error: String?
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("词汇表条目", locale: interfaceLocale)).font(.title2)
            Form {
                Picker(L10n.tr("语言", locale: interfaceLocale), selection: $entry.language) {
                    ForEach(VocabularyLanguage.allCases, id: \.self) { Text(L10n.text($0.title, locale: interfaceLocale)).tag($0) }
                }
                TextField(L10n.tr("词条 / 发音拼写", locale: interfaceLocale), text: $entry.phrase, prompt: Text(L10n.tr("例如 A.W.S. 或 亚马逊", locale: interfaceLocale)))
                TextField(L10n.tr("输出写法（可选）", locale: interfaceLocale), text: $entry.displayAs, prompt: Text(L10n.tr("例如 AWS", locale: interfaceLocale)))
                TextField(L10n.tr("备注（仅本地）", locale: interfaceLocale), text: $entry.note, axis: .vertical).lineLimit(2...3)
                Toggle(L10n.tr("启用该条目", locale: interfaceLocale), isOn: $entry.enabled)
            }
            Text(L10n.tr("缩写按字母读时用句点分隔，例如 A.W.S.；数字在词条中写读音，在输出写法中可使用 0–9。AWS 会进一步检查对应语言的字符集。", locale: interfaceLocale))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(L10n.message(error, locale: interfaceLocale)).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(L10n.tr("取消", locale: interfaceLocale)) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("保存到本地", locale: interfaceLocale)) {
                    do { try store.saveVocabularyEntry(entry); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540)
    }
}

private struct VocabularyBulkEditor: View {
    private var interfaceLocale: Locale { store.interfaceLocale }
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var language: VocabularyLanguage = .english
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("批量添加词条", locale: interfaceLocale)).font(.title2)
            Picker(L10n.tr("这批词条的语言", locale: interfaceLocale), selection: $language) {
                ForEach(VocabularyLanguage.allCases, id: \.self) { Text(L10n.text($0.title, locale: interfaceLocale)).tag($0) }
            }
            Text(L10n.tr("每行一个词条，可粘贴两列：词条 + 制表符 + 输出写法。例如从表格复制两列内容。重复或格式错误时整批不保存。", locale: interfaceLocale))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(height: 240).border(.secondary.opacity(0.3))
            if let error { Text(L10n.message(error, locale: interfaceLocale)).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(L10n.tr("取消", locale: interfaceLocale)) { dismiss() }
                Spacer()
                Button(L10n.tr("添加到本地", locale: interfaceLocale)) {
                    do {
                        let count = try store.importVocabulary(text, language: language)
                        store.vocabularyStatus = "已添加 \(count) 条，请同步后用于新录音。"
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 620)
    }
}
