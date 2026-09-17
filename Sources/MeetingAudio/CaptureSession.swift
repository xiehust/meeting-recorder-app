import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import MeetingCore

public final class CaptureSession {
    private var engine: AVAudioEngine?
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var processor: PCMProcessor?
    private let callbackQueue = DispatchQueue(label: "meetingrecord.tap", qos: .userInteractive)
    public private(set) var scopedBundleIDs: [String] = []
    public private(set) var scopedProcessCount = 0
    public private(set) var clockDeviceName: String?

    public init() {}
    deinit { stop() }

    @MainActor
    public func startMicrophone(deviceID: AudioDeviceID, cacheURL: URL?,
            onData: @escaping @Sendable (Data) -> Void, onLevel: @escaping @Sendable (Float) -> Void,
            onFailure: @escaping @Sendable (Error) -> Void) throws {
        stop()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw CaptureError.microphoneDenied }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw CaptureError.unavailable }
        var deviceID = deviceID
        try checkAudio(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "选择麦克风")
        let format = input.outputFormat(forBus: 0)
        let processor = try PCMProcessor(format: format, cacheURL: cacheURL, onData: onData, onLevel: onLevel, onFailure: onFailure)
        self.processor = processor; self.engine = engine
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in processor.consume(buffer) }
        do { try engine.start() }
        catch { stop(); throw error }
    }

    @MainActor
    public func startApplication(_ app: MeetingApplication, cacheURL: URL?,
            onData: @escaping @Sendable (Data) -> Void, onLevel: @escaping @Sendable (Float) -> Void,
            onFailure: @escaping @Sendable (Error) -> Void) throws {
        stop()
        guard NSRunningApplication(processIdentifier: app.pid)?.bundleIdentifier == app.id else { throw CaptureError.unavailable }
        let scope = try AudioDevices.applicationScope(app)
        let description = scope.tapDescription(name: app.name)
        scopedBundleIDs = scope.bundleIDs
        scopedProcessCount = scope.processes.count
        let clock = AudioDevices.defaultOutputClock()
        clockDeviceName = clock?.safeForCaptureClock == true ? clock?.name : nil
        do {
            try checkAudio(AudioHardwareCreateProcessTap(description, &tapID), "创建指定应用音频采集")
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var stream = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checkAudio(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &stream), "读取音频格式")
            guard let format = AVAudioFormat(streamDescription: &stream) else { throw CaptureError.invalidFormat }
            let processor = try PCMProcessor(format: format, cacheURL: cacheURL, onData: onData, onLevel: onLevel, onFailure: onFailure)
            self.processor = processor
            guard let tapUID = AudioDevices.stringProperty(tapID, selector: kAudioTapPropertyUID), !tapUID.isEmpty else {
                throw CaptureError.unavailable
            }
            let specification = TapAggregateConfiguration.make(tapUID: tapUID, clock: clock)
            try checkAudio(AudioHardwareCreateAggregateDevice(specification as CFDictionary, &aggregateID), "创建私有音频设备")
            try checkAudio(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, callbackQueue) { _, input, _, output, _ in
                // The clock device is output-only. Contribute silence, leaving other applications' playback unchanged.
                for buffer in UnsafeMutableAudioBufferListPointer(output) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
                processor.consume(buffer)
            }, "连接应用音频")
            try checkAudio(AudioDeviceStart(aggregateID, ioProc), "开始应用音频")
        } catch { stop(); throw error }
    }

    public func stop() {
        if let engine {
            engine.stop(); engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        if aggregateID != 0 {
            if let ioProc {
                AudioDeviceStop(aggregateID, ioProc)
                AudioDeviceDestroyIOProcID(aggregateID, ioProc)
                self.ioProc = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0
        }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        processor?.stop(); processor = nil
    }
}
