import Foundation

public struct ImportedRecording: Codable, Sendable {
    public let fileName: String
    public let duration: TimeInterval
    public let importedAt: Date
    public init(fileName: String, duration: TimeInterval, importedAt: Date = Date()) {
        self.fileName = fileName; self.duration = duration; self.importedAt = importedAt
    }
}

public extension Meeting {
    /// Live meetings retain their immutable live ledger. Imported meetings expose the adopted
    /// file transcript, or the first completed version while it is awaiting review.
    var originalSegments: [TranscriptSegment] {
        guard importedRecording != nil else { return sortedSegments }
        return selectedBatchVersion?.segments
            ?? batchVersions?.first(where: { $0.state == .ready && $0.isComplete })?.segments ?? []
    }
}
