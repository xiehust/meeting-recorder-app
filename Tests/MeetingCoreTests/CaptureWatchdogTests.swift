import Foundation
import Testing
@testable import MeetingCore

@Test func silentTeamsIntroCanRecoverAfterOldEightSecondCutoff() {
    let start = Date(timeIntervalSince1970: 1_000)
    var watchdog = CaptureWatchdog(startedAt: start)
    #expect(watchdog.poll(source: .application, now: start.addingTimeInterval(5)) == .none)
    #expect(watchdog.poll(source: .application, now: start.addingTimeInterval(10)) == .waitForApplicationAudio)
    #expect(watchdog.poll(source: .application, now: start.addingTimeInterval(20)) == .none)
    watchdog.frameArrived(at: start.addingTimeInterval(25))
    #expect(!watchdog.awaitingFrames)
    #expect(watchdog.lastFrameAt == start.addingTimeInterval(25))
    #expect(watchdog.poll(source: .application, now: start.addingTimeInterval(30)) == .none)
    #expect(watchdog.poll(source: .application, now: start.addingTimeInterval(40)) == .waitForApplicationAudio)
}

@Test func microphoneStillStopsWhenDeviceNoLongerDeliversFrames() {
    let start = Date(timeIntervalSince1970: 1_000)
    var watchdog = CaptureWatchdog(startedAt: start)
    watchdog.frameArrived(at: start.addingTimeInterval(5))
    #expect(watchdog.poll(source: .microphone, now: start.addingTimeInterval(10)) == .none)
    #expect(watchdog.poll(source: .microphone, now: start.addingTimeInterval(15)) == .stopUnavailableMicrophone)
}
