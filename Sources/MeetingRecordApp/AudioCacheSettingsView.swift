import SwiftUI
import MeetingCore

struct AudioCacheSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmCleanup = false
    private var locale: Locale { store.interfaceLocale }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var body: some View {
        Section(L10n.tr("本地录音缓存", locale: locale)) {
            Toggle(L10n.tr("默认开启本地音频缓存", locale: locale), isOn: $store.settings.cacheAudio)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    if let snapshot = store.audioCacheSnapshot {
                        Text(L10n.tr("缓存占用", locale: locale)).font(.caption).foregroundStyle(.secondary)
                        Text(size(snapshot.bytes)).font(.title2).monospacedDigit()
                        Text(L10n.tr("\(snapshot.meetingCount) 场会议 · \(snapshot.files.count) 个音频文件", locale: locale))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L10n.tr("可清理 \(size(store.cleanableAudioCacheBytes)) · 使用中 \(size(snapshot.bytes - store.cleanableAudioCacheBytes))", locale: locale))
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text(L10n.tr("正在统计录音缓存…", locale: locale)).foregroundStyle(.secondary) }
                }
                Spacer()
                if store.cleaningAudioCache || store.refreshingAudioCache { ProgressView().controlSize(.small) }
                Button(L10n.tr("刷新", locale: locale)) { Task { await store.refreshAudioCache() } }
                    .disabled(store.cleaningAudioCache || store.refreshingAudioCache)
                Button(L10n.tr("一键清理…", locale: locale), role: .destructive) { confirmCleanup = true }
                    .disabled(store.cleaningAudioCache || store.starting || store.audioCacheSnapshot == nil || store.cleanableAudioCacheFileCount == 0)
            }
            Picker(L10n.tr("自动清理期限", locale: locale), selection: Binding(
                get: { store.settings.effectiveAudioCacheRetention },
                set: { store.settings.audioCacheRetentionDays = $0.rawValue })) {
                ForEach(AudioCacheRetention.allCases, id: \.self) { retention in
                    Text(L10n.text(retention.title, locale: locale)).tag(retention)
                }
            }
            Text(L10n.tr("期限按会议结束时间计算，保存设置后生效。应用启动时和运行期间每小时检查；正在录音或处理的会议会被跳过。", locale: locale))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.tr("清理仅删除本地录音缓存，会议记录、转录和纪要会保留。清理后的录音无法再次用于复核。", locale: locale))
                .font(.caption).foregroundStyle(.secondary)
            if let result = store.audioCacheLastCleanup, let date = store.audioCacheLastCleanupAt {
                Text(L10n.tr("最近清理：\(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))) · \(result.removedFiles) 个文件 · \(size(result.removedBytes))", locale: locale))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.audioCacheError { Text(L10n.message(error, locale: locale)).font(.caption).foregroundStyle(.orange) }
            Button(L10n.tr("在 Finder 中打开资料目录", locale: locale)) { NSWorkspace.shared.open(store.directory) }
        }
        .confirmationDialog(L10n.tr("清理本地录音缓存？", locale: locale), isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button(L10n.tr("清理录音缓存", locale: locale), role: .destructive) { store.cleanAudioCache(expiredOnly: false) }
            Button(L10n.tr("取消", locale: locale), role: .cancel) {}
        } message: {
            Text(L10n.tr("将清理约 \(size(store.cleanableAudioCacheBytes)) 的本地录音。会议记录、转录和纪要会保留，但这些录音将无法恢复或重新转录。正在使用的缓存不会清理。", locale: locale))
        }
        .task {
            while !Task.isCancelled {
                await store.refreshAudioCache()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
}
