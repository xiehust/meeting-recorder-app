import SwiftUI
import MeetingCore

struct RecordingReviewSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    private var locale: Locale { store.interfaceLocale }
    var body: some View {
        Section(L10n.tr("会后录音复核", locale: locale)) {
            Picker(L10n.tr("录音复核服务", locale: locale), selection: Binding(
                get: { store.settings.effectiveReviewProvider }, set: { store.settings.recordingReviewProvider = $0 })) {
                ForEach(RecordingReviewProvider.allCases, id: \.self) { Text(L10n.text($0.title, locale: locale)).tag($0) }
            }
            Picker(L10n.tr("执行方式", locale: locale), selection: Binding(
                get: { store.settings.automaticBatchTranscription ?? false }, set: { store.settings.automaticBatchTranscription = $0 })) {
                Text(L10n.tr("可选：会后手动触发", locale: locale)).tag(false)
                Text(L10n.tr("默认：结束记录后自动执行", locale: locale)).tag(true)
            }
            TextField(L10n.tr("录音上传 S3 桶", locale: locale), text: Binding(
                get: { store.settings.batchTranscriptionBucket ?? "" }, set: { store.settings.batchTranscriptionBucket = $0 }))
            Text(L10n.tr("留空时使用全局词汇表的 S3 桶。当前：\(store.batchBucket.isEmpty ? L10n.tr("未配置", locale: locale) : store.batchBucket)", locale: locale)).font(.caption).foregroundStyle(.secondary)
            if store.settings.effectiveReviewProvider == .doubao {
                Text(L10n.tr("两路录音按时间对齐混为单声道，重叠时间只计一次。按人民币 0.80 元／音频小时估算；临时 S3 存储和流量另计。", locale: locale)).font(.caption).foregroundStyle(.secondary)
                Text(L10n.tr("使用私有 S3 临时音频及有时效的只读下载链接。结果保存后清理临时对象；录音文件识别 2.0 需单独开通。", locale: locale)).font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.tr("复核服务独立于实时转录。自动模式会保留录音；复核结果需采用后再用于校对和纪要。", locale: locale)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RecordingReviewCostView: View {
    @EnvironmentObject private var store: AppStore
    let plan: RecordingAudioPlan
    var pricePerHour: Double = 0.80
    private var locale: Locale { store.interfaceLocale }
    var body: some View {
        let usage: SpeechUsage = {
            var value = SpeechUsage(pricePerHour: pricePerHour); value.submittedSeconds = plan.mixedSeconds; return value
        }()
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr("会议声音 \(TimeLabel.format(plan.applicationSeconds)) · 麦克风 \(TimeLabel.format(plan.microphoneSeconds))", locale: locale))
            Text(L10n.tr("混音后 \(TimeLabel.format(plan.mixedSeconds)) · \(plan.slices.count) 个文件 · 预计识别费 \(usage.costDescription(locale: locale))", locale: locale)).fontWeight(.medium)
            Text(L10n.tr("按 \(pricePerHour.formatted(.currency(code: "CNY").locale(locale)))／音频小时估算，实际以平台账单为准；不含 S3 存储、流量和 AI 总结费用。", locale: locale)).foregroundStyle(.secondary)
        }.font(.caption)
    }
}

struct RecordingReviewLiveCostView: View {
    @EnvironmentObject private var store: AppStore
    let meeting: Meeting
    var body: some View {
        if meeting.status.isActive, meeting.settings.automaticBatchTranscription == true,
           meeting.settings.effectiveReviewProvider == .doubao {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let inputs = meeting.audioChunks.compactMap { chunk -> RecordingAudioInput? in
                    guard let start = chunk.audioStart else { return nil }
                    let end = chunk.end ?? meeting.offset(at: context.date)
                    return .init(chunk: chunk, frames: Int64(max(0, end - start) * 16000), sampleRate: 16000)
                }
                if let plan = try? RecordingAudioPlan(inputs: inputs) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("会后豆包复核预估（结束后按实际录音校准）", locale: store.interfaceLocale)).font(.caption)
                        RecordingReviewCostView(plan: plan, pricePerHour: meeting.settings.effectiveReviewSettings.pricePerHour)
                    }
                }
            }
        }
    }
}
