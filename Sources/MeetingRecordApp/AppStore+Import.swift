import Foundation
import MeetingCore
import MeetingAudio

extension AppStore {
    func importRecording(source: URL, title: String, startedAt: Date, configuration: AppSettings,
                         transcribe: Bool, bucket: String) {
        guard mayStart else { return }
        recordingImportError = nil
        let directory = directory
        importTask = Task {
            defer { importTask = nil; objectWillChange.send() }
            var prepared: Meeting?
            do {
                let worker = Task.detached {
                    let accessed = source.startAccessingSecurityScopedResource()
                    defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                    return try RecordingImporter.prepare(source: source, title: title, startedAt: startedAt,
                        settings: configuration, directory: directory)
                }
                let meeting = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                prepared = meeting
                try Task.checkCancellation()
                try await enqueueSave(meeting).value
                // From this point the recording belongs to the persisted meeting, even if quitting.
                prepared = nil
                meetings.insert(meeting, at: 0); selection = meeting.id
                importedMeetingID = meeting.id
                showRecordingImport = false
                await refreshAudioCache()
                if transcribe && !Task.isCancelled { startBatch(meetingID: meeting.id, configuration: configuration, bucket: bucket) }
            } catch {
                if let prepared {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("Audio/\(prepared.id.uuidString)"))
                }
                if !Task.isCancelled { recordingImportError = error.localizedDescription }
            }
        }
        objectWillChange.send()
    }
}
