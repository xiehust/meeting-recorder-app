import Foundation

public enum AudioCacheRetention: Int, CaseIterable, Sendable {
    case forever = 0, oneWeek = 7, twoWeeks = 14, thirtyDays = 30, ninetyDays = 90
    public var title: String {
        switch self {
        case .forever: "永不自动清理"
        case .oneWeek: "1 周"
        case .twoWeeks: "2 周"
        case .thirtyDays: "30 天"
        case .ninetyDays: "90 天"
        }
    }
    public func cutoff(at now: Date) -> Date? {
        self == .forever ? nil : now.addingTimeInterval(-Double(rawValue) * 86_400)
    }
}

public extension AppSettings {
    var effectiveAudioCacheRetention: AudioCacheRetention {
        AudioCacheRetention(rawValue: audioCacheRetentionDays ?? 0) ?? .forever
    }
}

public struct AudioCacheFile: Sendable {
    public let meetingID: UUID
    public let relativePath: String
    public let bytes: Int64
    public let modifiedAt: Date
}

public struct AudioCacheSnapshot: Sendable {
    public let files: [AudioCacheFile]
    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    public var meetingCount: Int { Set(files.map(\.meetingID)).count }
    public func cleanableBytes(protecting ids: Set<UUID>) -> Int64 {
        files.filter { !ids.contains($0.meetingID) }.reduce(0) { $0 + $1.bytes }
    }
    public func containsAllAudio(for meeting: Meeting) -> Bool {
        let paths = Set(files.filter { $0.meetingID == meeting.id }.map(\.relativePath))
        return !meeting.audioChunks.isEmpty && meeting.audioChunks.allSatisfy { paths.contains($0.relativePath) }
    }
}

public struct AudioCacheCleanupResult: Sendable {
    public let removedBytes: Int64
    public let removedFiles: Int
    public let failedFiles: Int
    public let snapshot: AudioCacheSnapshot
}

public enum AudioCacheError: LocalizedError {
    case unsafeDirectory
    public var errorDescription: String? { "录音缓存目录不是普通文件夹，已停止清理。" }
}

/// Serializes filesystem work off the UI actor. Only direct CAF children of Audio/<meeting UUID> are cache files.
/// The caller reserves capture/transcription operations while cleanup runs. Meeting JSON and cloud files are never changed here.
public actor AudioCacheManager {
    private let directory: URL
    private var root: URL { directory.appendingPathComponent("Audio", isDirectory: true) }
    private let manager = FileManager.default
    private let removeFile: @Sendable (URL) throws -> Void
    private let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    public init(directory: URL) {
        self.directory = directory
        removeFile = { try FileManager.default.removeItem(at: $0) }
    }
    init(directory: URL, removeFile: @escaping @Sendable (URL) throws -> Void) {
        self.directory = directory; self.removeFile = removeFile
    }

    public func scan() throws -> AudioCacheSnapshot {
        guard manager.fileExists(atPath: root.path) else { return .init(files: []) }
        try validateRoot()
        var files: [AudioCacheFile] = []
        for folder in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            let attributes = try folder.resourceValues(forKeys: keys)
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { continue }
            for file in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) {
                guard file.pathExtension.lowercased() == "caf" else { continue }
                let values = try file.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                files.append(.init(meetingID: id, relativePath: "Audio/\(folder.lastPathComponent)/\(file.lastPathComponent)",
                    bytes: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .distantFuture))
            }
        }
        return .init(files: files)
    }

    public static func protectedMeetingIDs(_ meetings: [Meeting], inUse: Set<UUID> = []) -> Set<UUID> {
        inUse.union(meetings.filter {
            $0.status.isActive || $0.status.isProcessing || $0.batchVersions?.contains(where: { $0.state == .running }) == true
        }.map(\.id))
    }

    /// nil retention means manual cleanup of all idle caches; .forever means automatic cleanup is disabled.
    public func clean(meetings: [Meeting], inUse: Set<UUID> = [], retention: AudioCacheRetention?,
                      now: Date = Date()) throws -> AudioCacheCleanupResult {
        let snapshot = try scan()
        let protected = Self.protectedMeetingIDs(meetings, inUse: inUse)
        let endedAt = Dictionary(meetings.compactMap { meeting in
            (meeting.importedRecording?.importedAt ?? meeting.endedAt).map { (meeting.id, $0) }
        }, uniquingKeysWith: max)
        let cutoff = retention?.cutoff(at: now)
        var bytes: Int64 = 0, removed = 0, failed = 0
        for file in snapshot.files {
            try Task.checkCancellation()
            guard !protected.contains(file.meetingID), retention != .forever else { continue }
            if let cutoff, (endedAt[file.meetingID] ?? file.modifiedAt) > cutoff { continue }
            do {
                try validateRoot()
                let url = directory.appendingPathComponent(file.relativePath)
                let parent = try url.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard parent.isDirectory == true, parent.isSymbolicLink != true else { throw AudioCacheError.unsafeDirectory }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AudioCacheError.unsafeDirectory }
                try removeFile(url)
                bytes += file.bytes; removed += 1
            } catch { failed += 1 }
        }
        return .init(removedBytes: bytes, removedFiles: removed, failedFiles: failed, snapshot: try scan())
    }

    private func validateRoot() throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AudioCacheError.unsafeDirectory }
    }
}
