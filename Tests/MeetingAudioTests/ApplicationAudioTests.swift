import Foundation
import CoreAudio
import AVFoundation
import Testing
@testable import MeetingAudio

private final class ApplicationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var teamsURL: URL { root.appendingPathComponent("Microsoft Teams.app") }
    init() throws { try FileManager.default.createDirectory(at: teamsURL, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func executable(_ path: String) throws -> String {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        return url.path
    }
}

private func process(_ id: UInt32, bundle: String, path: String?, pid: Int32 = 200) -> ApplicationAudioProcess {
    .init(objectID: id, pid: pid, bundleID: bundle, executableURL: path.map { URL(fileURLWithPath: $0) })
}

@Test func teamsWithoutMainAudioProcessStillIncludesModuleHostAndWebView() throws {
    let fixture = try ApplicationFixture()
    let teamsURL = fixture.teamsURL
    let candidates = [
        process(127, bundle: "com.microsoft.teams2.modulehost",
                path: try fixture.executable("Microsoft Teams.app/Contents/Helpers/ModuleHost.app/Contents/MacOS/ModuleHost")),
        process(128, bundle: "com.microsoft.teams2.helper",
                path: try fixture.executable("Microsoft Teams.app/Contents/Helpers/WebView.app/Contents/MacOS/WebView")),
        process(129, bundle: "com.microsoft.teams2.helper",
                path: try fixture.executable("Microsoft Teams.app/Contents/Helpers/WebView.app/Contents/Frameworks/Helper"))
    ]
    let scope = ApplicationAudioScope(applicationPID: 100, bundleID: "com.microsoft.teams2",
                                      bundleURL: teamsURL, candidates: candidates)
    #expect(scope.processes.map(\.objectID) == [127, 128, 129])
    #expect(scope.bundleIDs == ["com.microsoft.teams2", "com.microsoft.teams2.helper", "com.microsoft.teams2.modulehost"])
    let tap = scope.tapDescription(name: "Teams")
    #expect(tap.processes == [127, 128, 129])
    #expect(!tap.isExclusive)
    #expect(tap.isMixdown && !tap.isMono && tap.isPrivate)
    #expect(tap.muteBehavior == .unmuted)
}

@Test func bundlePrefixDoesNotIncludeUnrelatedApplicationsOrSiblingPaths() throws {
    let fixture = try ApplicationFixture()
    let teamsURL = fixture.teamsURL
    let candidates = [
        process(1, bundle: "com.microsoft.teams2.helper", path: try fixture.executable("Other.app/Contents/MacOS/helper")),
        process(2, bundle: "com.microsoft.teams2.helper", path: try fixture.executable("Microsoft Teams.app-copy/Contents/helper")),
        process(3, bundle: "com.microsoft.teams2.modulehost", path: nil),
        process(4, bundle: "com.apple.Safari", path: try fixture.executable("Safari.app/Contents/MacOS/Safari"))
    ]
    let scope = ApplicationAudioScope(applicationPID: 100, bundleID: "com.microsoft.teams2", bundleURL: teamsURL, candidates: candidates)
    #expect(scope.processes.isEmpty)
    #expect(scope.bundleIDs == ["com.microsoft.teams2"])
    #expect(!scope.tapDescription(name: "Teams").isExclusive)
}

@Test func symlinkOutsideSelectedAppIsNotCaptured() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let application = temporary.appendingPathComponent("Teams.app")
    let outside = temporary.appendingPathComponent("Other.app")
    try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data().write(to: outside.appendingPathComponent("process"))
    try FileManager.default.createSymbolicLink(at: application.appendingPathComponent("helper"), withDestinationURL: outside)
    #expect(!ApplicationAudioScope.belongsToApplication(application.appendingPathComponent("helper/process"), bundleURL: application))
    #expect(!ApplicationAudioScope.belongsToApplication(application.appendingPathComponent("missing/process"), bundleURL: application))
}

@Test func helpersStartingAfterCaptureAreRegisteredWithoutGenericSharedIDs() throws {
    let fixture = try ApplicationFixture()
    let teamsURL = fixture.teamsURL
    let scope = ApplicationAudioScope(applicationPID: 100, bundleID: "com.microsoft.teams2", bundleURL: teamsURL,
        candidates: [], bundledHelperIDs: ["com.microsoft.teams2.modulehost", "com.microsoft.teams2.helper", "com.microsoft.edgemac.helper"])
    #expect(scope.bundleIDs.contains("com.microsoft.teams2.modulehost"))
    #expect(scope.bundleIDs.contains("com.microsoft.teams2.helper"))
    #expect(!scope.bundleIDs.contains("com.microsoft.edgemac.helper"))
}

