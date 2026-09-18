import SwiftUI
import MeetingCore

enum DetailTab: String, CaseIterable {
    case transcript = "转录", original = "原文", batch = "录音复核", people = "人物", notes = "术语与备注", correction = "校对", summary = "纪要"
}

struct ContentView: View {
    private var interfaceLocale: Locale { store.interfaceLocale }
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var tab: DetailTab = .transcript
    @State private var deleting: Meeting?
    @State private var focusedSegmentID: String?

    var filtered: [Meeting] {
        store.meetings.filter { meeting in
            search.isEmpty || meeting.title.localizedCaseInsensitiveContains(search)
                || meeting.workingSegments.contains { meeting.text(for: $0).localizedCaseInsensitiveContains(search) }
                || meeting.note.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("会议记录", locale: interfaceLocale)).font(.headline)
                        Text(L10n.tr("留住讨论，理清下一步", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
                Button { store.prepareToStart() } label: {
                    Label(L10n.tr("开始新会议", locale: interfaceLocale), systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).tint(.teal).disabled(!store.mayStart).padding(.horizontal, 16)
                HStack {
                    Text(L10n.tr("会议资料", locale: interfaceLocale)).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(store.meetings.count)").font(.caption).foregroundStyle(.tertiary)
                }.padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 8)
                List(selection: $store.selection) {
                    ForEach(filtered) { meeting in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            HStack(spacing: 6) {
                                Circle().fill(meeting.status == .recording ? Color.red : Color.teal.opacity(0.6)).frame(width: 5, height: 5)
                                Text(L10n.text(meeting.status.title, locale: interfaceLocale))
                                Spacer()
                                Text(meeting.startedAt, format: .dateTime.month().day())
                            }.font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 7).tag(meeting.id)
                            .contextMenu {
                                Button(L10n.tr("删除本地资料", locale: interfaceLocale), role: .destructive) { deleting = meeting }.disabled(meeting.status.isActive || store.isProcessing(meeting.id))
                            }
                    }
                }.listStyle(.sidebar)
                Divider()
                VocabularyManagerButton().buttonStyle(.plain).font(.callout)
                    .padding(.horizontal, 18).padding(.top, 12)
                HStack {
                    Label(L10n.tr("本地资料库", locale: interfaceLocale), systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.showSettings = true } label: { Image(systemName: "gearshape") }.buttonStyle(.plain)
                }.padding(18)
            }
            .navigationSplitViewColumnWidth(min: 235, ideal: 260, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if !store.meetingReminders.applications.isEmpty, store.active == nil, store.startRequest == nil {
                    MeetingApplicationRemindersView(applications: store.meetingReminders.applications,
                        mayStart: store.mayStart, prepare: { store.prepareToStart(application: $0) },
                        dismiss: { store.dismissMeetingReminders() })
                }
                if let meeting = store.selected {
                    detail(meeting)
                } else { welcome }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .searchable(text: $search, placement: .sidebar, prompt: L10n.tr("搜索会议和转录", locale: interfaceLocale))
        .tint(.teal)
        .sheet(item: $store.startRequest) { request in
            StartMeetingView(preferredApplication: request.application).environmentObject(store)
        }
        .sheet(isPresented: $store.showSettings) { SettingsView().environmentObject(store) }
        .alert(L10n.tr("操作未完成", locale: interfaceLocale), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L10n.tr("知道了", locale: interfaceLocale)) { store.error = nil }
        } message: { Text(L10n.message(store.error ?? "", locale: interfaceLocale)) }
        .confirmationDialog(L10n.tr("删除这场会议的所有本地资料？", locale: interfaceLocale), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L10n.tr("删除本地会议、转录、备注和音频", locale: interfaceLocale), role: .destructive) {
                if let meeting = deleting { Task { await store.delete(meeting) } }
                deleting = nil
            }
        } message: {
            Text(deleting?.batchVersions?.contains(where: { $0.jobs.contains { !$0.cloudCleaned } }) == true
                ? L10n.tr("这场会议仍有未确认清理的批量任务或云端文件。建议先到“录音复核”清理；删除本地资料也会移除这些任务的本地索引，不会删除云端文件。", locale: interfaceLocale)
                : L10n.tr("此操作删除本机资料，不表示删除云服务侧按服务条款保留的数据。", locale: interfaceLocale))
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 28).fill(.teal.opacity(0.08)).frame(width: 108, height: 108)
                Image(systemName: "waveform.badge.mic").font(.system(size: 45, weight: .light)).foregroundStyle(.teal)
            }
            VStack(spacing: 10) {
                Text(L10n.tr("专注讨论，记录交给这里", locale: interfaceLocale)).font(.system(size: 28, weight: .semibold))
                Text(L10n.tr("分别记录会议声音与自己的发言。\n原话、修改和备注，各有出处。", locale: interfaceLocale))
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(5)
            }
            HStack(spacing: 12) {
                Button(L10n.tr("开始第一场会议", locale: interfaceLocale)) { store.prepareToStart() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.mayStart)
                Button(L10n.tr("查看交互示例", locale: interfaceLocale)) { store.loadExample() }.buttonStyle(.bordered).controlSize(.large).disabled(!store.mayStart)
            }
            Label(L10n.tr("只有点击「开始记录」后才会采集声音", locale: interfaceLocale), systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 35) {
                feature(L10n.tr("双路音频", locale: interfaceLocale), icon: "waveform.path")
                feature(L10n.tr("原文留存", locale: interfaceLocale), icon: "doc.text")
                feature(L10n.tr("人工修订", locale: interfaceLocale), icon: "pencil.line")
            }.padding(.bottom, 45)
        }.frame(maxWidth: .infinity)
    }
    private func feature(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.callout).foregroundStyle(.secondary)
    }

    private func detail(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(meeting.isExample ? L10n.tr("交互示例", locale: interfaceLocale) : meeting.applicationName, systemImage: meeting.isExample ? "sparkles" : "video")
                        .font(.caption).foregroundStyle(.secondary)
                    if let vocabulary = meeting.settings.transcriptionVocabulary {
                        Text(L10n.tr("词汇表快照：\(L10n.message(vocabulary.description, locale: interfaceLocale))", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(status: meeting.status)
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(meeting.title).font(.system(size: 26, weight: .semibold))
                        HStack(spacing: 14) {
                            Text(meeting.startedAt, format: .dateTime.year().month().day().hour().minute())
                            Label(L10n.tr("\(meeting.speakers.count) 位发言人", locale: interfaceLocale), systemImage: "person.2")
                            Text(L10n.text(meeting.settings.language.title, locale: interfaceLocale))
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if meeting.status.isActive {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(TimeLabel.format(meeting.offset(at: meeting.endedAt ?? context.date)))
                                .font(.system(.title2, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                if meeting.status.isActive {
                    HStack(spacing: 12) {
                        ForEach(AudioSource.allCases, id: \.self) { source in
                            AudioStatusCard(source: source, level: store.levels[source] ?? 0,
                                capture: store.captureStates[source] ?? L10n.tr("等待", locale: interfaceLocale), cloud: store.cloudStates[source] ?? L10n.tr("等待", locale: interfaceLocale),
                                muted: source == .microphone && !store.microphoneEnabled)
                        }
                    }
                    HStack {
                        Button(meeting.status == .paused ? L10n.tr("恢复记录", locale: interfaceLocale) : L10n.tr("暂停", locale: interfaceLocale)) {
                            if meeting.status == .paused { store.resume() } else { store.pause() }
                        }.disabled(meeting.status == .finalizing)
                        MicrophoneToggleButton()
                        if meeting.status == .paused {
                            Menu(L10n.tr("切换识别语言", locale: interfaceLocale)) {
                                ForEach(RecognitionLanguage.allCases, id: \.self) { language in
                                    Button(L10n.text(language.title, locale: interfaceLocale)) { store.resume(language: language) }
                                }
                            }
                        }
                        Spacer()
                        Button(meeting.settings.automaticBatchTranscription == true ? L10n.tr("结束并重新转录", locale: interfaceLocale)
                            : ((meeting.settings.automaticallyGenerateMinutes ?? true) ? L10n.tr("结束并生成纪要", locale: interfaceLocale) : L10n.tr("结束记录", locale: interfaceLocale)), role: .destructive) { Task { await store.finish() } }
                            .buttonStyle(.borderedProminent).tint(.red).disabled(meeting.status == .finalizing)
                    }.controlSize(.regular)
                    Text(L10n.tr("“静音麦克风”只控制本应用，与会议软件的静音状态独立；会议应用声音继续采集。", locale: interfaceLocale))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(28)
            HStack {
                ViewThatFits(in: .horizontal) {
                    detailPicker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                    detailPicker.pickerStyle(.menu)
                }
                Spacer()
                if tab != .summary && tab != .correction && tab != .batch { Menu {
                    ForEach(MeetingExport.Format.allCases, id: \.self) { format in
                        Button("\(tab == .original ? L10n.tr("原始转录", locale: interfaceLocale) : L10n.tr("人工修订稿", locale: interfaceLocale)) · \(format.rawValue.uppercased())") {
                            store.export(meeting, original: tab == .original, format: format)
                        }
                    }
                } label: { Label(L10n.tr("导出转录", locale: interfaceLocale), systemImage: "square.and.arrow.up") } }
            }.padding(.horizontal, 28).padding(.bottom, 18)
            Divider()
            if meeting.batchVersions?.last?.state == .ready, meeting.batchVersions?.last?.id != meeting.selectedBatchVersionID {
                HStack {
                    Label(meeting.batchVersions?.last?.segments.isEmpty == true
                        ? L10n.tr("录音重新转录已完成，未识别到发言。可查看详情。", locale: interfaceLocale)
                        : L10n.tr("新的批量转录已就绪，复核并采用后可用于校对和纪要。", locale: interfaceLocale), systemImage: "checkmark.circle")
                    Spacer()
                    Button(L10n.tr("复核录音转录", locale: interfaceLocale)) { tab = .batch }
                }.font(.caption).padding(14).background(.teal.opacity(0.06))
            } else if meeting.status == .retranscribing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.message(meeting.batchVersions?.last?.message ?? "正在重新转录录音…", locale: interfaceLocale))
                    Spacer()
                    Button(L10n.tr("查看进度", locale: interfaceLocale)) { tab = .batch }
                }.font(.caption).padding(14)
            } else if let batch = meeting.batchVersions?.last, [.failed, .cancelled, .interrupted].contains(batch.state) {
                HStack {
                    Label(L10n.tr("录音重新转录未完成，已保存的结果保留。", locale: interfaceLocale), systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button(L10n.tr("查看并重试", locale: interfaceLocale)) { tab = .batch }
                }.font(.caption).padding(14).background(.orange.opacity(0.06))
            }
            if let issue = meeting.issue {
                Label(L10n.message(issue, locale: interfaceLocale), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.06))
            }
            Group {
                switch tab {
                case .transcript, .original: TranscriptView(meeting: meeting, original: tab == .original, focusedSegmentID: focusedSegmentID)
                case .batch: BatchTranscriptionView(meeting: meeting) { tab = .correction }.id(meeting.id)
                case .correction:
                    CorrectionView(meeting: meeting) { id in
                        focusedSegmentID = id
                        tab = .transcript
                    }
                case .people: SpeakersView(meeting: meeting)
                case .notes:
                    MeetingNotesView(meeting: meeting) { tab = .correction }
                case .summary:
                    MinutesView(meeting: meeting) { id in
                        focusedSegmentID = id
                        tab = .transcript
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var detailPicker: some View {
        Picker(L10n.tr("查看内容", locale: interfaceLocale), selection: $tab) {
            ForEach(DetailTab.allCases, id: \.self) { Text(L10n.text($0.rawValue, locale: interfaceLocale)).tag($0) }
        }
    }
}

struct StatusPill: View {
    @EnvironmentObject var store: AppStore
    private var interfaceLocale: Locale { store.interfaceLocale }
    let status: MeetingStatus
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        HStack(spacing: 5) {
            Circle().fill(status == .recording ? .red : .teal).frame(width: 6, height: 6)
            Text(L10n.text(status.title, locale: interfaceLocale)).font(.caption).fontWeight(.medium)
        }.padding(.horizontal, 10).padding(.vertical, 5).background(.quaternary, in: Capsule())
    }
}

struct AudioStatusCard: View {
    @EnvironmentObject var store: AppStore
    private var interfaceLocale: Locale { store.interfaceLocale }
    let source: AudioSource
    let level: Float
    let capture: String
    let cloud: String
    var muted = false
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.text(source.title, locale: interfaceLocale), systemImage: source == .application ? "speaker.wave.2" : (muted ? "mic.slash.fill" : "mic"))
                    .font(.callout).fontWeight(.medium)
                Spacer()
                ProgressView(value: Double(level)).frame(width: 60).tint(.teal)
            }
            Text(L10n.message(capture, locale: interfaceLocale)).font(.caption).lineLimit(2)
            Text(L10n.message(cloud, locale: interfaceLocale)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}
