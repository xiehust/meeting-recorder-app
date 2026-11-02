import Foundation
import MeetingCore
import MeetingCloud

extension AppStore {
    func sendChat(_ question: String, meetingID: UUID, scope: MeetingChatScope) {
        guard !isProcessing(meetingID), let index = meetings.firstIndex(where: { $0.id == meetingID }),
              !meetings[index].status.isActive, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let meeting = meetings[index]
        let context = MeetingChatContext(meeting: meeting, scope: scope)
        let turn = MeetingChatTurn(question: question.trimmingCharacters(in: .whitespacesAndNewlines), context: context)
        if meetings[index].chatTurns == nil { meetings[index].chatTurns = [] }
        meetings[index].chatTurns?.append(turn)
        meetings[index].lastSavedAt = Date()
        let pendingSave = enqueueSave(meetings[index])
        chatTasks[meetingID] = Task {
            defer { chatTasks.removeValue(forKey: meetingID); objectWillChange.send() }
            do {
                try await pendingSave.value
                try Task.checkCancellation()
                let answer = try await MeetingChatService().answer(question: turn.question, context: context,
                    history: meeting.chatTurns ?? [], configuration: meeting.settings.summary,
                    profile: meeting.settings.profile, language: meeting.settings.summaryLanguage)
                try Task.checkCancellation()
                try await updateChat(meetingID, turnID: turn.id) {
                    $0.answer = answer.text; $0.citations = answer.citations
                    $0.invocation = answer.invocation; $0.state = .completed
                }
            } catch {
                try? await updateChat(meetingID, turnID: turn.id) {
                    $0.state = Task.isCancelled ? .cancelled : .failed
                    $0.error = Task.isCancelled ? "问答已中断，可重试。" : Self.aiMessage(error)
                }
            }
        }
        objectWillChange.send()
    }

    private func updateChat(_ meetingID: UUID, turnID: UUID, change: (inout MeetingChatTurn) -> Void) async throws {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }),
              let position = meetings[index].chatTurns?.firstIndex(where: { $0.id == turnID }) else { throw CancellationError() }
        change(&meetings[index].chatTurns![position])
        meetings[index].lastSavedAt = Date()
        try await enqueueSave(meetings[index]).value
    }
}
