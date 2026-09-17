import Foundation
import CoreAudio
import Darwin

public struct ApplicationAudioProcess: Equatable, Sendable {
    public let objectID: AudioObjectID
    public let pid: Int32
    public let bundleID: String
    public let executableURL: URL?
    public init(objectID: AudioObjectID, pid: Int32, bundleID: String, executableURL: URL?) {
        self.objectID = objectID; self.pid = pid; self.bundleID = bundleID; self.executableURL = executableURL
    }
}

public struct ApplicationAudioScope: Sendable {
    public let processes: [ApplicationAudioProcess]
    public let bundleIDs: [String]

    public init(applicationPID: Int32, bundleID: String, bundleURL: URL, candidates: [ApplicationAudioProcess],
                bundledHelperIDs: [String] = []) {
        processes = candidates.filter {
            $0.pid == applicationPID || Self.belongsToApplication($0.executableURL, bundleURL: bundleURL)
        }
        // Generic helper IDs shared with another product must not expand the future-process allowlist.
        bundleIDs = Array(Set(([bundleID] + bundledHelperIDs + processes.map(\.bundleID)).filter {
            $0 == bundleID || $0.hasPrefix(bundleID + ".")
        })).sorted()
    }

    /// A bundle-ID prefix alone is not evidence of ownership. Helpers must execute inside the selected app.
    static func belongsToApplication(_ executableURL: URL?, bundleURL: URL) -> Bool {
        guard let executableURL else { return false }
        guard let root = canonicalPath(bundleURL), let executable = canonicalPath(executableURL) else { return false }
        return executable.hasPrefix(root + "/")
    }

    private static func canonicalPath(_ url: URL) -> String? {
        guard let resolved = url.withUnsafeFileSystemRepresentation({ path in
            path.flatMap { realpath($0, nil) }
        }) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func tapDescription(name: String) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: processes.map(\.objectID))
        description.name = "MeetingRecord · \(name)"
        description.uuid = UUID()
        description.bundleIDs = bundleIDs
        description.isExclusive = false
        description.isPrivate = true
        description.isProcessRestoreEnabled = true
        description.muteBehavior = .unmuted
        return description
    }
}

struct OutputClockDevice: Sendable {
    let uid: String
    let name: String
    let inputStreamCount: Int
    let outputStreamCount: Int
    var safeForCaptureClock: Bool { !uid.isEmpty && inputStreamCount == 0 && outputStreamCount > 0 }
}

enum TapAggregateConfiguration {
    static func make(tapUID: String, clock: OutputClockDevice?) -> [String: Any] {
        var result: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingRecord private capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        // Output-only hardware provides a continuous clock without adding any physical microphone inputs.
        // Duplex/Bluetooth devices are deliberately NOT attached: their inputs must never leak into the remote track.
        if let clock, clock.safeForCaptureClock {
            result[kAudioAggregateDeviceMainSubDeviceKey] = clock.uid
            result[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clock.uid]]
            result[kAudioAggregateDeviceTapAutoStartKey] = false
        }
        return result
    }
}
