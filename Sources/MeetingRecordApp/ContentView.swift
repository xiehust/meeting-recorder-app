import SwiftUI
import MeetingCore

enum DetailTab: String, CaseIterable {
    case transcript = "转录", original = "原文", people = "人物", notes = "术语与备注", correction = "校对", summary = "纪要"
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var tab: DetailTab = .transcript
    @State private var deleting: Meeting?
    @State private var focusedSegmentID: String?

    var filtered: [Meeting] {
        store.meetings.filter { meeting in
            search.isEmpty || meeting.title.localizedCaseInsensitiveContains(search)
                || meeting.segments.contains { meeting.text(for: $0).localizedCaseInsensitiveContains(search) }
                || meeting.note.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("会议记录").font(.headline)
                        Text("留住讨论，理清下一步").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
                Button { store.prepareToStart() } label: {
                    Label("开始新会议", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).tint(.teal).disabled(!store.mayStart).padding(.horizontal, 16)
                HStack {
                    Text("会议资料").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(store.meetings.count)").font(.caption).foregroundStyle(.tertiary)
                }.padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 8)
                List(selection: $store.selection) {
                    ForEach(filtered) { meeting in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            HStack(spacing: 6) {
                                Circle().fill(meeting.status == .recording ? Color.red : Color.teal.opacity(0.6)).frame(width: 5, height: 5)
                                Text(meeting.status.title)
                                Spacer()
                                Text(meeting.startedAt, format: .dateTime.month().day())
                            }.font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 7).tag(meeting.id)
                            .contextMenu {
                                Button("删除本地资料", role: .destructive) { deleting = meeting }.disabled(meeting.status.isActive || store.isProcessing(meeting.id))
                            }
                    }
                }.listStyle(.sidebar)
                Divider()
                VocabularyManagerButton().buttonStyle(.plain).font(.callout)
                    .padding(.horizontal, 18).padding(.top, 12)
                HStack {
                    Label("本地资料库", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
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
        .searchable(text: $search, placement: .sidebar, prompt: "搜索会议和转录")
        .tint(.teal)
        .sheet(item: $store.startRequest) { request in
            StartMeetingView(preferredApplication: request.application).environmentObject(store)
        }
        .sheet(isPresented: $store.showSettings) { SettingsView().environmentObject(store) }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog("删除这场会议的所有本地资料？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除本地会议、转录、备注和音频", role: .destructive) {
                if let meeting = deleting { Task { await store.delete(meeting) } }
                deleting = nil
            }
        } message: { Text("此操作删除本机资料，不表示删除云服务侧按服务条款保留的数据。") }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 28).fill(.teal.opacity(0.08)).frame(width: 108, height: 108)
                Image(systemName: "waveform.badge.mic").font(.system(size: 45, weight: .light)).foregroundStyle(.teal)
            }
            VStack(spacing: 10) {
                Text("专注讨论，记录交给这里").font(.system(size: 28, weight: .semibold))
                Text("分别记录会议声音与自己的发言。\n原话、修改和备注，各有出处。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(5)
            }
            HStack(spacing: 12) {
                Button("开始第一场会议") { store.prepareToStart() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.mayStart)
                Button("查看交互示例") { store.loadExample() }.buttonStyle(.bordered).controlSize(.large).disabled(!store.mayStart)
            }
            Label("只有点击「开始记录」后才会采集声音", systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 35) {
                feature("双路音频", icon: "waveform.path")
                feature("原文留存", icon: "doc.text")
                feature("人工修订", icon: "pencil.line")
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
                    Label(meeting.isExample ? "交互示例" : meeting.applicationName, systemImage: meeting.isExample ? "sparkles" : "video")
                        .font(.caption).foregroundStyle(.secondary)
                    if let vocabulary = meeting.settings.transcriptionVocabulary {
                        Text("词汇表快照：\(vocabulary.description)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(status: meeting.status)
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(meeting.title).font(.system(size: 26, weight: .semibold))
                        HStack(spacing: 14) {
                            Text(meeting.startedAt, format: .dateTime.year().month().day().hour().minute())
                            Label("\(meeting.speakers.count) 位发言人", systemImage: "person.2")
                            Text(meeting.settings.language.title)
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
                                capture: store.captureStates[source] ?? "等待", cloud: store.cloudStates[source] ?? "等待",
                                muted: source == .microphone && !store.microphoneEnabled)
                        }
                    }
                    HStack {
                        Button(meeting.status == .paused ? "恢复记录" : "暂停") {
                            if meeting.status == .paused { store.resume() } else { store.pause() }
                        }.disabled(meeting.status == .finalizing)
                        MicrophoneToggleButton()
                        if meeting.status == .paused {
                            Menu("切换识别语言") {
                                ForEach(RecognitionLanguage.allCases, id: \.self) { language in
                                    Button(language.title) { store.resume(language: language) }
                                }
                            }
                        }
                        Spacer()
                        Button((meeting.settings.automaticallyGenerateMinutes ?? true) ? "结束并生成纪要" : "结束记录", role: .destructive) { Task { await store.finish() } }
                            .buttonStyle(.borderedProminent).tint(.red).disabled(meeting.status == .finalizing)
                    }.controlSize(.regular)
                    Text("“静音麦克风”只控制本应用，与会议软件的静音状态独立；会议应用声音继续采集。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(28)
            HStack {
                Picker("查看内容", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 500)
                Spacer()
                if tab != .summary && tab != .correction { Menu {
                    ForEach(MeetingExport.Format.allCases, id: \.self) { format in
                        Button("\(tab == .original ? "原始转录" : "人工修订稿") · \(format.rawValue.uppercased())") {
                            store.export(meeting, original: tab == .original, format: format)
                        }
                    }
                } label: { Label("导出转录", systemImage: "square.and.arrow.up") } }
            }.padding(.horizontal, 28).padding(.bottom, 18)
            Divider()
            if let issue = meeting.issue {
                Label(issue, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.06))
            }
            Group {
                switch tab {
                case .transcript, .original: TranscriptView(meeting: meeting, original: tab == .original, focusedSegmentID: focusedSegmentID)
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
                        tab = .original
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct StatusPill: View {
    let status: MeetingStatus
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(status == .recording ? .red : .teal).frame(width: 6, height: 6)
            Text(status.title).font(.caption).fontWeight(.medium)
        }.padding(.horizontal, 10).padding(.vertical, 5).background(.quaternary, in: Capsule())
    }
}

struct AudioStatusCard: View {
    let source: AudioSource
    let level: Float
    let capture: String
    let cloud: String
    var muted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(source.title, systemImage: source == .application ? "speaker.wave.2" : (muted ? "mic.slash.fill" : "mic"))
                    .font(.callout).fontWeight(.medium)
                Spacer()
                ProgressView(value: Double(level)).frame(width: 60).tint(.teal)
            }
            Text(capture).font(.caption).lineLimit(2)
            Text(cloud).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}
