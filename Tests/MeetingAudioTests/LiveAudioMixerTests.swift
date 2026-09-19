import Foundation
import Testing
import MeetingCore
@testable import MeetingAudio

private func pcm(_ value: Int16, count: Int = 3200) -> Data {
    let word = UInt16(bitPattern: value)
    return Data(Array(repeating: [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8)], count: count).flatMap { $0 })
}
private func sample(_ data: Data, _ index: Int) -> Int16 {
    Int16(bitPattern: UInt16(data[2 * index]) | UInt16(data[2 * index + 1]) << 8)
}

@Test func mixerCombinesSimultaneousSourcesWithoutDoublingDurationOrClipping() throws {
    var mixer = TimestampedAudioMixer()
    try mixer.append(.init(data: pcm(30000), start: 10), source: .application)
    try mixer.append(.init(data: pcm(30000), start: 10), source: .microphone)
    let frames = mixer.render(until: 10.2, flush: true)
    let data = frames.reduce(Data()) { $0 + $1.data }
    #expect(abs(Double(data.count) / 32000 - 0.2) < 0.0001)
    #expect(sample(data, 500) == 30000)
    #expect(frames.first?.start == 10)
}

@Test func mixerAlignsTimestampsKeepsGapsAndFlushesTheLastPartialFrame() throws {
    var mixer = TimestampedAudioMixer()
    try mixer.append(.init(data: pcm(10000, count: 1600), start: 20), source: .application)
    try mixer.append(.init(data: pcm(20000, count: 1600), start: 20.2), source: .microphone)
    let frames = mixer.render(until: 20.3, flush: true)
    let data = frames.reduce(Data()) { $0 + $1.data }
    #expect(sample(data, 100) == 5000)
    #expect(sample(data, 2000) == 0)
    #expect(sample(data, 3500) == 10000)
    #expect(abs(Double(data.count) / 32000 - 0.3) < 0.0001)
}

@Test func mixerRingDoesNotReplayOldMicrophoneSamplesAfterMute() throws {
    var mixer = TimestampedAudioMixer()
    try mixer.append(.init(data: pcm(10000), start: 100), source: .microphone)
    for step in 0..<40 {
        let time = 100 + Double(step) * 0.2
        try mixer.append(.init(data: pcm(0), start: time), source: .application)
        let frames = mixer.render(until: time + 0.2, flush: true)
        if step > 0 { #expect(frames.allSatisfy { $0.data.allSatisfy { $0 == 0 } }) }
    }
}

@Test func mixerRejectsUnboundedOrEntirelyLateInput() throws {
    var mixer = TimestampedAudioMixer()
    try mixer.append(.init(data: pcm(1), start: 10), source: .application)
    _ = mixer.render(until: 10.4, flush: true)
    #expect(throws: AudioMixError.self) { try mixer.append(.init(data: pcm(1), start: 10), source: .microphone) }
    #expect(throws: AudioMixError.self) { try mixer.append(.init(data: pcm(1), start: 100), source: .application) }
    #expect(throws: AudioMixError.self) { try mixer.append(.init(data: Data([1]), start: 11), source: .application) }
}

@Test func mixerAcceptsEarlierTimestampFromTheSecondDeviceBeforeRendering() throws {
    var mixer = TimestampedAudioMixer()
    try mixer.append(.init(data: pcm(10000), start: 10.1), source: .application)
    try mixer.append(.init(data: pcm(20000), start: 10.0), source: .microphone)
    let frames = mixer.render(until: 10.3, flush: true)
    let data = frames.reduce(Data()) { $0 + $1.data }
    #expect(frames.first?.start == 10)
    #expect(data.count == 9600)
    #expect(sample(data, 100) == 10000)
    #expect(sample(data, 2000) == 15000)
    #expect(sample(data, 4000) == 5000)
}
