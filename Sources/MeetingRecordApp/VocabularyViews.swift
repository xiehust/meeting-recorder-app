import SwiftUI
import MeetingCore

struct VocabularyManagerButton: View {
    @EnvironmentObject var store: AppStore
    @State private var managing = false
    var body: some View {
        Button { managing = true } label: { Label("全局词汇表", systemImage: "text.book.closed") }
            .sheet(isPresented: $managing) { VocabularyManagerView().environmentObject(store) }
    }
}

struct VocabularyManagerView: View {
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
        VStack(alignment: .leading, spacing: 14) {
            Text("全局转录词汇表").font(.title2).fontWeight(.semibold)
            Text("用于 AWS Transcribe 识别人名、产品名和专业术语。中文、英文分别同步，中英混合转录可同时使用。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("搜索词条、输出写法或备注", text: $search).textFieldStyle(.roundedBorder)
                Spacer()
                Button("新增词条") { editing = VocabularyEntry() }.disabled(locked)
                Button("批量添加") { importing = true }.disabled(locked)
                Button("编辑") { editing = selected }.disabled(locked || selected == nil)
                Button("删除", role: .destructive) { deleting = true }.disabled(locked || selected == nil)
            }
            Table(entries, selection: $selectedID) {
                TableColumn("启用") { entry in
                    Toggle("启用 \(entry.phrase)", isOn: Binding(get: { entry.enabled }, set: { enabled in
                        var changed = entry; changed.enabled = enabled
                        do { try store.saveVocabularyEntry(changed) } catch { store.vocabularyError = error.localizedDescription }
                    })).labelsHidden().toggleStyle(.checkbox).disabled(locked)
                }.width(45)
                TableColumn("语言") { Text($0.language.title) }.width(65)
                TableColumn("词条") { Text($0.phrase).help($0.phrase) }
                TableColumn("输出写法") { Text($0.displayAs.isEmpty ? "默认" : $0.displayAs) }
                TableColumn("本地备注") { Text($0.note).foregroundStyle(.secondary).help($0.note) }
            }.frame(minHeight: 210)
            Text("例：A.W.S. → AWS；Amazon-Bedrock → Amazon Bedrock。词条中的空格会转为连字符，数字请写读音，输出写法可以保留数字和符号。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            configuration
            deploymentStatus
            if let error = store.vocabularyLibraryError ?? store.vocabularyError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(3)
            }
            HStack {
                Text("本地 \(store.vocabularyLibrary.entries.count) 条 · 启用 \(store.vocabularyLibrary.entries.filter(\.enabled).count) 条")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.vocabularyBusy)
            }
        }
        .padding(24).frame(width: 900, height: 770)
        .interactiveDismissDisabled(store.vocabularyBusy)
        .onAppear { bucket = store.vocabularyLibrary.bucket }
        .sheet(item: $editing) { VocabularyEntryEditor(entry: $0).environmentObject(store) }
        .sheet(isPresented: $importing) { VocabularyBulkEditor().environmentObject(store) }
        .confirmationDialog("删除选中的本地词条？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除词条", role: .destructive) { if let selectedID { store.deleteVocabularyEntry(selectedID) } }
        } message: { Text("下一次同步后不再加入新录音。历史词汇表版本和转录保持不变。") }
        .confirmationDialog("清理 \(store.vocabularyCleanupCandidates.count) 个云端旧版本？", isPresented: $cleaning, titleVisibility: .visible) {
            Button("清理旧版本及对应 S3 文件", role: .destructive) { store.cleanOldVocabularyVersions() }
        } message: { Text("只清理本应用创建、当前词条不再使用且没有本地会议引用的版本。") }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("同步目标：\(store.settings.profile) · \(store.settings.transcribeRegion)").font(.callout)
                Spacer()
                Toggle("新录音默认使用", isOn: Binding(
                    get: { store.vocabularyLibrary.useByDefault },
                    set: { store.setVocabularyOptions(useByDefault: $0) })).disabled(locked)
            }
            HStack {
                TextField("同区域 S3 桶名", text: $bucket).textFieldStyle(.roundedBorder).disabled(locked)
                Button("保存桶名") { store.setVocabularyOptions(bucket: bucket) }.disabled(locked)
                Button("同步到 AWS") { store.synchronizeVocabulary(bucket: bucket) }
                    .buttonStyle(.borderedProminent).disabled(locked)
            }
            Text("使用已有的同区域 S3 桶保存词汇表文本。保存词条只存本机；同步会上传词条和输出写法，备注不上传。请在设置中更改 profile／区域。")
                .font(.caption).foregroundStyle(.secondary)
            Text("仅 READY 版本用于新录音。已有会议保留原词汇表快照；此表不会替代“术语与备注”的 AI 校对上下文。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var deploymentStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if store.vocabularyBusy { ProgressView().controlSize(.small) }
                Text(store.vocabularyStatus).font(.caption)
                Spacer()
                if store.vocabularyBusy { Button("取消同步") { store.vocabularyTask?.cancel() } }
                Button("清理旧版本（\(store.vocabularyCleanupCandidates.count)）") { cleaning = true }
                    .disabled(locked || store.starting || store.vocabularyCleanupCandidates.isEmpty)
            }
            if let plans = try? store.vocabularyLibrary.plans() {
                HStack(spacing: 22) {
                    ForEach(plans, id: \.binding.name) { plan in
                        let deployment = store.vocabularyLibrary.deployments.last {
                            $0.scope == store.vocabularyScope && $0.binding == plan.binding
                        }
                        Text("\(plan.binding.language.title) \(plan.binding.entryCount) 条 · \(deployment?.state.title ?? "未同步")")
                            .font(.caption).foregroundStyle(deployment?.state == .ready ? .green : .secondary)
                            .help(plan.binding.name)
                    }
                }
            }
        }
    }
}

private struct VocabularyEntryEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var entry: VocabularyEntry
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("词汇表条目").font(.title2)
            Form {
                Picker("语言", selection: $entry.language) {
                    ForEach(VocabularyLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("词条 / 发音拼写", text: $entry.phrase, prompt: Text("例如 A.W.S. 或 亚马逊"))
                TextField("输出写法（可选）", text: $entry.displayAs, prompt: Text("例如 AWS"))
                TextField("备注（仅本地）", text: $entry.note, axis: .vertical).lineLimit(2...3)
                Toggle("启用该条目", isOn: $entry.enabled)
            }
            Text("缩写按字母读时用句点分隔，例如 A.W.S.；数字在词条中写读音，在输出写法中可使用 0–9。AWS 会进一步检查对应语言的字符集。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存到本地") {
                    do { try store.saveVocabularyEntry(entry); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540)
    }
}

private struct VocabularyBulkEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var language: VocabularyLanguage = .english
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("批量添加词条").font(.title2)
            Picker("这批词条的语言", selection: $language) {
                ForEach(VocabularyLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("每行一个词条，可粘贴两列：词条 + 制表符 + 输出写法。例如从表格复制两列内容。重复或格式错误时整批不保存。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(height: 240).border(.secondary.opacity(0.3))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("添加到本地") {
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
