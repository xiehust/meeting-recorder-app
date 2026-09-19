import Foundation
import Testing
@testable import MeetingCore

private func reviewInput(_ source: AudioSource, start: Double, duration: Double) -> RecordingAudioInput {
    .init(chunk: .init(source: source, relativePath: "fixture.caf", start: start), frames: Int64(duration * 16000), sampleRate: 16000)
}

@Test func mixedReviewChargesOverlappingTracksOnceAndDoesNotChargePauses() throws {
    let plan = try RecordingAudioPlan(inputs: [reviewInput(.application, start: 10, duration: 3600),
        reviewInput(.microphone, start: 10, duration: 3600), reviewInput(.application, start: 5000, duration: 60)])
    #expect(plan.sourceSeconds == 7260)
    #expect(plan.mixedSeconds == 3660)
    #expect(plan.slices.map(\.start) == [10, 5000])
    var usage = SpeechUsage(pricePerHour: 0.8); usage.submittedSeconds = plan.mixedSeconds
    #expect(abs(usage.estimatedCNY - 0.8133333333) < 0.000001)
}

@Test func reviewSlicesKeepOffsetsAndFreezeProviderRateAndTaskIDs() throws {
    let input = reviewInput(.application, start: 25, duration: 50)
    let plan = try RecordingAudioPlan(inputs: [input], maximumSliceSeconds: 20)
    #expect(plan.slices.map(\.start) == [25, 45, 65])
    #expect(plan.slices.map(\.duration) == [20, 20, 10])
    var settings = AppSettings(); settings.recordingReviewProvider = .doubao
    var meeting = Meeting(title: "test", applicationName: "", bundleID: "", microphoneName: "", settings: settings)
    meeting.status = .pending; meeting.audioChunks = [input.chunk]
    let version = try BatchTranscriptionVersion(meeting: meeting, settings: settings, bucket: "test-bucket", audioPlan: plan)
    let restored = try JSONDecoder().decode(BatchTranscriptionVersion.self, from: JSONEncoder().encode(version))
    #expect(restored.effectiveProvider == .doubao)
    #expect(restored.jobs.map(\.requestID) == version.jobs.map(\.requestID))
    #expect(restored.jobs.allSatisfy { $0.chunk.source == .mixed && $0.mixedAudio != nil })
    #expect(restored.estimatedPricePerHour == 0.8)
    meeting.settings.recordingReviewProvider = .transcribe
    #expect(restored.effectiveProvider == .doubao)
}

@Test func historicalReviewVersionsDecodeAsAWSAndInvalidPlansFail() throws {
    var meeting = Meeting(title: "old", applicationName: "", bundleID: "", microphoneName: "", settings: .init())
    meeting.status = .pending; meeting.audioChunks = [reviewInput(.application, start: 0, duration: 1).chunk]
    let version = try BatchTranscriptionVersion(meeting: meeting, settings: .init(), bucket: "test-bucket")
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(version)) as? [String: Any])
    json.removeValue(forKey: "provider"); json.removeValue(forKey: "audioPlan"); json.removeValue(forKey: "estimatedPricePerHour")
    let old = try JSONDecoder().decode(BatchTranscriptionVersion.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.effectiveProvider == .transcribe)
    #expect(old.estimatedCost == nil)
    #expect(throws: BatchTranscriptionError.self) { try RecordingAudioPlan(inputs: [reviewInput(.application, start: -1, duration: 1)]) }
    #expect(throws: BatchTranscriptionError.self) { try RecordingAudioPlan(inputs: [], maximumSliceSeconds: 0) }
}
