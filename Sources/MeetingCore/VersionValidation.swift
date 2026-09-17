import Foundation

public struct CorrectionProposal: Codable, Sendable {
    public var segmentID: String
    public var before: String
    public var after: String
    public var reason: String
    public var requiresConfirmation: Bool
    public init(segmentID: String, before: String, after: String, reason: String, requiresConfirmation: Bool) {
        self.segmentID = segmentID; self.before = before; self.after = after
        self.reason = reason; self.requiresConfirmation = requiresConfirmation
    }
}

public enum VersionValidation {
    /// Validation is intentionally conservative: model output cannot edit human-protected segments.
    public static func validate(_ proposals: [CorrectionProposal], for meeting: Meeting, inputRevision: Int) throws {
        guard inputRevision == meeting.revision else { throw MeetingError.invalidCorrection }
        var seen = Set<String>()
        for proposal in proposals {
            guard seen.insert(proposal.segmentID).inserted,
                  let segment = meeting.segments.first(where: { $0.id == proposal.segmentID }),
                  segment.originalText == proposal.before, !proposal.after.isEmpty,
                  !meeting.edits.contains(where: { $0.active && $0.segmentID == proposal.segmentID }) else {
                throw MeetingError.invalidCorrection
            }
        }
    }
    public static func validateReferences(_ ids: [String], in meeting: Meeting) throws {
        let originals = Set(meeting.segments.map(\.id))
        guard !ids.isEmpty, ids.allSatisfy(originals.contains) else { throw MeetingError.unknownSegment }
    }
}
