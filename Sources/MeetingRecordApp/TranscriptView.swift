import SwiftUI
import MeetingCore

struct TranscriptView: View {
    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    let original: Bool
    var focusedSegmentID: String? = nil
    @State private var editing: TranscriptSegment?
    private var displayedSegments: [TranscriptSegment] {
        if original { return meeting.sortedSegments }
        if let focusedSegmentID, let version = meeting.batchVersions?.first(where: { $0.segments.contains { $0.id == focusedSegmentID } }) {
            return version.segments
        }
        if let focusedSegmentID, meeting.segments.contains(where: { $0.id == focusedSegmentID }) { return meeting.sortedSegments }
        return meeting.workingSegments
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                Text(original ? "实时转录原文" : "当前输入：\(meeting.transcriptSourceDescription) · 引用定位时显示对应来源版本")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                if displayedSegments.isEmpty {
                    ContentUnavailableView(meeting.status.isActive ? "等待发言" : "暂无确定转录", systemImage: "waveform",
                        description: Text(meeting.status.isActive ? "连接成功后，确定的转录会持续保存。\n请同时留意会议声音与麦克风的状态。" : "可以查看音频区间与异常说明。"))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayedSegments) { segment in
                            segmentRow(segment).id(segment.id)
                                .background(segment.id == focusedSegmentID ? Color.teal.opacity(0.08) : .clear)
                            Divider().padding(.leading, 56)
                        }
                        if meeting.status.isActive && !original {
                            ForEach(store.partials.keys.sorted(), id: \.self) { key in
                                HStack(alignment: .top) {
                                    ProgressView().controlSize(.small)
                                    Text(store.partials[key] ?? "").foregroundStyle(.secondary)
                                    Text("临时").font(.caption2).foregroundStyle(.tertiary)
                                }.padding(.vertical, 12)
                            }
                        }
                        if !meeting.intervals.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                Label("暂停与待核对区间", systemImage: "clock.badge.exclamationmark").font(.callout).fontWeight(.medium)
                                ForEach(meeting.intervals) { interval in
                                    Text("\(TimeLabel.format(interval.start)) – \(interval.end.map(TimeLabel.format) ?? "未结束") · \(interval.reason)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10)).padding(.top, 20)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.horizontal, 28).padding(.vertical, 16)
                }
                if meeting.status.isActive {
                    HStack {
                        Text("\(meeting.segments.count) 段确定转录 · 原文始终保留").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                            Label("回到最新", systemImage: "arrow.down")
                        }.buttonStyle(.borderless)
                    }.padding(14).background(.bar)
                }
            }
            .task(id: focusedSegmentID) {
                guard let focusedSegmentID else { return }
                await Task.yield()
                withAnimation { proxy.scrollTo(focusedSegmentID, anchor: .center) }
            }
        }
        .sheet(item: $editing) { segment in SegmentEditor(meetingID: meeting.id, segment: segment).environmentObject(store) }
    }

    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(String(meeting.speakerName(for: segment).prefix(1)))
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(segment.source == .microphone ? .teal : .indigo)
                .frame(width: 36, height: 36)
                .background(segment.source == .microphone ? Color.teal.opacity(0.1) : Color.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Text(original ? meeting.speakers.first(where: { $0.id == segment.originalSpeakerID })?.name ?? "待确认" : meeting.speakerName(for: segment))
                        .font(.callout).fontWeight(.semibold)
                    Text(TimeLabel.format(segment.start)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    if !original && meeting.text(for: segment) != segment.originalText {
                        Text("人工修订").font(.caption2).foregroundStyle(.teal)
                    }
                    if meeting.annotations[segment.id]?.highlighted == true { Image(systemName: "star.fill").foregroundStyle(.orange).font(.caption) }
                    Spacer()
                    if !original { Button { editing = segment } label: { Image(systemName: "pencil") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }
                Text(original ? segment.originalText : meeting.text(for: segment))
                    .font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                if let note = meeting.annotations[segment.id]?.note, !note.isEmpty {
                    Text("人工备注 · \(note)").font(.caption).foregroundStyle(.secondary)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }.padding(.vertical, 19)
    }
}

struct SegmentEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let meetingID: UUID
    let segment: TranscriptSegment
    @State private var text = ""
    @State private var note = ""
    @State private var speaker = ""
    @State private var highlighted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("编辑发言").font(.title2).fontWeight(.semibold)
            Text("\(TimeLabel.format(segment.start)) · 原始转录保留不变").font(.caption).foregroundStyle(.secondary)
            GroupBox("原文") { Text(segment.originalText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
            Text("修订正文").font(.headline)
            TextEditor(text: $text).font(.body).frame(height: 100).border(.quaternary)
            Picker("归属人物", selection: $speaker) {
                ForEach(store.meetings.first(where: { $0.id == meetingID })?.speakers ?? []) { Text($0.name).tag($0.id) }
            }
            TextField("人工备注（不会作为原话）", text: $note, axis: .vertical).lineLimit(2...4)
            Toggle("标记重点", isOn: $highlighted)
            HStack {
                Button("恢复原文到编辑框") { text = segment.originalText }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存修改") {
                    store.mutate(meetingID) { meeting in
                        try? meeting.edit(segmentID: segment.id, text: text)
                        var annotation = SegmentAnnotation()
                        annotation.note = note; annotation.highlighted = highlighted; annotation.assignedSpeakerID = speaker
                        meeting.annotations[segment.id] = annotation; meeting.revision += 1
                    }
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 570)
            .onAppear {
                guard let meeting = store.meetings.first(where: { $0.id == meetingID }) else { return }
                text = meeting.text(for: segment); speaker = meeting.speakerID(for: segment)
                note = meeting.annotations[segment.id]?.note ?? ""; highlighted = meeting.annotations[segment.id]?.highlighted ?? false
            }
    }
}

struct SpeakersView: View {
    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    @State private var editing: Speaker?
    @State private var mergeFrom = ""
    @State private var mergeInto = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("姓名和备注仅用于这场会议，不会根据声音自动匹配真实身份。").font(.callout).foregroundStyle(.secondary)
                ForEach(meeting.speakers) { speaker in
                    HStack(alignment: .top) {
                        Image(systemName: "person.crop.circle").font(.title).foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(speaker.name).font(.headline)
                            if !speaker.role.isEmpty { Text(speaker.role).font(.caption).foregroundStyle(.secondary) }
                            if !speaker.note.isEmpty { Text("人物备注 · \(speaker.note)").font(.callout).foregroundStyle(.secondary) }
                            if let merge = meeting.merges.last(where: { $0.active && $0.from == speaker.id }) {
                                Text("已合并至 \(meeting.speakers.first(where: { $0.id == merge.into })?.name ?? "")").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button("编辑") { editing = speaker }
                    }.padding(18).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
                if meeting.speakers.count > 1 {
                    GroupBox("合并人物标签") {
                        HStack {
                            Picker("将", selection: $mergeFrom) {
                                Text("选择人物").tag("")
                                ForEach(meeting.speakers) { Text($0.name).tag($0.id) }
                            }
                            Picker("合并至", selection: $mergeInto) {
                                Text("选择人物").tag("")
                                ForEach(meeting.speakers) { Text($0.name).tag($0.id) }
                            }
                            Button("合并") {
                                store.mutate(meeting.id) { current in
                                    do { try current.mergeSpeaker(from: mergeFrom, into: mergeInto) }
                                    catch { store.error = error.localizedDescription }
                                }
                            }.disabled(mergeFrom.isEmpty || mergeInto.isEmpty || mergeFrom == mergeInto)
                        }.padding(10)
                    }
                    ForEach(meeting.merges.filter(\.active)) { merge in
                        Button("撤销合并：\(meeting.speakers.first(where: { $0.id == merge.from })?.name ?? "")") {
                            store.mutate(meeting.id) { current in
                                if let index = current.merges.firstIndex(where: { $0.id == merge.id }) {
                                    current.merges[index].active = false; current.revision += 1
                                }
                            }
                        }
                    }
                }
            }.padding(28)
        }.sheet(item: $editing) { speaker in SpeakerEditor(meetingID: meeting.id, speaker: speaker).environmentObject(store) }
    }
}

