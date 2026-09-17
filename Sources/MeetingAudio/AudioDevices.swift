import AppKit
import AVFoundation
import CoreAudio
import MeetingCore
import Darwin

public struct MeetingApplication: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var pid: pid_t
    public init(id: String, name: String, pid: pid_t) { self.id = id; self.name = name; self.pid = pid }

    // Match only desktop client IDs, never helper IDs or vendor-wide prefixes.
    private static let supportedNames = [
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "us.zoom.xos": "Zoom",
        "com.bytedance.macos.feishu": "飞书",
        "com.tencent.meeting": "腾讯会议",
        "5ZSL2CJU2T.com.dingtalk.mac": "钉钉"
    ]
    public static let supportedNamesDescription = "Teams、Zoom、飞书、腾讯会议、钉钉"

    static func recognized(bundleID: String?, localizedName: String?, pid: pid_t) -> MeetingApplication? {
        guard let bundleID, let fallback = supportedNames[bundleID] else { return nil }
        return .init(id: bundleID, name: localizedName ?? fallback, pid: pid)
    }
}

public struct MicrophoneDevice: Identifiable, Hashable, Sendable {
    public var id: AudioDeviceID
    public var name: String
}

public enum AudioDevices {
    @MainActor public static func meetingApplications() -> [MeetingApplication] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            MeetingApplication.recognized(bundleID: app.bundleIdentifier, localizedName: app.localizedName,
                                          pid: app.processIdentifier)
        }.sorted { $0.name < $1.name }
    }

    public static func microphones() -> [MicrophoneDevice] {
        objectIDs(kAudioHardwarePropertyDevices).compactMap { id in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
            return MicrophoneDevice(id: id, name: stringProperty(id, selector: kAudioObjectPropertyName) ?? "麦克风 \(id)")
        }
    }

    public static func defaultInputID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    public static func objectIDs(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        values(AudioObjectID(kAudioObjectSystemObject), selector)
    }

    static func values(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [UInt32] {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Enumerates process/device metadata only; this never creates a tap or opens a microphone.
    @MainActor public static func applicationScope(_ application: MeetingApplication) throws -> ApplicationAudioScope {
        guard let running = NSRunningApplication(processIdentifier: application.pid),
              running.bundleIdentifier == application.id, let bundleURL = running.bundleURL else {
            throw CaptureError.unavailable
        }
        let candidates = objectIDs(kAudioHardwarePropertyProcessObjectList).compactMap { id -> ApplicationAudioProcess? in
            guard let pid = values(id, kAudioProcessPropertyPID).first else { return nil }
            guard Int32(bitPattern: pid) > 0 else { return nil }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let count = proc_pidpath(Int32(pid), &path, UInt32(path.count))
            return .init(objectID: id, pid: Int32(pid),
                         bundleID: stringProperty(id, selector: kAudioProcessPropertyBundleID) ?? "",
                         executableURL: count > 0 ? URL(fileURLWithPath: String(cString: path)) : nil)
        }
        // Register exact nested helper bundle IDs before their audio process appears (for example, on joining a call).
        var helperIDs: [String] = []
        if let enumerator = FileManager.default.enumerator(at: bundleURL.appendingPathComponent("Contents"),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where ["app", "xpc"].contains(url.pathExtension) {
                guard ApplicationAudioScope.belongsToApplication(url, bundleURL: bundleURL),
                      let id = Bundle(url: url)?.bundleIdentifier else { continue }
                helperIDs.append(id)
            }
        }
        return .init(applicationPID: application.pid, bundleID: application.id, bundleURL: bundleURL,
                     candidates: candidates, bundledHelperIDs: helperIDs)
    }

    static func defaultOutputClock() -> OutputClockDevice? {
        guard let id = objectIDs(kAudioHardwarePropertyDefaultOutputDevice).first else { return nil }
        return .init(uid: stringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? "",
                     name: stringProperty(id, selector: kAudioObjectPropertyName) ?? "",
                     inputStreamCount: values(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count,
                     outputStreamCount: values(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).count)
    }

    public static func stringProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

public enum CaptureError: LocalizedError {
    case coreAudio(String, OSStatus), microphoneDenied, invalidFormat, unavailable, overloaded, cacheFailed
    public var errorDescription: String? {
        switch self {
        case let .coreAudio(operation, status): "\(operation)失败（Core Audio \(status)）。请检查音频权限及设备状态。"
        case .microphoneDenied: "麦克风未授权。请在系统设置 → 隐私与安全性 → 麦克风中授权。"
        case .invalidFormat: "音频格式不可用，可能是设备已切换。请暂停后重新选择来源。"
        case .unavailable: "所选应用或音频来源不可用。没有扩大到整个系统音频。"
        case .overloaded: "音频处理队列已满，出现音频缺口。请暂停并检查系统负载。"
        case .cacheFailed: "音频缓存写入失败，不能保证音频已保存。请检查磁盘空间和权限。"
        }
    }
}

func checkAudio(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CaptureError.coreAudio(operation, status) }
}
