import SwiftUI
import MeetingCore

struct MeetingChatView: View {
    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    let showSource: (String) -> Void
    @State private var question = ""
    @State private var scope = MeetingChatScope.all
    @State private var clearing = false
    @State private var citation: MeetingChatCitation?
    private var turns: [MeetingChatTurn] { meeting.chatTurns ?? [] }
    private var busy: Bool { store.isProcessing(meeting.id) || meeting.status.isActive }
    private var canAsk: Bool { scope == .minutes ? !(meeting.minuteVersions ?? []).isEmpty : !meeting.workingSegments.isEmpty || (scope == .all && !(meeting.minuteVersions ?? []).isEmpty) }

    var body: some View {
        let locale = store.interfaceLocale
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(L10n.tr("会议问答", locale: locale), systemImage: "bubble.left.and.bubble.right").font(.headline)
                    Spacer()
                    Button(L10n.tr("清空对话", locale: locale)) { clearing = true }.disabled(busy || turns.isEmpty)
                }
                Picker(L10n.tr("问答资料范围", locale: locale), selection: $scope) {
                    ForEach(MeetingChatScope.allCases, id: \.self) { Text(L10n.text($0.title, locale: locale)).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 420).disabled(busy)
                Text(L10n.tr("使用本会议的纪要模型：\(meeting.settings.summary.displayModel)。发送时会将所选资料和最近 12 轮对话交给该模型处理。", locale: locale))
                    .font(.caption).foregroundStyle(.secondary)
                if scope != .original, meeting.hasStaleSummary {
                    Label(L10n.tr("当前纪要基于旧资料，回答会标明这一限制。", locale: locale), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(20)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if turns.isEmpty {
                            ContentUnavailableView(L10n.tr("向会议资料提问", locale: locale), systemImage: "bubble.left.and.text.bubble.right",
                                description: Text(L10n.tr("例如：有哪些已确认的决定？谁负责下一步？原文中是怎么说的？", locale: locale)))
                        }
                        ForEach(turns) { turn in turnView(turn).id(turn.id) }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }.padding(22)
                }
                .onChange(of: turns.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
                .onChange(of: turns.last?.state) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if !canAsk {
                    Text(L10n.tr("所选范围暂无资料，请先完成转录并采用结果，或生成纪要。", locale: locale)).font(.caption).foregroundStyle(.secondary)
                }
                TextField(L10n.tr("输入问题，可继续追问…", locale: locale), text: $question, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder)
                HStack {
                    Text(L10n.tr("回答仅供参考，请核对引用。", locale: locale)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if store.chatTasks[meeting.id] != nil {
                        Button(L10n.tr("停止回答", locale: locale)) { store.chatTasks[meeting.id]?.cancel() }
                    } else {
                        Button(L10n.tr("发送", locale: locale)) { send() }.buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(busy || !canAsk || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.count > 4_000)
                    }
                }
                if question.count > 4_000 { Text(L10n.tr("请输入 1–4000 字的问题。", locale: locale)).font(.caption).foregroundStyle(.orange) }
            }.padding(20)
        }
        .confirmationDialog(L10n.tr("清空这场会议的聊天记录？", locale: locale), isPresented: $clearing, titleVisibility: .visible) {
            Button(L10n.tr("清空对话", locale: locale), role: .destructive) {
                guard !busy else { return }
                store.mutate(meeting.id) { $0.chatTurns = [] }
            }
        }
        .sheet(item: $citation) { item in
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.tr("回答引用", locale: locale)).font(.title2)
                Text(L10n.tr("以下为提问时保存的资料快照。", locale: locale)).font(.caption).foregroundStyle(.secondary)
                Text("[\(item.source.id)] · \(L10n.text(item.source.kind.title, locale: locale)) · \(item.source.start.map(TimeLabel.format) ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    if item.source.kind == .minutes { ChatMarkdownView(text: item.source.text) }
                    else { Text(item.source.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                HStack {
                    if let id = item.source.segmentID {
                        Button(L10n.tr("定位转录", locale: locale)) { citation = nil; showSource(id) }
                    }
                    Spacer()
                    Button(L10n.tr("关闭", locale: locale)) { citation = nil }
                }
            }.padding(24).frame(width: 620, height: 440)
        }
    }

    private func turnView(_ turn: MeetingChatTurn) -> some View {
        let locale = store.interfaceLocale
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 45)
                ChatMarkdownView(text: turn.question).padding(14)
                    .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }
            Label(L10n.text(turn.scope.title, locale: locale), systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary)
            if let answer = turn.answer {
                ChatMarkdownView(text: answer)
                ForEach(turn.citations) { reference in
                    Button { citation = reference } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("[\(reference.source.id)] · \(L10n.text(reference.source.kind.title, locale: locale)) · \(reference.source.start.map(TimeLabel.format) ?? "")").font(.caption).fontWeight(.medium)
                            Text(reference.quote).font(.caption).lineLimit(3).multilineTextAlignment(.leading)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }.buttonStyle(.plain).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                if let invocation = turn.invocation { Text(invocation.model).font(.caption2).foregroundStyle(.tertiary) }
            }
            if turn.isStale(in: meeting) || turn.minutesWereStale {
                Text(L10n.tr("此回答使用了旧版资料，引用快照已保留。", locale: locale)).font(.caption).foregroundStyle(.orange)
            }
            if turn.state == .answering { ProgressView(L10n.tr("正在查阅会议资料…", locale: locale)) }
            if let error = turn.error {
                Text(L10n.message(error, locale: locale)).foregroundStyle(.orange).textSelection(.enabled)
                Button(L10n.tr("重试这个问题", locale: locale)) { store.sendChat(turn.question, meetingID: meeting.id, scope: turn.scope) }.disabled(busy)
            }
        }
    }

    private func send() {
        store.sendChat(question, meetingID: meeting.id, scope: scope)
        if store.chatTasks[meeting.id] != nil { question = "" }
    }
}
