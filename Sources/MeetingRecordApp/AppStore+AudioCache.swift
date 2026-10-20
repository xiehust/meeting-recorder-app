import Foundation
import MeetingCore

extension AppStore {
    var protectedAudioCacheIDs: Set<UUID> {
        AudioCacheManager.protectedMeetingIDs(meetings, inUse: Set(meetings.filter { isProcessing($0.id) }.map(\.id)))
    }

    var cleanableAudioCacheBytes: Int64 { audioCacheSnapshot?.cleanableBytes(protecting: protectedAudioCacheIDs) ?? 0 }
    var cleanableAudioCacheFileCount: Int {
        let protected = protectedAudioCacheIDs
        return audioCacheSnapshot?.files.filter { !protected.contains($0.meetingID) }.count ?? 0
    }

    func hasCachedAudio(_ meeting: Meeting) -> Bool {
        audioCacheSnapshot?.containsAllAudio(for: meeting) ?? !meeting.audioChunks.isEmpty
    }

    func refreshAudioCache() async {
        guard ready, !refreshingAudioCache, !cleaningAudioCache else { return }
        refreshingAudioCache = true
        let generation = audioCacheGeneration
        defer { refreshingAudioCache = false }
        do {
            let snapshot = try await audioCacheManager.scan()
            guard generation == audioCacheGeneration else { return }
            audioCacheSnapshot = snapshot
            audioCacheError = nil
        } catch is CancellationError {
            // Closing Settings cancels its refresh task; that is not a filesystem failure.
        } catch {
            if generation == audioCacheGeneration { audioCacheError = "无法读取录音缓存统计，请检查资料目录权限。" }
        }
    }

    func maintainAudioCache(now: Date = Date()) {
        guard ready, !starting, !cleaningAudioCache, now.timeIntervalSince(lastAudioCacheCheck) >= 3_600 else { return }
        lastAudioCacheCheck = now
        if appliedAudioCacheRetention == .forever { return }
        cleanAudioCache(expiredOnly: true)
    }

    func cleanAudioCache(expiredOnly: Bool) {
        guard ready, !starting, !cleaningAudioCache else { return }
        let protected = protectedAudioCacheIDs
        let snapshot = meetings
        let retention: AudioCacheRetention? = expiredOnly ? appliedAudioCacheRetention : nil
        guard retention != .forever else { return }
        cleaningAudioCache = true
        audioCacheGeneration += 1
        audioCacheError = nil
        audioCacheCleanupTask = Task {
            defer { cleaningAudioCache = false; audioCacheCleanupTask = nil }
            do {
                let result = try await audioCacheManager.clean(meetings: snapshot, inUse: protected, retention: retention)
                audioCacheSnapshot = result.snapshot
                if result.removedFiles > 0 || !expiredOnly {
                    audioCacheLastCleanup = result
                    audioCacheLastCleanupAt = Date()
                }
                if result.failedFiles > 0 { audioCacheError = "部分录音缓存未能删除，请检查文件权限后重试。" }
            } catch {
                audioCacheError = "录音缓存清理未完成，请检查资料目录权限后重试。"
            }
        }
    }
}
