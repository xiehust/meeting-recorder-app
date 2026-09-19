import SwiftUI
import MeetingCore
import MeetingCloud

struct AIControls: View {
    private var interfaceLocale: Locale { store.interfaceLocale }
    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    var preferSummaryOnly = false
    @State private var settings = false
    @State private var confirmSkip = false
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        VStack(alignment: .leading, spacing: 12) {
            MeetingSummaryTemplatePicker(meeting: meeting)
            Text(L10n.tr("输入来源：\(L10n.message(meeting.transcriptSourceDescription, locale: interfaceLocale))", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
            HStack {
                if store.isProcessing(meeting.id) {
                    ProgressView().controlSize(.small)
                    Text(L10n.message(store.batchTasks[meeting.id] != nil ? (meeting.batchVersions?.last?.message ?? "处理录音中…")
                         : (meeting.aiTask?.progress ?? "正在准备 AI 处理…"), locale: interfaceLocale)).font(.callout)
                    Spacer()
                    Button(L10n.tr("取消处理", locale: interfaceLocale)) { store.cancelAI(meeting.id) }
                } else {
                    Button {
                        store.processAI(meeting.id, operation: preferSummaryOnly && canReuseCorrection ? .summary : .full)
                    } label: {
                        Label(preferSummaryOnly && canReuseCorrection ? L10n.tr("按模板生成纪要", locale: interfaceLocale) : L10n.tr("校对并生成纪要", locale: interfaceLocale), systemImage: "sparkles")
                    }.buttonStyle(.borderedProminent).disabled(meeting.status.isActive || meeting.workingSegments.isEmpty)
                    Menu(L10n.tr("更多处理", locale: interfaceLocale)) {
                        Button(L10n.tr("仅重新校对", locale: interfaceLocale)) { store.processAI(meeting.id, operation: .correction) }
                        Button(L10n.tr("按所选模板重新生成纪要（复用校对）", locale: interfaceLocale)) { store.processAI(meeting.id, operation: .summary) }
                            .disabled(meeting.correctionVersions?.contains { $0.isComplete && $0.input.inputRevision == meeting.revision } != true)
                        Divider()
                        Button(L10n.tr("跳过校对，直接生成纪要…", locale: interfaceLocale)) { confirmSkip = true }
                    }.disabled(meeting.status.isActive || meeting.workingSegments.isEmpty)
                    Spacer()
                    Button { settings = true } label: { Label(L10n.tr("本会议 AI 设置", locale: interfaceLocale), systemImage: "slider.horizontal.3") }
                        .disabled(meeting.status.isActive)
                }
            }
            if let error = meeting.aiTask?.error {
                Label(L10n.message(error, locale: interfaceLocale), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                if meeting.correctionVersions?.last?.isComplete == true {
                    Text(L10n.tr("校对结果已保留，可在“更多处理”中只重试纪要生成。", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if meeting.hasStaleSummary {
                Label(L10n.tr("模板或输入内容已变化，已有纪要需要更新；旧版本仍保留。", locale: interfaceLocale), systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }

        }
        .sheet(isPresented: $settings) { MeetingAISettings(meeting: meeting).environmentObject(store) }
        .confirmationDialog(L10n.tr("明确跳过校对？", locale: interfaceLocale), isPresented: $confirmSkip, titleVisibility: .visible) {
            Button(L10n.tr("使用当前原文与人工修订生成", locale: interfaceLocale)) { store.processAI(meeting.id, operation: .summaryWithoutCorrection) }
        } message: { Text(L10n.tr("将使用当前确定转录和人工修改，纪要会标注“已跳过 AI 校对”。", locale: interfaceLocale)) }
    }
    private var canReuseCorrection: Bool {
        meeting.correctionVersions?.contains { $0.isComplete && $0.input.inputRevision == meeting.revision } == true
    }
}

struct CorrectionView: View {
    private var interfaceLocale: Locale { store.interfaceLocale }
    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    let locate: (String) -> Void
    @State private var selection: UUID?
    var versions: [CorrectionVersion] { meeting.correctionVersions ?? [] }
    var selected: CorrectionVersion? { versions.first { $0.id == selection } ?? versions.last }
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AIControls(meeting: meeting)
                if let version = selected {
                    HStack {
                        Picker(L10n.tr("校对版本", locale: interfaceLocale), selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
                            ForEach(Array(versions.enumerated()), id: \.element.id) { index, value in
                                Text("V\(index + 1) · \(value.createdAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale)))\(value.isComplete ? "" : L10n.tr(" · 部分完成", locale: interfaceLocale))")
                                    .tag(Optional(value.id))
                            }
                        }.frame(maxWidth: 300)
                        Spacer()
                        Button(L10n.tr("全部接受", locale: interfaceLocale)) { store.acceptAllCorrections(meeting.id, versionID: version.id) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!version.isComplete || version.input.inputRevision != meeting.revision
                                || meeting.pendingCorrections(in: version).isEmpty || store.isProcessing(meeting.id))
                            .help(L10n.tr("接受当前版本全部待确认建议，已撤销项保持不变。原文和人工编辑不会覆盖，之后仍可逐条撤销。", locale: interfaceLocale))
                            .accessibilityLabel(L10n.tr("全部接受当前校对版本的待确认建议", locale: interfaceLocale))
                        Menu(L10n.tr("导出本版校对稿", locale: interfaceLocale)) {
                            ForEach(MeetingExport.Format.allCases, id: \.self) { format in
                                Button(format.rawValue.uppercased()) { store.exportCorrection(meeting, version: version, format: format) }
                            }
                        }
                    }
                    VersionMetadata(configuration: version.configuration, revision: version.input.inputRevision, date: version.createdAt)
                    Text(L10n.tr("本版来源：\(L10n.message(version.input.transcriptSource ?? "实时转录", locale: interfaceLocale))", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                    if version.input.inputRevision != meeting.revision {
                        Label(L10n.tr("这是旧输入版本。当前转录有更新，重新校对后再生成纪要。", locale: interfaceLocale), systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text(L10n.tr("原文保留。标点调整可自动生效；字词及敏感信息先待确认。接受或撤销都会保留记录。", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                    if version.isComplete && !version.changes.isEmpty {
                        Text(L10n.tr("待确认 \(meeting.pendingCorrections(in: version).count) 项。“全部接受”不恢复已撤销项；接受后可重新生成纪要。", locale: interfaceLocale))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if version.changes.isEmpty {
                        Label(version.isComplete ? L10n.tr("未发现需要修改的片段。", locale: interfaceLocale) : L10n.tr("正在校对，已保存的分块没有修改建议。", locale: interfaceLocale), systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(version.changes) { change in
                        correctionCard(change, version: version)
                    }
                    if !version.warnings.isEmpty {
                        GroupBox(L10n.tr("转录疑点", locale: interfaceLocale)) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(version.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.callout) }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    DisclosureGroup(L10n.tr("查看本版校对正文", locale: interfaceLocale)) {
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
                    ContentUnavailableView(L10n.tr("准备校对转录", locale: interfaceLocale), systemImage: "text.badge.checkmark",
                        description: Text(L10n.tr("校对将保留原意与疑点。人工编辑的片段会受到保护。", locale: interfaceLocale)))
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
                Text(disposition == .accepted ? L10n.tr("已生效", locale: interfaceLocale) : disposition == .pending ? L10n.tr("待确认", locale: interfaceLocale) : L10n.tr("已撤销", locale: interfaceLocale))
                    .font(.caption).foregroundStyle(disposition == .pending ? .orange : .teal)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("修改前", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                    Text(change.before).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("建议", locale: interfaceLocale)).font(.caption).foregroundStyle(.teal)
                    Text(change.after).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(change.reason).font(.caption).foregroundStyle(.secondary)
            Button(L10n.tr("定位原文并手动编辑", locale: interfaceLocale)) { locate(change.segmentID) }.buttonStyle(.borderless)
            HStack {
                Button(L10n.tr("接受", locale: interfaceLocale)) { store.review(meeting.id, versionID: version.id, changeID: change.id, disposition: .accepted) }
                    .disabled(disposition == .accepted)
                Button(L10n.tr("撤销 / 不采用", locale: interfaceLocale)) { store.review(meeting.id, versionID: version.id, changeID: change.id, disposition: .rejected) }
                    .disabled(disposition == .rejected)
                Button(L10n.tr("标为待确认", locale: interfaceLocale)) { store.review(meeting.id, versionID: version.id, changeID: change.id, disposition: .pending) }
                    .disabled(disposition == .pending)
            }.disabled(!version.isComplete || version.input.inputRevision != meeting.revision || store.isProcessing(meeting.id))
        }.padding(18).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MinutesView: View {
    private var interfaceLocale: Locale { store.interfaceLocale }
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
        let interfaceLocale = self.interfaceLocale
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AIControls(meeting: meeting, preferSummaryOnly: true)
                if let version = selected {
                    HStack {
                        Picker(L10n.tr("纪要版本", locale: interfaceLocale), selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
                            ForEach(Array(versions.enumerated()), id: \.element.id) { index, value in
                                Text("V\(index + 1) · \(value.createdAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale))) · \(value.isHumanEdited ? L10n.tr("人工编辑", locale: interfaceLocale) : "AI")").tag(Optional(value.id))
                            }
                        }.frame(maxWidth: 320)
                        Spacer()
                        Button(L10n.tr("编辑并保存新版本", locale: interfaceLocale)) { editingVersion = version; markdown = MeetingExport.minutesBody(version); editing = true }
                        Menu(L10n.tr("导出本版纪要", locale: interfaceLocale)) {
                            ForEach(MeetingExport.Format.allCases, id: \.self) { format in
                                Button(format.rawValue.uppercased()) { store.exportMinutes(version, format: format) }
                            }
                        }
                    }
                    VersionMetadata(configuration: version.configuration, revision: version.input.inputRevision, date: version.createdAt)
                    Text(L10n.tr("本版来源：\(L10n.message(version.input.transcriptSource ?? "实时转录", locale: interfaceLocale))", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.tr("本版模板：\(version.effectiveSummaryTemplate.displayName) · V\(version.effectiveSummaryTemplate.revision)", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                    if meeting.isStale(version) { Text(L10n.tr("此版本的输入已过时，引用保留生成时的原话。", locale: interfaceLocale)).font(.caption).foregroundStyle(.orange) }
                    if let edited = version.editedMarkdown {
                        Label(L10n.tr("人工编辑版；下方引用来自原 AI 版本，人工新增内容未自动验证。", locale: interfaceLocale), systemImage: "pencil")
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
                                points(L10n.tr("需要核对的结论", locale: interfaceLocale), icon: "questionmark.circle", values: version.minutes.supplementalQuestions, version: version)
                            }
                        } else {
                            points(L10n.tr("主要议题", locale: interfaceLocale), icon: "list.bullet", values: version.minutes.topics, version: version)
                            points(L10n.tr("已确认决策", locale: interfaceLocale), icon: "checkmark.seal", values: version.minutes.decisions, version: version)
                            actions(L10n.tr("行动项", locale: interfaceLocale), values: version.minutes.actions, version: version)
                            points(L10n.tr("待确认问题", locale: interfaceLocale), icon: "questionmark.circle", values: version.minutes.questions, version: version)
                        }
                        if !version.minutes.limitations.isEmpty {
                            heading(L10n.tr("记录限制与疑点", locale: interfaceLocale), icon: "exclamationmark.triangle")
                            ForEach(Array(version.minutes.limitations.enumerated()), id: \.offset) { _, value in
                                Text("• \(value)").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if let details = version.minutes.reviewDetails, !details.isEmpty {
                            DisclosureGroup(L10n.tr("录音与校对详情", locale: interfaceLocale)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(details.enumerated()), id: \.offset) { _, value in
                                        Text(value).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }
                        }
                        if !version.input.userNote.isEmpty {
                            heading(L10n.tr("用户补充 · 人工备注", locale: interfaceLocale), icon: "note.text")
                            Text(version.input.userNote).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                } else {
                    ContentUnavailableView(L10n.tr("按模板整理记录", locale: interfaceLocale), systemImage: "text.document",
                        description: Text(L10n.tr("将按“\(meeting.settings.effectiveSummaryTemplate.displayName)”整理，并保留可核对的原文引用。", locale: interfaceLocale)))
                }
            }.padding(28)
        }
        .onChange(of: versions.count) { _, _ in selection = versions.last?.id }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.tr("编辑纪要 · 保存为新版本", locale: interfaceLocale)).font(.title2)
                Text(L10n.tr("原 AI 版本保留。人工新增内容不会自动获得原文引用。", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $markdown).font(.system(.body, design: .monospaced)).frame(minHeight: 400)
                HStack {
                    Button(L10n.tr("取消", locale: interfaceLocale)) { editing = false }
                    Spacer()
                    Button(L10n.tr("保存新版本", locale: interfaceLocale)) {
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
        if values.isEmpty { Text(title == L10n.tr("已确认决策", locale: interfaceLocale) ? L10n.tr("未发现明确达成的决策。", locale: interfaceLocale) : L10n.tr("无单独提取的条目。", locale: interfaceLocale)).foregroundStyle(.secondary) }
        ForEach(Array(values.enumerated()), id: \.element.id) { index, point in
            VStack(alignment: .leading, spacing: 9) {
                if let topic = point.heading, index == 0 || values[index - 1].heading != topic {
                    Text(topic).font(.headline).padding(.top, 8).textSelection(.enabled)
                }
                Text(point.text).lineSpacing(4).textSelection(.enabled)
                CitationButtons(citations: point.citations, input: version.input, locate: locate)
            }.padding(.bottom, 5)
        }
    }
    @ViewBuilder private func actions(_ title: String, values: [MinutesAction], version: MinutesVersion) -> some View {
        heading(title, icon: "checklist")
        if values.isEmpty { Text(L10n.tr("未发现明确行动项。", locale: interfaceLocale)).foregroundStyle(.secondary) }
        ForEach(values) { action in
            VStack(alignment: .leading, spacing: 10) {
                Text(action.task).fontWeight(.medium).textSelection(.enabled)
                HStack(spacing: 18) {
                    Label(action.owner ?? L10n.tr("负责人未明确", locale: interfaceLocale), systemImage: "person")
                    Label(action.dueDate ?? L10n.tr("截止日期未明确", locale: interfaceLocale), systemImage: "calendar")
                }.font(.caption).foregroundStyle(.secondary)
                CitationButtons(citations: action.citations, input: version.input, locate: locate)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.teal.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct CitationButtons: View {
    @EnvironmentObject var store: AppStore
    private var interfaceLocale: Locale { store.interfaceLocale }
    let citations: [SourceCitation]
    let input: AIInputSnapshot
    let locate: (String) -> Void
    @State private var selected: SourceCitation?
    var unique: [SourceCitation] {
        var seen = Set<String>(); return citations.filter { seen.insert($0.id).inserted }
    }
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(unique) { citation in
                    Button {
                        selected = citation
                    } label: {
                        Label(TimeLabel.format(input.segments.first(where: { $0.id == citation.segmentID })?.start ?? 0),
                              systemImage: "quote.bubble").font(.caption)
                    }.buttonStyle(.bordered)
                        .accessibilityLabel(L10n.tr("查看原文 \(citation.reference)", locale: interfaceLocale))
                        .popover(isPresented: Binding(get: { selected?.id == citation.id }, set: { if !$0 { selected = nil } })) {
                            if let source = input.segments.first(where: { $0.id == citation.segmentID }) {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("\(TimeLabel.format(source.start)) · \(source.speakerName)").font(.headline)
                                    Text(L10n.tr("生成时输入版本 \(input.inputRevision)", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                                    Text("“\(citation.quote)”").textSelection(.enabled)
                                    Divider()
                                    Text(source.text).font(.callout).textSelection(.enabled)
                                    if source.text != source.originalText {
                                        Text(L10n.tr("原始识别：\(source.originalText)", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Button(L10n.tr("定位到原始转录", locale: interfaceLocale)) { selected = nil; locate(citation.segmentID) }
                                }.padding(20).frame(width: 430)
                            }
                        }
                }
            }
        }
    }
}

struct VersionMetadata: View {
    @EnvironmentObject var store: AppStore
    private var interfaceLocale: Locale { store.interfaceLocale }
    let configuration: ModelConfiguration
    let revision: Int
    let date: Date
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        Text(L10n.tr("\(configuration.displayModel) / \(L10n.text(configuration.reasoningLabel, locale: interfaceLocale)) · \(configuration.destination) / \(configuration.endpoint) · 输入 V\(revision) · \(date.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(interfaceLocale)))", locale: interfaceLocale))
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

struct MeetingAISettings: View {
    private var interfaceLocale: Locale { store.interfaceLocale }
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let meeting: Meeting
    @State private var correction = ModelConfiguration()
    @State private var summary = ModelConfiguration()
    @State private var language = "中文"
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("本会议的 AI 设置", locale: interfaceLocale)).font(.title2).fontWeight(.semibold)
            Form {
                Section(L10n.tr("校对", locale: interfaceLocale)) { ModelSettingsRow(title: L10n.tr("校对", locale: interfaceLocale), configuration: $correction, profile: meeting.settings.profile) }
                Section(L10n.tr("纪要", locale: interfaceLocale)) {
                    ModelSettingsRow(title: L10n.tr("总结", locale: interfaceLocale), configuration: $summary, profile: meeting.settings.profile)
                    Picker(L10n.tr("输出语言", locale: interfaceLocale), selection: $language) {
                        ForEach(SummaryLanguage.allCases, id: \.self) {
                            Text(L10n.text($0.rawValue, locale: interfaceLocale)).tag($0.rawValue)
                        }
                    }
                }
                Text(L10n.tr("转录文字、人物信息、术语和必要备注会发送至以上所选模型服务。Bedrock 使用本会议的 \(meeting.settings.profile) profile。", locale: interfaceLocale))
                    .font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            HStack {
                Button(L10n.tr("采用当前全局默认值", locale: interfaceLocale)) {
                    correction = store.settings.correction; summary = store.settings.summary; language = store.settings.summaryLanguage
                }
                Spacer()
                Button(L10n.tr("取消", locale: interfaceLocale)) { dismiss() }
                Button(L10n.tr("保存", locale: interfaceLocale)) {
                    store.mutate(meeting.id) { current in
                        current.settings.correction = correction; current.settings.summary = summary
                        current.settings.summaryLanguage = language
                    }; dismiss()
                }.buttonStyle(.borderedProminent)
                    .disabled((try? AIModelCatalog.resolve(correction)) == nil || (try? AIModelCatalog.resolve(summary)) == nil)
            }
        }.padding(24).frame(width: 740, height: 760)
            .onAppear { correction = meeting.settings.correction; summary = meeting.settings.summary; language = meeting.settings.summaryLanguage }
    }
}
