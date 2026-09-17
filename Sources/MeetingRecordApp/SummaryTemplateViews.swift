import SwiftUI
import MeetingCore

struct SummaryTemplatePicker: View {
    @EnvironmentObject var store: AppStore
    @Binding var selection: SummaryTemplate
    @State private var managing = false
    var options: [SummaryTemplate] {
        let library = store.templateLibrary.all
        return library.contains(where: { $0 == selection }) ? library : library + [selection]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Picker("纪要模板", selection: Binding(
                    get: { selection.selectionKey },
                    set: { key in if let value = options.first(where: { $0.selectionKey == key }) { selection = value } }
                )) {
                    ForEach(options, id: \.selectionKey) { template in
                        Text(template.name + (store.templateLibrary.all.contains(template) ? "" : " · 保存的旧版"))
                            .tag(template.selectionKey)
                    }
                }
                Button("管理模板") { managing = true }
            }
            Text(selection.instructions).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(selection.instructions)
            Text(selection.sections.map(\.title).joined(separator: " → "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .sheet(isPresented: $managing) { SummaryTemplateLibraryView().environmentObject(store) }
    }
}

struct MeetingSummaryTemplatePicker: View {
    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    var body: some View {
        SummaryTemplatePicker(selection: Binding(
            get: { meeting.settings.effectiveSummaryTemplate },
            set: { store.selectSummaryTemplate($0, meetingID: meeting.id) }
        )).disabled(store.isProcessing(meeting.id))
    }
}

struct SummaryTemplateLibraryView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var editing: SummaryTemplate?
    @State private var deleting: SummaryTemplate?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("纪要模板").font(.title2).fontWeight(.semibold)
                Spacer()
                Button { editing = .blank } label: { Label("新增模板", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(store.templateLibraryError != nil)
            }
            Text("模板决定总结视角、章节顺序和整理要求。内置模板可复制；历史纪要保留生成时的模板内容。")
                .font(.callout).foregroundStyle(.secondary)
            if let problem = store.templateLibraryError { Text(problem).foregroundStyle(.red).font(.caption) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("内置模板").font(.headline)
                    ForEach(SummaryTemplate.builtIns) { template in row(template) }
                    Text("我的模板").font(.headline).padding(.top, 8)
                    if store.templateLibrary.custom.isEmpty {
                        Text("可以新建模板，也可以复制内置模板后调整。").foregroundStyle(.secondary)
                    }
                    ForEach(store.templateLibrary.custom) { template in row(template) }
                }
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 780, height: 710)
            .sheet(item: $editing) { template in SummaryTemplateEditor(template: template).environmentObject(store) }
            .confirmationDialog("删除此自定义模板？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除模板", role: .destructive) {
                    if let template = deleting {
                        do { try store.deleteSummaryTemplate(template.id) }
                        catch { self.error = error.localizedDescription }
                    }
                    deleting = nil
                }
            } message: { Text("仅移除模板库条目。已有会议和历史纪要保留原模板；如该模板是全局默认，后续新记录恢复使用“会议纪要”。") }
            .alert("模板操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了") { error = nil }
            } message: { Text(error ?? "") }
    }
    private func row(_ template: SummaryTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(template.name).font(.headline)
                Text("V\(template.revision)").font(.caption).foregroundStyle(.secondary)
                if store.settings.effectiveSummaryTemplate.id == template.id {
                    Text("新记录默认").font(.caption).foregroundStyle(.teal)
                }
                Spacer()
                Button("设为默认") {
                    do { try store.setDefaultSummaryTemplate(template) }
                    catch { self.error = error.localizedDescription }
                }
                Button("复制") { editing = template.duplicate() }.disabled(store.templateLibraryError != nil)
                if !template.isBuiltIn {
                    Button("编辑") { editing = template }.disabled(store.templateLibraryError != nil)
                    Button("删除", role: .destructive) { deleting = template }.disabled(store.templateLibraryError != nil)
                }
            }
            Text(template.instructions).font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("章节与要求（\(template.sections.count)）") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("概览标题：\(template.overviewTitle)").font(.caption)
                    ForEach(template.sections) { section in
                        Text("\(section.title) · \(section.kind.title)\n\(section.instructions)").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 8)
            }
        }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SummaryTemplateEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var draft: SummaryTemplate
    @State private var error: String?
    init(template: SummaryTemplate) { _draft = State(initialValue: template) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑纪要模板").font(.title2).fontWeight(.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("模板名称，例如：客户需求访谈", text: $draft.name).textFieldStyle(.roundedBorder)
                    Text("总结要求").font(.headline)
                    Text("描述视角、关注点和写作要求；具体章节与顺序在下方设置。原文引用、人工备注隔离和不编造事实的规则始终保留。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draft.instructions).frame(height: 110).border(.quaternary)
                    TextField("概览标题", text: $draft.overviewTitle).textFieldStyle(.roundedBorder)
                    HStack {
                        Text("输出章节 · 按下方顺序生成").font(.headline)
                        Spacer()
                        Button("添加章节") { draft.sections.append(.init(title: "新章节")) }.disabled(draft.sections.count >= 16)
                    }
                    ForEach($draft.sections) { $section in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                TextField("章节标题", text: $section.title)
                                Picker("类型", selection: $section.kind) {
                                    ForEach(SummarySectionKind.allCases, id: \.self) { Text($0.title).tag($0) }
                                }.labelsHidden().frame(width: 190)
                                Button { move(section.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                    .disabled(draft.sections.first?.id == section.id)
                                Button { move(section.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                    .disabled(draft.sections.last?.id == section.id)
                                Button(role: .destructive) { draft.sections.removeAll { $0.id == section.id } } label: { Image(systemName: "trash") }
                                    .disabled(draft.sections.count <= 1)
                            }
                            TextField("本章节需要提取什么内容？", text: $section.instructions, axis: .vertical).lineLimit(2...5)
                        }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Text("“行动项”包含负责人和截止日期；其余类型输出带原文引用的要点。内容不足时保留空章节，不编造补齐。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("保存只更新模板库，不改动历史纪要。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存模板") {
                    do { try store.saveSummaryTemplate(draft); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 780, height: 740)
    }
    private func move(_ id: String, by distance: Int) {
        guard let index = draft.sections.firstIndex(where: { $0.id == id }), draft.sections.indices.contains(index + distance) else { return }
        draft.sections.swapAt(index, index + distance)
    }
}
