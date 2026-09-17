import SwiftUI
import MeetingCore

struct BatchTranscriptionView: View {
    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    let continueToAI: () -> Void
    @State private var showStart = false
    @State private var selectedID: UUID?
    @State private var cleanVersion: BatchTranscriptionVersion?
    private var versions: [BatchTranscriptionVersion] { meeting.batchVersions ?? [] }
    private var selected: BatchTranscriptionVersion? { versions.first { $0.id == selectedID } ?? versions.last }
    private var busy: Bool { store.isProcessing(meeting.id) || meeting.status.isActive }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("会后用录音重新转录").font(.title3).fontWeight(.semibold)
                        Text("当前校对与纪要使用：\(meeting.transcriptSourceDescription)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("新建批量转录…") { showStart = true }
                        .buttonStyle(.borderedProminent).disabled(busy || meeting.audioChunks.isEmpty)
                }
                Text("批量结果按时间与实时原文对照。复核后点击“采用本版”；原文、人工修改和旧纪要始终保留。两版的分段、人物编号可能不同，人工修改与人物映射不会自动迁移。")
                    .font(.callout).foregroundStyle(.secondary)
                if meeting.audioChunks.isEmpty {
                    Label("这场会议没有保留录音，无法重新转录。下次开始记录时请开启本地音频缓存。", systemImage: "waveform.slash")
                        .foregroundStyle(.secondary)
                }
                if meeting.selectedBatchVersionID != nil {
                    Button("恢复使用实时转录与原人工修订") {
                        Task { await store.adoptBatch(meeting.id, versionID: nil) }
                    }.disabled(busy)
                }
                if let version = selected {
                    Picker("批量版本", selection: Binding(get: { selected?.id }, set: { selectedID = $0 })) {
                        ForEach(Array(versions.enumerated()), id: \.element.id) { index, item in
                            Text("V\(index + 1) · \(item.createdAt.formatted(date: .numeric, time: .shortened))")
                                .tag(Optional(item.id))
                        }
                    }.frame(maxWidth: 400)
                    Text("\(version.settings.profile) · \(version.settings.transcribeRegion) · \(version.settings.language.title) · \(version.jobs.filter { $0.segments != nil }.count)/\(version.jobs.count) 段录音完成")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("词汇表：\(version.settings.transcriptionVocabulary?.description ?? "未使用")")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if version.state == .running { ProgressView().controlSize(.small) }
                        Text(version.message).textSelection(.enabled)
                            .foregroundStyle(version.state == .failed ? .orange : .secondary)
                        Spacer()
                        if store.batchTasks[meeting.id] != nil {
                            Button("停止等待") { store.cancelAI(meeting.id) }
                        } else if version.state != .ready {
                            Button("继续任务") { store.resumeBatch(meetingID: meeting.id, version: version) }.disabled(busy)
                        }
                    }
                    if version.state == .ready, !version.segments.isEmpty {
                        HStack {
                            Button(meeting.selectedBatchVersionID == version.id ? "已采用本版" : "采用本版，稍后校对") {
                                Task { await store.adoptBatch(meeting.id, versionID: version.id) }
                            }.disabled(busy || meeting.selectedBatchVersionID == version.id)
                            Button("采用本版并校对、生成纪要") {
                                Task {
                                    await store.adoptBatch(meeting.id, versionID: version.id, runAI: true)
                                    continueToAI()
                                }
                            }.buttonStyle(.borderedProminent).disabled(busy)
                        }
                    }
                    if version.jobs.contains(where: { !$0.cloudCleaned }) {
                        HStack {
                            Text("有云端任务或文件尚未清理。成功结果落盘后会自动尝试清理；失败或中断的任务保留供继续。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("清理云端文件…") { cleanVersion = version }.disabled(busy)
                        }
                    }
                    Divider()
                    HStack {
                        Text("实时原文（相同音源与时间范围）").frame(maxWidth: .infinity, alignment: .leading)
                        Text("批量结果").frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption).foregroundStyle(.secondary)
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(version.segments) { segment in
                            HStack(alignment: .top, spacing: 18) {
                                VStack(alignment: .leading, spacing: 6) {
                                    let matches = meeting.sortedSegments.filter {
                                        $0.source == segment.source && $0.end >= segment.start && $0.start <= segment.end
                                    }
                                    if matches.isEmpty { Text("此范围没有实时确定结果").foregroundStyle(.secondary) }
                                    ForEach(matches) { original in
                                        Text(original.originalText).textSelection(.enabled)
                                        if meeting.text(for: original) != original.originalText {
                                            Text("人工修订：\(meeting.text(for: original))").font(.caption).foregroundStyle(.teal)
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(TimeLabel.format(segment.start))–\(TimeLabel.format(segment.end)) · \(segment.source.title)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(segment.originalText).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    DisclosureGroup("查看全部实时原文（含批量版可能漏掉的发言）") {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(meeting.sortedSegments) { segment in
                                Text("\(TimeLabel.format(segment.start)) · \(segment.source.title)：\(segment.originalText)").textSelection(.enabled)
                            }
                        }.padding(.top, 10)
                    }
                } else if !meeting.audioChunks.isEmpty {
                    ContentUnavailableView("录音可用于批量复核", systemImage: "waveform.badge.magnifyingglass",
                        description: Text("提交后会上传录音到 S3，并产生额外的 Transcribe 批量转录及存储用量。"))
                }
            }.padding(28)
        }
        .sheet(isPresented: $showStart) { BatchStartView(meeting: meeting).environmentObject(store) }
        .confirmationDialog("清理本版本的云端任务和文件？",
            isPresented: Binding(get: { cleanVersion != nil }, set: { if !$0 { cleanVersion = nil } }), titleVisibility: .visible) {
            Button("清理云端任务、录音和结果文件", role: .destructive) {
                if let version = cleanVersion { store.cleanBatch(meeting.id, version: version) }; cleanVersion = nil
            }
        } message: {
            Text("仅清理本版本创建的资源，本地录音和结果保留。清理未完成的任务后，再次继续可能重新提交并计费。AWS 正在运行的任务可能暂时无法删除。")
        }
        .onChange(of: versions.count) { _, _ in selectedID = versions.last?.id }
    }
}

private struct BatchStartView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let meeting: Meeting
    @State private var bucket = ""
    @State private var vocabulary = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("会后用录音重新转录").font(.title2)
            Text("将使用 \(store.settings.profile) · \(store.settings.transcribeRegion)，识别语言：\(meeting.settings.language.title)。")
            TextField("录音上传 S3 桶", text: $bucket)
            Toggle("使用当前全局词汇表", isOn: $vocabulary)
            if vocabulary { Text(store.vocabularyReadiness(language: meeting.settings.language)).font(.caption).foregroundStyle(.secondary) }
            Text("共 \(meeting.audioChunks.count) 段录音，将分别上传并转录，产生额外用量。结果保存到本地后自动尝试删除本次云端任务和文件；清理失败会保留可重试入口。原录音保留至删除会议。")
                .font(.callout).foregroundStyle(.secondary)
            Text("批量结果不会自动替换实时原文或人工修订。复核并采用后，再用于 AI 校对和纪要。")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("上传录音并开始") {
                    do {
                        try CustomVocabularyLibrary.validateBucket(bucket.trimmingCharacters(in: .whitespacesAndNewlines))
                        let configuration = try store.batchConfiguration(for: meeting, useVocabulary: vocabulary)
                        store.startBatch(meetingID: meeting.id, configuration: configuration, bucket: bucket)
                        if store.batchTasks[meeting.id] != nil { dismiss() }
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(26).frame(width: 550)
            .onAppear { bucket = store.batchBucket; vocabulary = store.vocabularyLibrary.useByDefault }
    }
}
