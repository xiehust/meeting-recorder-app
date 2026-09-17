import Foundation
import AppKit
import MeetingCore
import MeetingCloud

@main
struct MeetingAIValidate {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data(("AI validation failed: \(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }
    @MainActor private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--probe-models"] {
            for model in ModelChoice.allCases {
                var configuration = ModelConfiguration(); configuration.model = model
                let response = try await BedrockResponsesClient().generate(
                    instructions: "Return exactly one JSON object: {\"ok\":true}.",
                    input: "Connectivity test with no meeting data.", configuration: configuration,
                    profile: "default", maxOutputTokens: 2_048)
                guard let data = response.text.data(using: .utf8),
                      let value = try JSONSerialization.jsonObject(with: data) as? [String: Bool],
                      value["ok"] == true else { throw AIError.invalidOutput("模型连通性测试返回内容不符合要求。") }
                print("\(model.rawValue): PASS; medium; \(response.invocation.durationSeconds)s")
            }
            return
        }
        let explicitID = arguments.count >= 2 && arguments.first == "--meeting" ? UUID(uuidString: arguments[1]) : nil
        guard arguments == ["--latest"] || arguments == ["--latest", "--summary-only"]
                || (explicitID != nil && (arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--summary-only"))) else {
            print("Usage: MeetingAIValidate --probe-models | --latest [--summary-only] | --meeting UUID [--summary-only]")
            print("--latest sends the latest ended real meeting to its configured AWS Bedrock models and saves versions. Close MeetingRecord first.")
            return
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.meetingrecord.app").isEmpty else {
            throw AIError.configuration("请先退出会议记录应用，避免两个进程同时修改同一会议。")
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingRecord")
        let repository = try MeetingRepository(directory: directory)
        let meetings = try await repository.loadAll()
        let candidates = meetings.filter { !$0.isExample && $0.endedAt != nil && (explicitID == nil || $0.id == explicitID) }
        guard !meetings.contains(where: { $0.status.isActive }),
              let meeting = candidates.max(by: { $0.startedAt < $1.startedAt }) else {
            throw AIError.noTranscript
        }
        let operation: AIWorkflowOperation = arguments.contains("--summary-only") ? .summary : .full
        let state = ValidationState(meeting: meeting, repository: repository)
        do {
            try await MeetingAIWorkflow().run(meeting: meeting, operation: operation) { event in try await state.receive(event) }
        } catch {
            try await state.receive(.progress(.init(stage: .failed, progress: "验证未完成", error: error.localizedDescription)))
            throw error
        }
        let result = try await repository.loadAll().first { $0.id == meeting.id }
        guard result?.segments == meeting.segments else { throw AIError.invalidOutput("原文保留检查未通过。") }
        await state.report()
    }
}

private actor ValidationState {
    var meeting: Meeting
    let repository: MeetingRepository
    init(meeting: Meeting, repository: MeetingRepository) { self.meeting = meeting; self.repository = repository }
    func receive(_ event: AIWorkflowEvent) async throws {
        try meeting.applyAIEvent(event)
        try await repository.save(meeting)
        if case .progress(let task) = event { print(task.progress) }
    }
    func report() {
        let correction = meeting.correctionVersions?.last
        let minutes = meeting.minuteVersions?.last
        print("Meeting: \(meeting.id); original segments unchanged: \(meeting.segments.count)")
        print("Correction changes: \(correction?.changes.count ?? 0); complete: \(correction?.isComplete ?? false)")
        print("Minutes: \(minutes?.minutes.topics.count ?? 0) topics, \(minutes?.minutes.decisions.count ?? 0) decisions, \(minutes?.minutes.actions.count ?? 0) actions")
        print("Validated citations: \(minutes.map(MeetingExport.allCitations)?.count ?? 0)")
    }
}
