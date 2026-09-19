import Foundation
import AVFoundation
import MeetingCore
import MeetingAudio
import MeetingCloud

enum RecordingReviewValidation {
    static func run(_ arguments: [String]) async throws -> Bool {
        if arguments == ["--check-doubao-recording-credentials"] {
            guard let key = try DoubaoKeychain.read(), !key.isEmpty else { throw SpeechConfigurationError.missingKey }
            try await DoubaoCredentialCheck.checkRecording(apiKey: key)
            print("Doubao recording query access: PASS; no audio submitted")
            return true
        }
        guard (arguments.first == "--check-doubao-recording" && arguments.count == 5)
                || (arguments.first == "--check-doubao-recording-config" && arguments.count == 2) else { return false }
        var settings = AppSettings(); settings.recordingReviewProvider = .doubao
        let bucket: String, path: String
        if arguments.count == 5 {
            settings.profile = arguments[1]; settings.transcribeRegion = arguments[2]; bucket = arguments[3]; path = arguments[4]
        } else {
            let defaults = UserDefaults(suiteName: "local.meetingrecord.app")!
            let stored = try defaults.data(forKey: "settings").map { try JSONDecoder().decode(AppSettings.self, from: $0) } ?? .init()
            let vocabulary = try defaults.data(forKey: "customVocabularyLibrary").map { try JSONDecoder().decode(CustomVocabularyLibrary.self, from: $0) }
            settings.profile = stored.profile; settings.transcribeRegion = stored.transcribeRegion
            let configured = stored.batchTranscriptionBucket?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            bucket = configured.isEmpty ? (vocabulary?.bucket ?? "") : configured
            path = arguments[1]
        }
        try CustomVocabularyLibrary.validateBucket(bucket)
        guard let key = try DoubaoKeychain.read(), !key.isEmpty else { throw SpeechConfigurationError.missingKey }
        let source = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: source)
        guard file.length > 0, Double(file.length) / file.processingFormat.sampleRate <= 60 else {
            throw BatchTranscriptionError.invalid("Recording probe accepts nonempty fixtures up to 60 seconds")
        }
        var meeting = Meeting(title: "Synthetic recording review validation", applicationName: "Fixture", bundleID: "", microphoneName: "", settings: settings)
        meeting.status = .pending
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-review-probe-\(meeting.id)")
        let relative = "Audio/\(meeting.id)/fixture.wav"
        let target = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: source, to: target)
        meeting.audioChunks = [.init(source: .application, relativePath: relative, start: 5)]
        let plan = try RecordingReviewAudio.plan(meeting: meeting, directory: root)
        let version = try BatchTranscriptionVersion(meeting: meeting, settings: settings, bucket: bucket, audioPlan: plan)
        let receipt = root.appendingPathComponent("receipt.json")
        let state = RecordingProbeState(receipt: receipt)
        try await state.save(version)
        print("Recording probe receipt: \(receipt.path)")
        let remote = DoubaoBatchTranscriptionRemote(api: DoubaoRecordingClient(apiKey: key),
            storage: try await S3ReviewAudioStorage(scope: .init(profile: settings.profile, region: settings.transcribeRegion)))
        let meetingID = meeting.id
        try await BatchTranscriptionService(remote: remote, pollLimit: 60, pollDelay: .seconds(3)).run(version: version, prepare: { chunk in
            guard let slice = version.jobs.first(where: { $0.chunk.id == chunk.id })?.mixedAudio else { return nil }
            return try RecordingReviewAudio.prepare(slice, meetingID: meetingID, directory: root, output: root.appendingPathComponent("mixed.wav"))
        }) { try await state.save($0) }
        guard let result = await state.latest, result.state == .ready, !result.segments.isEmpty,
              result.jobs.allSatisfy(\.cloudCleaned) else {
            throw BatchTranscriptionError.invalid("Recording probe did not complete transcript and S3 cleanup; inspect receipt")
        }
        print("Doubao recording review: PASS; segments=\(result.segments.count); mixedSeconds=\(plan.mixedSeconds); S3 cleanup=PASS")
        try FileManager.default.removeItem(at: root)
        return true
    }
}

private actor RecordingProbeState {
    let receipt: URL
    var latest: BatchTranscriptionVersion?
    init(receipt: URL) { self.receipt = receipt }
    func save(_ version: BatchTranscriptionVersion) throws {
        try JSONEncoder().encode(version).write(to: receipt, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        latest = version
    }
}
