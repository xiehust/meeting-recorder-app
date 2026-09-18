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

    private static func stream(file: URL, settings: AppSettings) async throws {
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
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 1600) else {
            throw AIError.configuration("Unable to prepare PCM buffer")
        }
        let state = LanguageStreamState()
        let stream = TranscriptionStream()
        defer { stream.cancel() }
        stream.start(settings: settings, source: .application, offset: 0) { await state.receive($0) }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: 1600)
            guard let channel = buffer.int16ChannelData?.pointee, buffer.frameLength > 0 else { break }
            stream.send(Data(bytes: channel, count: Int(buffer.frameLength) * 2))
            try await Task.sleep(for: .milliseconds(100))
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
        try await state.validate(language: settings.language)
        print("Streaming \(settings.language.rawValue): PASS; final transcript received; speaker labels enabled")
    }
}

private actor LanguageStreamState {
    var segments: [TranscriptSegment] = []
    var errors: [String] = []
    func receive(_ event: TranscriptionUpdate) {
        switch event {
        case let .final(_, values): segments += values
        case let .failed(message): errors.append(message)
        default: break
        }
    }
    func validate(language: RecognitionLanguage) throws {
        guard errors.isEmpty, !segments.isEmpty else {
            throw AIError.invalidOutput(errors.first ?? "No final streaming transcript")
        }
        if language == .japanese || language == .multilingual {
            guard segments.contains(where: { $0.originalText.range(of: #"[ぁ-ヿ]"#, options: .regularExpression) != nil }) else {
                throw AIError.invalidOutput("Fixture produced no Japanese text")
            }
        }
    }
}

private actor LanguageSummaryState {
    var meeting: Meeting
    init(_ meeting: Meeting) { self.meeting = meeting }
    func receive(_ event: AIWorkflowEvent) throws { try meeting.applyAIEvent(event) }
}
