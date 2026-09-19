import Foundation
import AVFoundation
import MeetingCore
import MeetingAudio
import MeetingCloud

/// Explicit integration probes. Never open the user's meeting database or preferences.
enum LanguageValidation {
    static func loadVocabulary(_ path: String, into settings: inout AppSettings) throws {
        let library = try JSONDecoder().decode(CustomVocabularyLibrary.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        settings.transcriptionVocabulary = try library.snapshot(language: settings.language,
            scope: .init(profile: settings.profile, region: settings.transcribeRegion))
    }

    static func run(_ arguments: [String]) async throws -> Bool {
        if arguments == ["--check-doubao-credentials"] {
            guard let key = try DoubaoKeychain.read(), !key.isEmpty else { throw SpeechConfigurationError.missingKey }
            try await DoubaoCredentialCheck.check(apiKey: key)
            print("Doubao ASR 2.0 authenticated WebSocket upgrade: PASS; no audio sent")
            return true
        }
        if arguments.first == "--check-doubao-file", arguments.count == 2 {
            var settings = AppSettings(); settings.speechProvider = .doubao
            try await stream(file: URL(fileURLWithPath: arguments[1]), settings: settings)
            return true
        }
        if arguments.first == "--audit-doubao-speakers", arguments.count == 2 {
            guard let key = try DoubaoKeychain.read(), !key.isEmpty else { throw SpeechConfigurationError.missingKey }
            var settings = AppSettings(); settings.speechProvider = .doubao
            var failed = false
            for mode in [DoubaoResponseMode.single, .full] {
                do {
                    try await stream(file: URL(fileURLWithPath: arguments[1]), settings: settings,
                        responseMode: mode, audit: true, apiKey: key)
                } catch { failed = true; print("AUDIT \(mode.rawValue) failed: \(error.localizedDescription)") }
            }
            if failed { throw AIError.invalidOutput("One or more speaker audit cases failed; inspect the numeric diagnostics above") }
            return true
        }
        if arguments.first == "--check-stream-file", (5...6).contains(arguments.count) {
            guard let language = RecognitionLanguage(rawValue: arguments[4]) else { throw AIError.configuration("Unknown recognition language") }
            var settings = AppSettings()
            settings.profile = arguments[1]; settings.transcribeRegion = arguments[2]; settings.language = language
            if arguments.count == 6 { try loadVocabulary(arguments[5], into: &settings) }
            try await stream(file: URL(fileURLWithPath: arguments[3]), settings: settings)
            return true
        }
        if arguments.first == "--check-summary-language", arguments.count == 4 {
            guard let language = SummaryLanguage(rawValue: arguments[3]) else { throw AIError.configuration("Unknown summary language") }
            var settings = AppSettings()
            settings.profile = arguments[1]; settings.correction.region = arguments[2]; settings.summary.region = arguments[2]
            settings.summaryLanguage = language.rawValue; settings.summaryTemplate = .training
            var meeting = Meeting(title: "Synthetic multilingual training fixture", applicationName: "Fixture",
                                  bundleID: "", microphoneName: "", settings: settings)
            for (index, text) in ["今日は非同期処理について説明します。キューにタスクを入れます。",
                                   "The worker reads tasks from the queue and processes them.",
                                   "今天的练习是创建一个队列。截止日期尚未确定。"].enumerated() {
                try meeting.ingest(.init(sessionID: "fixture", resultID: "\(index)", source: .application,
                    start: Double(index * 5), end: Double(index * 5 + 4), text: text, speakerID: "fixture"))
            }
            meeting.status = .pending
            let state = LanguageSummaryState(meeting)
            try await MeetingAIWorkflow().run(meeting: meeting, operation: .full) { try await state.receive($0) }
            let result = await state.meeting
            guard let version = result.minuteVersions?.last, version.language == language.rawValue,
                  result.segments == meeting.segments, !MeetingExport.allCitations(version).isEmpty else {
                throw AIError.invalidOutput("Summary language/citation/original preservation check failed")
            }
            if language == .japanese {
                guard version.minutes.overview.range(of: #"[ぁ-ヿ]"#, options: .regularExpression) != nil,
                      MeetingExport.minutesBody(version).contains("## 研修の概要") else {
                    throw AIError.invalidOutput("Japanese summary output missing")
                }
            }
            print("Summary language \(language.rawValue): PASS; proofreading, template sections, source citations, and original preservation PASS")
            return true
        }
        if arguments.first == "--clean-vocabulary-file", arguments.count == 4 {
            let scope = VocabularyScope(profile: arguments[1], region: arguments[2])
            let library = try JSONDecoder().decode(CustomVocabularyLibrary.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
            guard library.deployments.allSatisfy({
                $0.scope == scope && $0.binding.name.hasPrefix(library.resourcePrefix) && $0.key.hasPrefix(library.objectPrefix)
            }) else { throw VocabularyError.invalid("Receipt resources do not match the requested scope and library namespace") }
            let remote = try await AWSVocabularyRemote(scope: scope)
            for deployment in library.deployments { try await remote.delete(deployment) }
            print("Vocabulary receipt cleanup PASS; vocabulary and S3 objects removed")
            return true
        }
        return false
    }

    private static func stream(file: URL, settings: AppSettings, responseMode: DoubaoResponseMode = .single,
                               audit: Bool = false, apiKey: String? = nil) async throws {
        let original = try AVAudioFile(forReading: file)
        guard Double(original.length) / original.processingFormat.sampleRate <= 60 else {
            throw AIError.configuration("Streaming probe accepts fixtures up to 60 seconds")
        }
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetingrecord-stream-fixture-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let relative = "Audio/\(id)/fixture.caf"
        let cached = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: file, to: cached)
        let chunk = AudioChunk(source: .application, relativePath: relative, start: 0)
        guard let wav = try BatchAudioPreparer.prepare(chunk, meetingID: id, directory: root, output: root.appendingPathComponent("fixture.wav")) else {
            throw AIError.configuration("Empty audio fixture")
        }
        let input = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatInt16, interleaved: true)
        let frameCount: AVAudioFrameCount = audit ? 3200 : 1600
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: frameCount) else {
            throw AIError.configuration("Unable to prepare PCM buffer")
        }
        let state = LanguageStreamState()
        let stream: any StreamingTranscribing
        if settings.effectiveSpeechProvider == .doubao {
            let storedKey: String?
            if let apiKey { storedKey = apiKey } else { storedKey = try DoubaoKeychain.read() }
            guard let key = storedKey, !key.isEmpty else { throw SpeechConfigurationError.missingKey }
            let observer: (@Sendable ([DoubaoSpeakerObservation]) async -> Void)?
            if audit { observer = { values in await state.recordSpeakers(values) } }
            else { observer = nil }
            stream = DoubaoTranscriptionStream(apiKey: key, diagnostics: { await state.recordSchema($0) },
                responseMode: responseMode, speakerObserver: observer)
        } else { stream = TranscriptionStream() }
        defer { stream.cancel() }
        stream.start(settings: settings, source: .application, offset: 0) { await state.receive($0) }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: frameCount)
            guard let channel = buffer.int16ChannelData?.pointee, buffer.frameLength > 0 else { break }
            stream.send(Data(bytes: channel, count: Int(buffer.frameLength) * 2))
            try await Task.sleep(for: .seconds(Double(buffer.frameLength) / 16000))
        }
        stream.finish()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await stream.waitUntilFinished() }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                stream.cancel()
                throw AIError.configuration("Streaming fixture timed out")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        if audit { await state.reportSpeakerAudit(mode: responseMode, expectedSeconds: Double(input.length) / 16000) }
        try await state.validate(language: settings.language)
        if settings.effectiveSpeechProvider == .doubao {
            try await state.validateAudioSubmission(expectedSeconds: Double(input.length) / 16000)
            let speakers = try await state.validateDoubaoSpeakers()
            print("Doubao speaker labels observed: \(speakers)")
        }
        print("\(settings.effectiveSpeechProvider.rawValue) streaming \(settings.language.rawValue): PASS; final transcript received; speaker labels enabled")
    }
}