struct SpeakerEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let meetingID: UUID
    let speaker: Speaker
    @State private var name = ""
    @State private var role = ""
    @State private var note = ""
    var body: some View {
        Form {
            Text("人物信息").font(.title2)
            TextField("姓名", text: $name)
            TextField("角色", text: $role)
            TextField("人物备注", text: $note, axis: .vertical).lineLimit(3...5)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    store.mutate(meetingID) { meeting in
                        if let index = meeting.speakers.firstIndex(where: { $0.id == speaker.id }) {
                            meeting.speakers[index] = .init(id: speaker.id, name: name, role: role, note: note)
                            meeting.revision += 1
                        }
                    }; dismiss()
                }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 470).onAppear { name = speaker.name; role = speaker.role; note = speaker.note }
    }
}

struct MeetingNotesView: View {
    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    let onContinue: () -> Void
    @State private var glossary = ""
    @State private var note = ""
    @State private var saved = false
    @State private var isSaving = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("校对前准备").font(.headline)
                Text("先补充术语与背景，再进入校对。记录期间也可以提前填写并保存，结束后的自动校对会使用已保存内容。")
                    .font(.caption).foregroundStyle(.secondary)
                Label("会议术语", systemImage: "character.book.closed").font(.headline)
                Text("填写项目名、产品名、人名、缩写及解释。会后 AI 校对会参考这些内容纠正识别用词；不会改变 Transcribe 的实时识别，也不会把未说出的内容补进原话。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $glossary).frame(height: 145).border(.quaternary).disabled(isSaving)
                Label("人工补充", systemImage: "note.text").font(.headline).padding(.top, 8)
                Text("校对时作为背景参考，生成纪要时单独显示在“用户补充”中；原文／人工修订稿导出也会明确标注。补充内容不能作为会上原话、决策或行动项的依据。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $note).frame(height: 160).border(.quaternary).disabled(isSaving)
                HStack {
                    Button("保存术语与备注") { save(continueToCorrection: false) }
                        .buttonStyle(.bordered).disabled(isSaving)
                    if isSaving { ProgressView().controlSize(.small) }
                    if saved { Text("已保存").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("保存并前往校对") { save(continueToCorrection: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || meeting.status.isActive || store.isProcessing(meeting.id))
                }
                Text(store.isProcessing(meeting.id)
                     ? "AI 已在处理中；此时保存的新内容会用于下一次校对和纪要生成，当前请求保持原输入。"
                     : "保存成功后再进入校对页，开始处理时会使用刚保存的术语和备注。已生成版本不会自动重写；执行 AI 处理时相关内容会发送至 AWS Bedrock。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.onAppear { glossary = meeting.glossary; note = meeting.note }
            .onChange(of: meeting.id) { _, _ in glossary = meeting.glossary; note = meeting.note; saved = false }
            .onChange(of: glossary) { _, _ in saved = false }
            .onChange(of: note) { _, _ in saved = false }
    }

    private func save(continueToCorrection: Bool) {
        guard !isSaving else { return }
        isSaving = true
        let id = meeting.id
        let savedGlossary = glossary
        let savedNote = note
        Task {
            let succeeded = await store.saveMeetingNotes(id, glossary: savedGlossary, note: savedNote)
            isSaving = false
            guard store.selection == id else { return }
            saved = succeeded
            if succeeded && continueToCorrection { onContinue() }
        }
    }
}
