import SwiftUI
import MeetingCore
import MeetingCloud

struct AIControls: View {
    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    var preferSummaryOnly = false
    @State private var settings = false
    @State private var confirmSkip = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MeetingSummaryTemplatePicker(meeting: meeting)
            Text("输入来源：\(meeting.transcriptSourceDescription)").font(.caption).foregroundStyle(.secondary)
            HStack {
                if store.isProcessing(meeting.id) {
                    ProgressView().controlSize(.small)
                    Text(store.batchTasks[meeting.id] != nil ? (meeting.batchVersions?.last?.message ?? "处理录音中…")
                         : (meeting.aiTask?.progress ?? "正在准备 AI 处理…")).font(.callout)
                    Spacer()
                    Button("取消处理") { store.cancelAI(meeting.id) }
                } else {
                    Button {
                        store.processAI(meeting.id, operation: preferSummaryOnly && canReuseCorrection ? .summary : .full)
                    } label: {
                        Label(preferSummaryOnly && canReuseCorrection ? "按模板生成纪要" : "校对并生成纪要", systemImage: "sparkles")
                    }.buttonStyle(.borderedProminent).disabled(meeting.status.isActive || meeting.workingSegments.isEmpty)
                    Menu("更多处理") {
                        Button("仅重新校对") { store.processAI(meeting.id, operation: .correction) }
                        Button("按所选模板重新生成纪要（复用校对）") { store.processAI(meeting.id, operation: .summary) }
                            .disabled(meeting.correctionVersions?.contains { $0.isComplete && $0.input.inputRevision == meeting.revision } != true)
                        Divider()
                        Button("跳过校对，直接生成纪要…") { confirmSkip = true }
                    }.disabled(meeting.status.isActive || meeting.workingSegments.isEmpty)
                    Spacer()
                    Button { settings = true } label: { Label("本会议 AI 设置", systemImage: "slider.horizontal.3") }
                        .disabled(meeting.status.isActive)
                }
            }
            if let error = meeting.aiTask?.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                if meeting.correctionVersions?.last?.isComplete == true {
                    Text("校对结果已保留，可在“更多处理”中只重试纪要生成。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if meeting.hasStaleSummary {
                Label("模板或输入内容已变化，已有纪要需要更新；旧版本仍保留。", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
            if store.modelConnectionStatus.contains("当前访问"), !store.isProcessing(meeting.id) {
                Label("最近的模型调用被访问地区限制拒绝。可在设置中验证服务状态。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .sheet(isPresented: $settings) { MeetingAISettings(meeting: meeting).environmentObject(store) }
        .confirmationDialog("明确跳过校对？", isPresented: $confirmSkip, titleVisibility: .visible) {
            Button("使用当前原文与人工修订生成") { store.processAI(meeting.id, operation: .summaryWithoutCorrection) }
        } message: { Text("将使用当前确定转录和人工修改，纪要会标注“已跳过 AI 校对”。") }
    }
    private var canReuseCorrection: Bool {
        meeting.correctionVersions?.contains { $0.isComplete && $0.input.inputRevision == meeting.revision } == true
    }
}

struct CorrectionView: View {
    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    let locate: (String) -> Void
    @State private var selection: UUID?
    var versions: [CorrectionVersion] { meeting.correctionVersions ?? [] }
    var selected: CorrectionVersion? { versions.first { $0.id == selection } ?? versions.last }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AIControls(meeting: meeting)
                if let version = selected {
                    HStack {
                        Picker("校对版本", selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
                            ForEach(Array(versions.enumerated()), id: \.element.id) { index, value in
                                Text("V\(index + 1) · \(value.createdAt.formatted(date: .omitted, time: .shortened))\(value.isComplete ? "" : " · 部分完成")")
                                    .tag(Optional(value.id))
                            }
                        }.frame(maxWidth: 300)
                        Spacer()
                        Button("全部接受") { store.acceptAllCorrections(meeting.id, versionID: version.id) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!version.isComplete || version.input.inputRevision != meeting.revision
                                || meeting.pendingCorrections(in: version).isEmpty || store.isProcessing(meeting.id))
                            .help("接受当前版本全部待确认建议，已撤销项保持不变。原文和人工编辑不会覆盖，之后仍可逐条撤销。")
                            .accessibilityLabel("全部接受当前校对版本的待确认建议")
                        Menu("导出本版校对稿") {
                            ForEach(MeetingExport.Format.allCases, id: \.self) { format in
                                Button(format.rawValue.uppercased()) { store.exportCorrection(meeting, version: version, format: format) }
                            }
                        }
                    }
                    VersionMetadata(configuration: version.configuration, revision: version.input.inputRevision, date: version.createdAt)
                    Text("本版来源：\(version.input.transcriptSource ?? "实时转录")").font(.caption).foregroundStyle(.secondary)
                    if version.input.inputRevision != meeting.revision {
                        Label("这是旧输入版本。当前转录有更新，重新校对后再生成纪要。", systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("原文保留。标点调整可自动生效；字词及敏感信息先待确认。接受或撤销都会保留记录。")
                        .font(.caption).foregroundStyle(.secondary)
                    if version.isComplete && !version.changes.isEmpty {
                        Text("待确认 \(meeting.pendingCorrections(in: version).count) 项。“全部接受”不恢复已撤销项；接受后可重新生成纪要。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if version.changes.isEmpty {
                        Label(version.isComplete ? "未发现需要修改的片段。" : "正在校对，已保存的分块没有修改建议。", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(version.changes) { change in
                        correctionCard(change, version: version)
                    }
                    if !version.warnings.isEmpty {
                        GroupBox("转录疑点") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(version.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.callout) }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    DisclosureGroup("查看本版校对正文") {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(meeting.correctedInput(using: version).segments) { segment in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(TimeLabel.format(segment.start)) · \(segment.speakerName)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(segment.text).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.top, 12)
                    }
                } else {
                    ContentUnavailableView("准备校对转录", systemImage: "text.badge.checkmark",
                        description: Text("校对将保留原意与疑点。人工编辑的片段会受到保护。"))
                }
            }.padding(28)
        }.onChange(of: versions.count) { _, _ in selection = versions.last?.id }
    }

    private func correctionCard(_ change: AICorrection, version: CorrectionVersion) -> some View {
        let disposition = meeting.disposition(of: change, in: version)
        let segment = version.input.segments.first { $0.id == change.segmentID }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(TimeLabel.format(segment?.start ?? 0)) · \(segment?.speakerName ?? "")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(disposition == .accepted ? "已生效" : disposition == .pending ? "待确认" : "已撤销")
                    .font(.caption).foregroundStyle(disposition == .pending ? .orange : .teal)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("修改前").font(.caption).foregroundStyle(.secondary)
                    Text(change.before).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text("建议").font(.caption).foregroundStyle(.teal)
                    Text(change.after).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(change.reason).font(.caption).foregroundStyle(.secondary)
            Button("定位原文并手动编辑") { locate(change.segmentID) }.buttonStyle(.borderless)
            HStack {
                Button("接受") { store.review(meeting.id, versionID: version.id, changeID: change.id, disposition: .accepted) }
                    .disabled(disposition == .accepted)
                Button("撤销 / 不采用") { store.review(meeting.id, versionID: version.id, changeID: change.id, disposition: .rejected) }
                    .disabled(disposition == .rejected)
                Button("标为待确认") { store.review(meeting.id, versionID: version.id, changeID: change.id, disposition: .pending) }
                    .disabled(disposition == .pending)
            }.disabled(!version.isComplete || version.input.inputRevision != meeting.revision || store.isProcessing(meeting.id))
        }.padding(18).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MinutesView: View {
    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    let locate: (String) -> Void
    @State private var selection: UUID?
    @State private var editing = false
    @State private var editingVersion: MinutesVersion?
    @State private var markdown = ""
    var versions: [MinutesVersion] { meeting.minuteVersions ?? [] }
    var selected: MinutesVersion? { versions.first { $0.id == selection } ?? versions.last }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AIControls(meeting: meeting, preferSummaryOnly: true)
                if let version = selected {
                    HStack {
                        Picker("纪要版本", selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
                            ForEach(Array(versions.enumerated()), id: \.element.id) { index, value in
                                Text("V\(index + 1) · \(value.createdAt.formatted(date: .omitted, time: .shortened)) · \(value.isHumanEdited ? "人工编辑" : "AI")").tag(Optional(value.id))
                            }
                        }.frame(maxWidth: 320)
                        Spacer()
                        Button("编辑并保存新版本") { editingVersion = version; markdown = MeetingExport.minutesBody(version); editing = true }
                        Menu("导出本版纪要") {
                            ForEach(MeetingExport.Format.allCases, id: \.self) { format in
                                Button(format.rawValue.uppercased()) { store.exportMinutes(version, format: format) }
                            }
                        }
                    }
                    VersionMetadata(configuration: version.configuration, revision: version.input.inputRevision, date: version.createdAt)
                    Text("本版来源：\(version.input.transcriptSource ?? "实时转录")").font(.caption).foregroundStyle(.secondary)
                    Text("本版模板：\(version.summaryTemplateDescription)")
                        .font(.caption).foregroundStyle(.secondary)
                    if meeting.isStale(version) { Text("此版本的输入已过时，引用保留生成时的原话。").font(.caption).foregroundStyle(.orange) }
                    if let edited = version.editedMarkdown {
                        Label("人工编辑版；下方引用来自原 AI 版本，人工新增内容未自动验证。", systemImage: "pencil")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(edited).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        CitationButtons(citations: MeetingExport.allCitations(version), input: version.input, locate: locate)
                    } else {
                        heading(version.effectiveSummaryTemplate.outputOverviewTitle(language: version.language), icon: "text.alignleft")
                        Text(version.minutes.overview).lineSpacing(5).textSelection(.enabled)
                        if let sections = version.minutes.sections {
                            ForEach(sections) { section in
                                if section.kind == .actions { actions(section.title, values: section.actions, version: version) }
                                else {
                                    points(section.title, icon: section.kind == .questions ? "questionmark.circle" : "list.bullet",
                                           values: section.points, version: version)
                                }
                            }
                            if !version.minutes.supplementalQuestions.isEmpty {
                                points("需要核对的结论", icon: "questionmark.circle", values: version.minutes.supplementalQuestions, version: version)
                            }
                        } else {
                            points("主要议题", icon: "list.bullet", values: version.minutes.topics, version: version)
                            points("已确认决策", icon: "checkmark.seal", values: version.minutes.decisions, version: version)
                            actions("行动项", values: version.minutes.actions, version: version)
                            points("待确认问题", icon: "questionmark.circle", values: version.minutes.questions, version: version)
                        }
                        if !version.minutes.limitations.isEmpty {
                            heading("记录限制与疑点", icon: "exclamationmark.triangle")
                            ForEach(Array(version.minutes.limitations.enumerated()), id: \.offset) { _, value in
                                Text("• \(value)").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if !version.input.userNote.isEmpty {
                            heading("用户补充 · 人工备注", icon: "note.text")
                            Text(version.input.userNote).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                } else {
                    ContentUnavailableView("按模板整理记录", systemImage: "text.document",
                        description: Text("将按“\(meeting.settings.effectiveSummaryTemplate.name)”整理，并保留可核对的原文引用。"))
                }
            }.padding(28)
        }
        .onChange(of: versions.count) { _, _ in selection = versions.last?.id }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("编辑纪要 · 保存为新版本").font(.title2)
                Text("原 AI 版本保留。人工新增内容不会自动获得原文引用。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $markdown).font(.system(.body, design: .monospaced)).frame(minHeight: 400)
                HStack {
                    Button("取消") { editing = false }
                    Spacer()
                    Button("保存新版本") {
                        if let version = editingVersion { store.editMinutes(meeting.id, version: version, markdown: markdown) }
                        editing = false
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 720, height: 600)
        }
    }
    private func heading(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline).padding(.top, 5)
    }
    @ViewBuilder private func points(_ title: String, icon: String, values: [MinutesPoint], version: MinutesVersion) -> some View {
        heading(title, icon: icon)
        if values.isEmpty { Text(title == "已确认决策" ? "未发现明确达成的决策。" : "无单独提取的条目。").foregroundStyle(.secondary) }
        ForEach(values) { point in
            VStack(alignment: .leading, spacing: 9) {
                Text(point.text).lineSpacing(4).textSelection(.enabled)
                CitationButtons(citations: point.citations, input: version.input, locate: locate)
            }.padding(.bottom, 5)
        }
    }
    @ViewBuilder private func actions(_ title: String, values: [MinutesAction], version: MinutesVersion) -> some View {
        heading(title, icon: "checklist")
        if values.isEmpty { Text("未发现明确行动项。").foregroundStyle(.secondary) }
        ForEach(values) { action in
            VStack(alignment: .leading, spacing: 10) {
                Text(action.task).fontWeight(.medium).textSelection(.enabled)
                HStack(spacing: 18) {
                    Label(action.owner ?? "负责人未明确", systemImage: "person")
                    Label(action.dueDate ?? "截止日期未明确", systemImage: "calendar")
                }.font(.caption).foregroundStyle(.secondary)
                CitationButtons(citations: action.citations, input: version.input, locate: locate)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.teal.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct CitationButtons: View {
    let citations: [SourceCitation]
    let input: AIInputSnapshot
    let locate: (String) -> Void
    @State private var selected: SourceCitation?
    var unique: [SourceCitation] {
        var seen = Set<String>(); return citations.filter { seen.insert($0.id).inserted }
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(unique) { citation in
                    Button {
                        selected = citation
                    } label: {
                        Label(TimeLabel.format(input.segments.first(where: { $0.id == citation.segmentID })?.start ?? 0),
                              systemImage: "quote.bubble").font(.caption)
                    }.buttonStyle(.bordered)
                        .accessibilityLabel("查看原文 \(citation.reference)")
                        .popover(isPresented: Binding(get: { selected?.id == citation.id }, set: { if !$0 { selected = nil } })) {
                            if let source = input.segments.first(where: { $0.id == citation.segmentID }) {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("\(TimeLabel.format(source.start)) · \(source.speakerName)").font(.headline)
                                    Text("生成时输入版本 \(input.inputRevision)").font(.caption).foregroundStyle(.secondary)
                                    Text("“\(citation.quote)”").textSelection(.enabled)
                                    Divider()
                                    Text(source.text).font(.callout).textSelection(.enabled)
                                    if source.text != source.originalText {
                                        Text("原始识别：\(source.originalText)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Button("定位到原始转录") { selected = nil; locate(citation.segmentID) }
                                }.padding(20).frame(width: 430)
                            }
                        }
                }
            }
        }
    }
}

struct VersionMetadata: View {
    let configuration: ModelConfiguration
    let revision: Int
    let date: Date
    var body: some View {
        Text("\(configuration.model.rawValue) / \(configuration.reasoningEffort) · \(configuration.region) / \(configuration.endpoint) · 输入 V\(revision) · \(date.formatted(date: .numeric, time: .shortened))")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

struct MeetingAISettings: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let meeting: Meeting
    @State private var correction = ModelConfiguration()
    @State private var summary = ModelConfiguration()
    @State private var language = "中文"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("本会议的 AI 设置").font(.title2).fontWeight(.semibold)
            Form {
                Section("校对") { ModelSettingsRow(title: "校对", configuration: $correction) }
                Section("纪要") {
                    ModelSettingsRow(title: "总结", configuration: $summary)
                    Picker("输出语言", selection: $language) { Text("中文").tag("中文"); Text("English").tag("English") }
                }
                Text("使用 \(meeting.settings.profile) profile。转录文字、人物信息、术语和必要备注会发送至所选区域的 AWS Bedrock。")
                    .font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            HStack {
                Button("采用当前全局默认值") {
                    correction = store.settings.correction; summary = store.settings.summary; language = store.settings.summaryLanguage
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    store.mutate(meeting.id) { current in
                        current.settings.correction = correction; current.settings.summary = summary
                        current.settings.summaryLanguage = language
                    }; dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 640, height: 550)
            .onAppear { correction = meeting.settings.correction; summary = meeting.settings.summary; language = meeting.settings.summaryLanguage }
    }
}