private actor LanguageStreamState {
    var segments: [TranscriptSegment] = []
    var errors: [String] = []
    private var schema: String?
    private var speakerObservations: [DoubaoSpeakerObservation] = []
    private var submittedSeconds = 0.0
    func recordSchema(_ value: String) { schema = value }
    func recordSpeakers(_ values: [DoubaoSpeakerObservation]) {
        speakerObservations += values.prefix(max(0, 10000 - speakerObservations.count))
    }
    func reportSpeakerAudit(mode: DoubaoResponseMode, expectedSeconds: Double) {
        let rawLabels = Set(speakerObservations.compactMap(\.speakerID).compactMap(Int.init)).sorted()
        let finalLabels = Set(speakerObservations.filter(\.definite).compactMap(\.speakerID).compactMap(Int.init)).sorted()
        let missing = speakerObservations.filter { $0.speakerID == nil }.count
        var latest: [String: String] = [:]
        var revisions = 0
        for value in speakerObservations where value.definite {
            guard let end = value.end, value.start.isFinite, end.isFinite,
                  value.start >= 0, end <= 60000, let label = value.speakerID else { continue }
            let key = "\(value.start):\(end)"
            if let previous = latest[key], previous != label { revisions += 1 }
            latest[key] = label
        }
        print("AUDIT mode=\(mode.rawValue); audio=pcm/16000/16/mono; packet=200ms")
        print("raw_numeric_speaker_ids=\(rawLabels); definite_numeric_speaker_ids=\(finalLabels); missing_label_observations=\(missing)")
        print("definite_speaker_revisions=\(revisions); saved_utterances=\(segments.count); observations=\(speakerObservations.count)")
        print("submitted_audio_seconds=\(submittedSeconds); file_audio_seconds=\(expectedSeconds)")
        if let schema { print("schema: \(schema)") }
    }
    func receive(_ event: TranscriptionUpdate) {
        switch event {
        case let .final(_, values): segments += values
        case let .failed(message): errors.append(message)
        case let .usage(seconds): submittedSeconds += seconds
        default: break
        }
    }
    func validate(language: RecognitionLanguage) throws {
        guard errors.isEmpty, !segments.isEmpty else {
            throw AIError.invalidOutput(errors.first ?? "No final streaming transcript")
        }
        if language == .japanese || language == .multilingual || language == .englishJapanese {
            guard segments.contains(where: { $0.originalText.range(of: #"[ぁ-ヿ]"#, options: .regularExpression) != nil }) else {
                throw AIError.invalidOutput("Fixture produced no Japanese text")
            }
        }
    }
    func validateDoubaoSpeakers() throws -> Int {
        let speakers = Set(segments.map(\.originalSpeakerID).filter { !$0.hasSuffix(":unknown") })
        guard !speakers.isEmpty else {
            throw AIError.invalidOutput("No Doubao speaker information received. Schema: \(schema ?? "unavailable")")
        }
        return speakers.count
    }
    func validateAudioSubmission(expectedSeconds: Double) throws {
        guard abs(submittedSeconds - expectedSeconds) < 0.01 else {
            throw AIError.invalidOutput("The stream ended before all fixture audio was submitted")
        }
    }
}

private actor LanguageSummaryState {
    var meeting: Meeting
    init(_ meeting: Meeting) { self.meeting = meeting }
    func receive(_ event: AIWorkflowEvent) throws { try meeting.applyAIEvent(event) }
}
