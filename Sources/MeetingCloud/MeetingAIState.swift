import Foundation
import MeetingCore

public extension Meeting {
    mutating func applyAIEvent(_ event: AIWorkflowEvent) throws {
        switch event {
        case .progress(var task):
            if [.failed, .cancelled, .interrupted].contains(task.stage) {
                task.input = aiTask?.input
                task.configuration = aiTask?.configuration
                task.profile = aiTask?.profile
                task.summaryTemplate = aiTask?.summaryTemplate
            }
            aiTask = task
            switch task.stage {
            case .correction: status = .correcting
            case .summary: status = .summarizing
            case .completed: status = (minuteVersions?.isEmpty ?? true) ? .pending : .completed
            case .failed, .cancelled, .interrupted: status = .failed
            }
            if issue?.contains("当前版本尚未接入 AI") == true { issue = nil }
        case .correction(let version):
            guard version.input.meetingID == id else { throw AIError.invalidOutput("校对结果不属于当前会议。") }
            if correctionVersions == nil { correctionVersions = [] }
            if let index = correctionVersions?.firstIndex(where: { $0.id == version.id }) {
                guard correctionVersions?[index].isComplete == false else {
                    throw AIError.invalidOutput("已完成的校对版本不能被覆盖。")
                }
                correctionVersions?[index] = version
            } else { correctionVersions?.append(version) }
        case .minutes(let version):
            guard version.input.meetingID == id, minuteVersions?.contains(where: { $0.id == version.id }) != true else {
                throw AIError.invalidOutput("纪要版本不匹配或已存在。")
            }
            if minuteVersions == nil { minuteVersions = [] }
            minuteVersions?.append(version)
            status = .completed
            aiTask = .init(stage: .completed, progress: "校对与纪要已保存")
        }
        lastSavedAt = Date()
    }
}
