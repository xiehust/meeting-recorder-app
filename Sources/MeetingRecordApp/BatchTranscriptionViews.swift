import SwiftUI
import MeetingCore

struct BatchTranscriptionView: View {
    private var interfaceLocale: Locale { store.interfaceLocale }
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
        let interfaceLocale = self.interfaceLocale
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.tr("会后用录音重新转录", locale: interfaceLocale)).font(.title3).fontWeight(.semibold)
                        Text(L10n.tr("当前校对与纪要使用：\(L10n.message(meeting.transcriptSourceDescription, locale: interfaceLocale))", locale: interfaceLocale))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.tr("新建批量转录…", locale: interfaceLocale)) { showStart = true }
                        .buttonStyle(.borderedProminent).disabled(busy || meeting.audioChunks.isEmpty)
                }
                Text(L10n.tr("批量结果按时间与实时原文对照。复核后点击“采用本版”；原文、人工修改和旧纪要始终保留。两版的分段、人物编号可能不同，人工修改与人物映射不会自动迁移。", locale: interfaceLocale))
                    .font(.callout).foregroundStyle(.secondary)
                if meeting.audioChunks.isEmpty {
                    Label(L10n.tr("这场会议没有保留录音，无法重新转录。下次开始记录时请开启本地音频缓存。", locale: interfaceLocale), systemImage: "waveform.slash")
                        .foregroundStyle(.secondary)
                }
                if meeting.selectedBatchVersionID != nil {
                    Button(L10n.tr("恢复使用实时转录与原人工修订", locale: interfaceLocale)) {
                        Task { await store.adoptBatch(meeting.id, versionID: nil) }
                    }.disabled(busy)
                }
                if let version = selected {
                    Picker(L10n.tr("批量版本", locale: interfaceLocale), selection: Binding(get: { selected?.id }, set: { selectedID = $0 })) {
                        ForEach(Array(versions.enumerated()), id: \.element.id) { index, item in
                            Text("V\(index + 1) · \(L10n.text(item.effectiveProvider.title, locale: interfaceLocale)) · \(item.createdAt.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(interfaceLocale)))")
                                .tag(Optional(item.id))
                        }
                    }.frame(maxWidth: 400)
                    Text(L10n.tr("\(version.settings.profile) · \(version.settings.transcribeRegion) · \(L10n.text(version.settings.language.title, locale: interfaceLocale)) · \(version.jobs.filter { $0.segments != nil }.count)/\(version.jobs.count) 段录音完成", locale: interfaceLocale))
                        .font(.caption).foregroundStyle(.secondary)
                    if version.effectiveProvider == .doubao {
                        Text(L10n.tr("豆包直传热词 \(version.settings.effectiveReviewSettings.hotwords.count) 条", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                        if let plan = version.audioPlan {
                            RecordingReviewCostView(plan: plan, pricePerHour: version.estimatedPricePerHour ?? 0.80)
                        }
                        if let cost = version.submittedCost {
                            Text(L10n.tr("已提交或等待确认部分估算：\(cost.costDescription(locale: interfaceLocale))", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(L10n.tr("词汇表：\(L10n.message(version.settings.transcriptionVocabulary?.description ?? "未使用", locale: interfaceLocale))", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if version.state == .running { ProgressView().controlSize(.small) }
                        Text(L10n.message(version.message, locale: interfaceLocale)).textSelection(.enabled)
                            .foregroundStyle(version.state == .failed ? .orange : .secondary)
                        Spacer()
                        if store.batchTasks[meeting.id] != nil {
                            Button(L10n.tr("停止等待", locale: interfaceLocale)) { store.cancelAI(meeting.id) }
                        } else if version.state != .ready {
                            Button(L10n.tr("继续任务", locale: interfaceLocale)) { store.resumeBatch(meetingID: meeting.id, version: version) }.disabled(busy)
                        }
                    }
                    if version.state == .ready, !version.segments.isEmpty {
                        HStack {
                            Button(meeting.selectedBatchVersionID == version.id ? L10n.tr("已采用本版", locale: interfaceLocale) : L10n.tr("采用本版，稍后校对", locale: interfaceLocale)) {
                                Task { await store.adoptBatch(meeting.id, versionID: version.id) }
                            }.disabled(busy || meeting.selectedBatchVersionID == version.id)
                            Button(L10n.tr("采用本版并校对、生成纪要", locale: interfaceLocale)) {
                                Task {
                                    await store.adoptBatch(meeting.id, versionID: version.id, runAI: true)
                                    continueToAI()
                                }
                            }.buttonStyle(.borderedProminent).disabled(busy)
                        }
                    }
                    if version.jobs.contains(where: { !$0.cloudCleaned }) {
                        HStack {
                            Text(version.effectiveProvider == .doubao
                                ? L10n.tr("有临时音频尚未清理。结果落盘后自动尝试删除 S3 对象；不代表删除了豆包服务端数据。", locale: interfaceLocale)
                                : L10n.tr("有云端任务或文件尚未清理。成功结果落盘后会自动尝试清理；失败或中断的任务保留供继续。", locale: interfaceLocale))
                                .font(.caption).foregroundStyle(.secondary)
                            Button(L10n.tr("清理云端文件…", locale: interfaceLocale)) { cleanVersion = version }.disabled(busy)
                        }
                    }
                    Divider()
                    HStack {
                        Text(L10n.tr("实时原文（相同音源与时间范围）", locale: interfaceLocale)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(L10n.tr("批量结果", locale: interfaceLocale)).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption).foregroundStyle(.secondary)
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(version.segments) { segment in
                            HStack(alignment: .top, spacing: 18) {
                                VStack(alignment: .leading, spacing: 6) {
                                    let matches = meeting.sortedSegments.filter {
                                        ($0.source == segment.source || $0.source == .mixed || segment.source == .mixed) && $0.end >= segment.start && $0.start <= segment.end
                                    }
                                    if matches.isEmpty { Text(L10n.tr("此范围没有实时确定结果", locale: interfaceLocale)).foregroundStyle(.secondary) }
                                    ForEach(matches) { original in
                                        Text(original.originalText).textSelection(.enabled)
                                        if meeting.text(for: original) != original.originalText {
                                            Text(L10n.tr("人工修订：\(meeting.text(for: original))", locale: interfaceLocale)).font(.caption).foregroundStyle(.teal)
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(TimeLabel.format(segment.start))–\(TimeLabel.format(segment.end)) · \(L10n.text(segment.source.title, locale: interfaceLocale))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(L10n.tr("说话人：\(segment.source == .microphone ? L10n.tr("我", locale: interfaceLocale) : String(segment.originalSpeakerID.split(separator: "/").last ?? "unknown"))", locale: interfaceLocale))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(segment.originalText).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    DisclosureGroup(L10n.tr("查看全部实时原文（含批量版可能漏掉的发言）", locale: interfaceLocale)) {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(meeting.sortedSegments) { segment in
                                Text("\(TimeLabel.format(segment.start)) · \(L10n.text(segment.source.title, locale: interfaceLocale))：\(segment.originalText)").textSelection(.enabled)
                            }
                        }.padding(.top, 10)
                    }
                } else if !meeting.audioChunks.isEmpty {
                    ContentUnavailableView(L10n.tr("录音可用于批量复核", locale: interfaceLocale), systemImage: "waveform.badge.magnifyingglass",
                        description: Text(L10n.tr("可选择 AWS Transcribe 或豆包录音文件识别 2.0。提交前会显示本次服务和音频用量。", locale: interfaceLocale)))
                }
            }.padding(28)
        }
        .sheet(isPresented: $showStart) { BatchStartView(meeting: meeting).environmentObject(store) }
        .confirmationDialog(L10n.tr("清理本版本的云端任务和文件？", locale: interfaceLocale),
            isPresented: Binding(get: { cleanVersion != nil }, set: { if !$0 { cleanVersion = nil } }), titleVisibility: .visible) {
            Button(L10n.tr("清理云端任务、录音和结果文件", locale: interfaceLocale), role: .destructive) {
                if let version = cleanVersion { store.cleanBatch(meeting.id, version: version) }; cleanVersion = nil
            }
        } message: {
            Text(cleanVersion?.effectiveProvider == .doubao
                ? L10n.tr("仅删除本版本的 S3 临时音频，本地录音和结果保留；不会取消豆包任务。未完成任务可能因音频被删除而失败。", locale: interfaceLocale)
                : L10n.tr("仅清理本版本创建的资源，本地录音和结果保留。清理未完成的任务后，再次继续可能重新提交并计费。AWS 正在运行的任务可能暂时无法删除。", locale: interfaceLocale))
        }
        .onChange(of: versions.count) { _, _ in selectedID = versions.last?.id }
    }
}

private struct BatchStartView: View {
    private var interfaceLocale: Locale { store.interfaceLocale }
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let meeting: Meeting
    @State private var bucket = ""
    @State private var vocabulary = false
    @State private var provider = RecordingReviewProvider.transcribe
    @State private var plan: RecordingAudioPlan?
    @State private var preparing = true
    @State private var error: String?
    var body: some View {
        let interfaceLocale = self.interfaceLocale
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("会后用录音重新转录", locale: interfaceLocale)).font(.title2)
            Picker(L10n.tr("本次录音复核服务", locale: interfaceLocale), selection: $provider) {
                ForEach(RecordingReviewProvider.allCases, id: \.self) { Text(L10n.text($0.title, locale: interfaceLocale)).tag($0) }
            }
            Text(L10n.tr("将使用 \(store.settings.profile) · \(store.settings.transcribeRegion)，识别语言：\(L10n.text(meeting.settings.language.title, locale: interfaceLocale))。", locale: interfaceLocale))
            TextField(L10n.tr("录音上传 S3 桶", locale: interfaceLocale), text: $bucket)
            Toggle(L10n.tr("使用当前全局词汇表", locale: interfaceLocale), isOn: $vocabulary)
            if provider == .doubao {
                Text(L10n.tr("复用设置中的豆包 API Key。两路混音为单声道，保留时间位置；只读临时链接供豆包下载，结果保存后清理 S3 音频。", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
                if let plan { RecordingReviewCostView(plan: plan, pricePerHour: store.settings.effectiveReviewSettings.pricePerHour) }
            } else {
                if vocabulary { Text(L10n.message(store.vocabularyReadiness(language: meeting.settings.language), locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary) }
                Text(L10n.tr("共 \(meeting.audioChunks.count) 段录音，将分别上传并转录，产生额外用量。结果保存到本地后自动尝试删除本次云端任务和文件；清理失败会保留可重试入口。原录音保留至删除会议。", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
            }
            if preparing { ProgressView(L10n.tr("正在读取实际录音时长…", locale: interfaceLocale)) }
            Text(L10n.tr("批量结果不会自动替换实时原文或人工修订。复核并采用后，再用于 AI 校对和纪要。", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
            if let error { Text(L10n.message(error, locale: interfaceLocale)).foregroundStyle(.orange) }
            HStack {
                Button(L10n.tr("取消", locale: interfaceLocale)) { dismiss() }
                Spacer()
                Button(L10n.tr("上传录音并开始", locale: interfaceLocale)) {
                    do {
                        try CustomVocabularyLibrary.validateBucket(bucket.trimmingCharacters(in: .whitespacesAndNewlines))
                        let configuration = try store.batchConfiguration(for: meeting, useVocabulary: vocabulary, provider: provider)
                        store.startBatch(meetingID: meeting.id, configuration: configuration, bucket: bucket)
                        if store.batchTasks[meeting.id] != nil { dismiss() }
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(preparing || plan == nil || plan?.sourceSeconds == 0)
            }
        }.padding(26).frame(width: 610)
            .task {
                bucket = store.batchBucket; vocabulary = store.vocabularyLibrary.useByDefault; provider = store.settings.effectiveReviewProvider
                do { plan = try await store.reviewAudioPlan(meeting) }
                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                preparing = false
            }
    }
}