@Test func additionalMeetingClientAudioHelpersStayInsideTheSelectedInstallation() throws {
    let fixture = try ApplicationFixture()
    // Paths and IDs follow the desktop clients installed locally; framework version directories may change.
    let clients = [
        ("com.bytedance.macos.feishu", "Lark.app",
         "Contents/Frameworks/Lark Framework.framework/Versions/143/Helpers/Lark Helper (Iron).app/Contents/MacOS/Lark Helper (Iron)",
         "com.bytedance.macos.feishu.iron"),
        ("com.tencent.meeting", "TencentMeeting.app",
         "Contents/Frameworks/WeMeetFramework.framework/Versions/3.45/Frameworks/wmexternal.app/Contents/MacOS/wmexternal",
         "com.tencent.meeting.services.wmexternal"),
        ("5ZSL2CJU2T.com.dingtalk.mac", "DingTalk.app",
         "Contents/Frameworks/Tblive.app/Contents/MacOS/Tblive",
         "5ZSL2CJU2T.com.dingtalk.mac.tblive")
    ]
    for (bundleID, directory, helperPath, helperID) in clients {
        let candidates = [
            process(1, bundle: helperID, path: try fixture.executable("\(directory)/\(helperPath)")),
            process(2, bundle: "", path: try fixture.executable("\(directory)/Contents/MacOS/audio-worker")),
            process(3, bundle: helperID, path: try fixture.executable("Other.app/Contents/MacOS/helper")),
            process(4, bundle: helperID, path: try fixture.executable("\(directory)-copy/Contents/MacOS/helper")),
            process(5, bundle: helperID, path: nil)
        ]
        let scope = ApplicationAudioScope(applicationPID: 100, bundleID: bundleID,
            bundleURL: fixture.root.appendingPathComponent(directory), candidates: candidates)
        #expect(scope.processes.map(\.objectID) == [1, 2])
        #expect(scope.bundleIDs == [bundleID, helperID].sorted())
        let tap = scope.tapDescription(name: directory)
        #expect(tap.processes == [1, 2])
        #expect(!tap.isExclusive && tap.isPrivate && tap.isProcessRestoreEnabled)
        #expect(tap.muteBehavior == .unmuted)
    }
}

@Test func newClientsRegisterLateMeetingHelpersWithoutAllowingSharedVendorHelpers() throws {
    let fixture = try ApplicationFixture()
    for (bundleID, allowed, excluded) in [
        ("com.bytedance.macos.feishu",
         ["com.bytedance.macos.feishu.helper", "com.bytedance.macos.feishu.iron", "com.bytedance.macos.feishu.helper.renderer"],
         ["com.bytedance.macos.feishu-notifier", "com.bytedance.macos.other.helper"]),
        ("com.tencent.meeting",
         ["com.tencent.meeting.services.wmexternal", "com.tencent.meeting.TranscodeBridge"],
         ["com.tencent.wemeet.FileDelta", "com.tencent.xinWeChat"]),
        ("5ZSL2CJU2T.com.dingtalk.mac",
         ["5ZSL2CJU2T.com.dingtalk.mac.tblive"],
         ["com.alibaba.shared.helper", "5ZSL2CJU2T.com.dingtalk.mac-copy"])
    ] {
        let scope = ApplicationAudioScope(applicationPID: 100, bundleID: bundleID,
            bundleURL: fixture.root, candidates: [], bundledHelperIDs: allowed + excluded)
        #expect(scope.processes.isEmpty)
        #expect(scope.bundleIDs == ([bundleID] + allowed).sorted())
    }
}

@Test func outputOnlyHeadphonesProvideClockAndDoNotWaitForFirstSpeech() {
    let clock = OutputClockDevice(uid: "BuiltInHeadphoneOutputDevice", name: "External Headphones",
                                  inputStreamCount: 0, outputStreamCount: 1)
    let specification = TapAggregateConfiguration.make(tapUID: "actual-hal-tap-uid", clock: clock)
    #expect(specification[kAudioAggregateDeviceMainSubDeviceKey] as? String == clock.uid)
    #expect(specification[kAudioAggregateDeviceTapAutoStartKey] as? Bool == false)
    let subdevices = specification[kAudioAggregateDeviceSubDeviceListKey] as? [[String: String]]
    #expect(subdevices == [[kAudioSubDeviceUIDKey: clock.uid]])
    let taps = specification[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
    #expect(taps?.first?[kAudioSubTapUIDKey] as? String == "actual-hal-tap-uid")
}

@Test func duplexBluetoothDeviceNeverAddsItsMicrophoneToRemoteTrack() {
    let bluetooth = OutputClockDevice(uid: "bluetooth-duplex", name: "Bluetooth Headset", inputStreamCount: 1, outputStreamCount: 1)
    let specification = TapAggregateConfiguration.make(tapUID: "tap", clock: bluetooth)
    #expect(specification[kAudioAggregateDeviceSubDeviceListKey] == nil)
    #expect(specification[kAudioAggregateDeviceMainSubDeviceKey] == nil)
    #expect(specification[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true)
    #expect(specification[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
}

private final class PCMResults: @unchecked Sendable {
    let lock = NSLock()
    var data = Data()
    var levels: [Float] = []
    var errors = 0
    func append(_ bytes: Data) { lock.withLock { data.append(bytes) } }
    func level(_ value: Float) { lock.withLock { levels.append(value) } }
    func fail() { lock.withLock { errors += 1 } }
}

@Test func stereoTapBufferProducesMonoPCMWithoutLosingFrameLength() throws {
    let results = PCMResults()
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
    buffer.frameLength = 4_800
    for channel in 0..<2 {
        for frame in 0..<4_800 { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * .pi / 24)) * 0.25 }
    }
    let wrapped = try #require(AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: buffer.audioBufferList, deallocator: nil))
    #expect(wrapped.frameLength == 4_800)
    let processor = try PCMProcessor(format: format, cacheURL: nil, onData: { results.append($0) },
                                    onLevel: { results.level($0) }, onFailure: { _ in results.fail() })
    processor.consume(wrapped)
    processor.stop()
    #expect(results.errors == 0)
    #expect(results.data.count == 3_200)
    #expect(results.data.contains { $0 != 0 })
    #expect(results.levels.contains { $0 > 0 })
    let savedCount = results.data.count
    processor.consume(wrapped)
    #expect(results.data.count == savedCount)
}

@Test func stoppingBeforeAnyAudioDoesNotInventPCM() throws {
    let results = PCMResults()
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
    let processor = try PCMProcessor(format: format, cacheURL: nil, onData: { results.append($0) },
                                    onLevel: { results.level($0) }, onFailure: { _ in results.fail() })
    processor.stop()
    #expect(results.data.isEmpty)
}
