import Foundation
import MeetingCore

public enum DoubaoCredentialCheck {
    /// Performs only an authenticated upgrade against the ASR 2.0 hourly resource; no audio/configuration frames.
    public static func check(apiKey: String) async throws {
        try await check(apiKey: apiKey, socket: URLSessionDoubaoSocket())
    }
    public static func checkRecording(apiKey: String) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 4096, !key.contains(where: \.isWhitespace),
              key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw SpeechConfigurationError.invalidKey
        }
        try await DoubaoRecordingClient(apiKey: key).checkAccess()
    }
    static func check(apiKey: String, socket: any DoubaoSocket) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 4096, !key.contains(where: \.isWhitespace),
              key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw SpeechConfigurationError.invalidKey
        }
        do {
            try Task.checkCancellation()
            try await socket.open(apiKey: key, sessionID: UUID().uuidString)
            try Task.checkCancellation()
            await socket.close()
        } catch {
            await socket.close()
            throw error
        }
    }
}
