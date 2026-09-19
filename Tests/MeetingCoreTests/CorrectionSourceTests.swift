import Foundation
import Testing
import MeetingCore

@Test func summarySourceSelectsLatestMatchingCompleteCorrectionAndUsesStableVersionNumbers() throws {
    var meeting = Meeting(title: "Source", applicationName: "Test", bundleID: "test", microphoneName: "Mic", settings: .init())
    try meeting.ingest(.init(sessionID: "s", resultID: "r", source: .application, start: 0, end: 2, text: "原始文本", speakerID: "one"))
    let revision = meeting.revision
    func version(_ input: AIInputSnapshot, complete: Bool) -> CorrectionVersion {
        var result = CorrectionVersion(input: input, configuration: .init(), profile: "default", chunkCount: 1)
        if complete { result.completedChunks = [0] }
        return result
    }
    let first = version(.init(meeting: meeting), complete: true)
    meeting.revision += 1
    let stale = version(.init(meeting: meeting), complete: true)
    meeting.revision = revision
    let latest = version(.init(meeting: meeting), complete: true)
    let partial = version(.init(meeting: meeting), complete: false)
    meeting.correctionVersions = [first, stale, latest, partial]
    #expect(meeting.reusableCorrectionVersion?.id == latest.id)
    #expect(meeting.correctionVersionNumber(for: latest.id) == 3)
    #expect(meeting.correctionVersionNumber(for: first.id) == 1)
    #expect(meeting.correctionVersionNumber(for: UUID()) == nil)

    let historical = MinutesVersion(input: first.input, correctionVersionID: first.id, configuration: .init(), profile: "default",
        minutes: .init(overview: "历史纪要", topics: [], decisions: [], actions: [], questions: [], limitations: []), invocation: nil)
    #expect(meeting.correctionVersionNumber(for: try #require(historical.correctionVersionID)) == 1)
    meeting.revision += 2
    #expect(meeting.reusableCorrectionVersion == nil)
    #expect(meeting.correctionVersionNumber(for: first.id) == 1)
}

@Test func sharedConnectionRetainsEachStagesModelAndReasoningAndLeavesSnapshotsUntouched() throws {
    let defaults = ModelConfiguration()
    #expect(ModelConnection(defaults).applying(to: defaults) == defaults)
    var correction = ModelConfiguration()
    correction.provider = .responsesProxy; correction.proxyURL = "https://proxy.example.com/openai/v1"
    correction.customModelID = "model-correction"; correction.reasoningEffort = "low"
    var summary = correction
    summary.customModelID = "model-summary"; summary.reasoningEffort = "high"
    let historical = summary
    var shared = ModelConnection(correction)
    shared.proxyURL = "https://proxy.example.com/new/v1"
    let first = shared.applying(to: correction), second = shared.applying(to: summary)
    #expect(first.proxyURL == second.proxyURL)
    #expect(first.customModelID == "model-correction")
    #expect(second.customModelID == "model-summary")
    #expect(first.reasoningEffort == "low")
    #expect(second.reasoningEffort == "high")
    #expect(historical.proxyURL == "https://proxy.example.com/openai/v1")
    #expect(try ResponsesEndpoint.url(first.proxyURL!).absoluteString == "https://proxy.example.com/new/v1/responses")
}
