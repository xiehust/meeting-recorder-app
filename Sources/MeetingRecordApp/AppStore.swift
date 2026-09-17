import AppKit
import AVFoundation
import Combine
import MeetingCore
import MeetingAudio
import MeetingCloud

struct StartMeetingRequest: Identifiable {
    let id = UUID()
    let application: MeetingApplication?
}

@MainActor
final class AppStore: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selection: UUID?
    @Published var settings = AppSettings()
    @Published private(set) var templateLibrary = SummaryTemplateLibrary()
    @Published private(set) var templateLibraryError: String?
    @Published var vocabularyLibrary = CustomVocabularyLibrary()
    @Published var vocabularyLibraryError: String?
    @Published var vocabularyStatus = "尚未同步"
    @Published var vocabularyBusy = false
    @Published var vocabularyError: String?
    var vocabularyTask: Task<Void, Never>?
    @Published var startRequest: StartMeetingRequest?
    @Published var showSettings = false
    @Published var starting = false
    @Published var error: String?
    @Published private(set) var meetingReminders = MeetingApplicationReminders()
    @Published var levels: [AudioSource: Float] = [:]
    @Published var captureStates: [AudioSource: String] = [:]
    @Published var cloudStates: [AudioSource: String] = [:]
    @Published var partials: [String: String] = [:]
    @Published var connectionStatus = "尚未检查"
    @Published var checkingConnection = false
    @Published var modelConnectionStatus = "尚未验证模型调用"
    @Published var checkingModel = false
    @Published private(set) var microphoneEnabled = false
    @Published private(set) var changingMicrophone = false
    @Published var ready = false
    private var repository: MeetingRepository?
    let directory: URL
    private var captures: [AudioSource: CaptureSession] = [:]
    private var streams: [String: TranscriptionStream] = [:]
    private var currentStreamIDs: [AudioSource: String] = [:]
    private var currentCaptureIDs: [AudioSource: String] = [:]
    private var expectedEndSessions = Set<String>()
    private var saveTask: Task<Void, Never>?
    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    var batchTasks: [UUID: Task<Void, Never>] = [:]
    private var observation: [NSObjectProtocol] = []
    private var monitor: Task<Void, Never>?
    private var watchdogs: [AudioSource: CaptureWatchdog] = [:]
    private var stalledApplicationInterval: UUID?
    private let waitingForApplicationAudio = "尚未收到会议应用音频，仍在等待；请检查应用内声音与系统音频权限。"
    private var activeApplication: MeetingApplication?
    private var microphoneID: UInt32 = 0
    private var transcribeEnabled = true

    var selected: Meeting? { meetings.first { $0.id == selection } }
    var active: Meeting? { meetings.first { $0.status.isActive } }
    var mayStart: Bool { ready && active == nil && !starting }
    var processingMeeting: Meeting? { meetings.first { $0.status.isProcessing } }
    var hasAIProcessing: Bool { !processingTasks.isEmpty || !batchTasks.isEmpty }
    func isProcessing(_ id: UUID) -> Bool { processingTasks[id] != nil || batchTasks[id] != nil }

    func prepareToStart(application: MeetingApplication? = nil) {
        guard mayStart, startRequest == nil else { return }
        startRequest = StartMeetingRequest(application: application)
    }

    func dismissMeetingReminders() {
        meetingReminders.dismissAll()
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("MeetingRecord", isDirectory: true)
        if let data = UserDefaults.standard.data(forKey: "settings"),
           let stored = try? JSONDecoder().decode(AppSettings.self, from: data) { settings = stored }
        if let status = UserDefaults.standard.string(forKey: "lastModelConnectionStatus") { modelConnectionStatus = status }
        var migratedEndpoint = false
        if settings.correction.endpoint == "mantle", let runtime = try? AIModelCatalog.resolve(settings.correction) {
            settings.correction = runtime; migratedEndpoint = true
        }
        if settings.summary.endpoint == "mantle", let runtime = try? AIModelCatalog.resolve(settings.summary) {
            settings.summary = runtime; migratedEndpoint = true
        }
        if migratedEndpoint {
            saveSettings()
            modelConnectionStatus = "已切换至 Bedrock Runtime Responses · global 推理配置，需重新验证连接。"
            UserDefaults.standard.set(modelConnectionStatus, forKey: "lastModelConnectionStatus")
        }
        if let data = UserDefaults.standard.data(forKey: "summaryTemplateLibrary") {
            do {
                let library = try JSONDecoder().decode(SummaryTemplateLibrary.self, from: data)
                try library.validateLoaded()
                templateLibrary = library
            } catch { templateLibraryError = "模板库读取失败，原数据已保留；请检查本地设置后重新打开应用。" }
        }
        loadVocabularyLibrary()
        Task {
            do {
                let repository = try MeetingRepository(directory: directory)
                self.repository = repository
                meetings = try await repository.loadAll(recover: true)
                for index in meetings.indices where meetings[index].issue?.contains("当前版本尚未接入 AI") == true {
                    meetings[index].issue = nil
                    try await repository.save(meetings[index])
                }
                selection = meetings.first?.id
                ready = true
            } catch { self.error = error.localizedDescription }
        }
        let center = NSWorkspace.shared.notificationCenter
        observation.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause(reason: "系统进入睡眠；需手动恢复") }
        })
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                self.inspectSources()
            }
        }
    }

    func saveSettings() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(settings), forKey: "settings") }
        catch { self.error = error.localizedDescription }
    }

    @discardableResult func saveSummaryTemplate(_ draft: SummaryTemplate) throws -> SummaryTemplate {
        if let templateLibraryError { throw SummaryTemplateError.invalid(templateLibraryError) }
        var library = templateLibrary
        let saved = try library.save(draft)
        let encoded = try JSONEncoder().encode(library)
        if settings.effectiveSummaryTemplate.id == saved.id { try setDefaultSummaryTemplate(saved) }
        UserDefaults.standard.set(encoded, forKey: "summaryTemplateLibrary")
        templateLibrary = library
        return saved
    }

    func deleteSummaryTemplate(_ id: String) throws {
        if let templateLibraryError { throw SummaryTemplateError.invalid(templateLibraryError) }
        var library = templateLibrary
        try library.delete(id: id)
        let encoded = try JSONEncoder().encode(library)
        if settings.effectiveSummaryTemplate.id == id { try setDefaultSummaryTemplate(.meeting) }
        UserDefaults.standard.set(encoded, forKey: "summaryTemplateLibrary")
        templateLibrary = library
    }

    func setDefaultSummaryTemplate(_ template: SummaryTemplate) throws {
        let template = try template.validated()
        // Persist only the default template; other unsaved edits in the Settings sheet remain untouched.
        var persisted = UserDefaults.standard.data(forKey: "settings")
            .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        persisted.summaryTemplate = template
        let encoded = try JSONEncoder().encode(persisted)
        settings.summaryTemplate = template
        UserDefaults.standard.set(encoded, forKey: "settings")
    }

    func selectSummaryTemplate(_ template: SummaryTemplate, meetingID: UUID) {
        guard !isProcessing(meetingID) else { return }
        do {
            let validated = try template.validated()
            mutate(meetingID) { $0.settings.summaryTemplate = validated }
        } catch { self.error = error.localizedDescription }
    }

    func checkConnection() {
        guard !checkingConnection else { return }
        checkingConnection = true; connectionStatus = "正在检查所选 profile…"
        let snapshot = settings
        Task {
            do {
                try await TranscriptionStream.checkCredentials(settings: snapshot)
                connectionStatus = "凭证有效 · \(snapshot.profile) · \(snapshot.transcribeRegion)\n转录与模型调用权限仍需单独验证。"
            } catch { connectionStatus = TranscriptionStream.userMessage(error) }
            checkingConnection = false
        }
    }

    func checkModelConnection() {
        guard !checkingModel else { return }
        checkingModel = true; modelConnectionStatus = "正在验证校对模型（少量推理用量）…"
        let snapshot = settings
        Task {
            defer { checkingModel = false }
            do {
                _ = try await BedrockResponsesClient().generate(instructions: "Reply with JSON: {\"ok\":true}.",
                    input: "Connection check. No meeting content.", configuration: snapshot.correction,
                    profile: snapshot.profile, maxOutputTokens: 2_048)
                modelConnectionStatus = "\(snapshot.correction.model.rawValue) / \(snapshot.correction.reasoningEffort) 调用成功"
            } catch { modelConnectionStatus = "\(snapshot.correction.model.rawValue)：\(Self.aiMessage(error))" }
            modelConnectionStatus += "\n验证时间：\(Date().formatted(date: .numeric, time: .shortened))"
            UserDefaults.standard.set(modelConnectionStatus, forKey: "lastModelConnectionStatus")
        }
    }

    func start(title: String, application: MeetingApplication, microphone: MicrophoneDevice?,
               useMicrophone: Bool, cloud: Bool, cache: Bool, language: RecognitionLanguage,
               summaryTemplate: SummaryTemplate? = nil, useVocabulary: Bool = false, automaticBatch: Bool? = nil) async {
        guard mayStart else { return }
        error = nil
        starting = true
        defer { starting = false }
        var snapshot = settings; snapshot.cacheAudio = cache; snapshot.language = language
        snapshot.automaticBatchTranscription = automaticBatch ?? settings.automaticBatchTranscription ?? false
        snapshot.batchTranscriptionBucket = batchBucket
        if snapshot.automaticBatchTranscription == true { snapshot.cacheAudio = true }
        snapshot.transcriptionVocabulary = nil
        do {
            snapshot.summaryTemplate = try (summaryTemplate ?? settings.effectiveSummaryTemplate).validated()
            if snapshot.automaticBatchTranscription == true { try CustomVocabularyLibrary.validateBucket(batchBucket) }
            if (cloud || snapshot.automaticBatchTranscription == true) && useVocabulary {
                if let vocabularyLibraryError { throw VocabularyError.invalid(vocabularyLibraryError) }
                snapshot.transcriptionVocabulary = try vocabularyLibrary.snapshot(language: language, scope: vocabularyScope)
                if let vocabulary = snapshot.transcriptionVocabulary {
                    let service = VocabularyService(remote: try await AWSVocabularyRemote(scope: vocabulary.scope))
                    try await service.verifyReady(vocabulary)
                }
            }
        } catch {
            self.error = error is SummaryTemplateError ? error.localizedDescription : VocabularyService.userMessage(error)
            return
        }
        if useMicrophone {
            guard microphone != nil else { error = "请选择可用麦克风。"; return }
            guard await AVCaptureDevice.requestAccess(for: .audio) else { error = CaptureError.microphoneDenied.localizedDescription; return }
        }
        let meeting = Meeting(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名会议" : title,
            applicationName: application.name, bundleID: application.id,
            microphoneName: useMicrophone ? microphone!.name : "未采集麦克风", settings: snapshot)
        meetings.insert(meeting, at: 0); selection = meeting.id
        activeApplication = application; microphoneID = microphone?.id ?? 0
        microphoneEnabled = useMicrophone; transcribeEnabled = cloud
        levels = [:]; captureStates = [:]; cloudStates = [:]; partials = [:]
        await persist(meeting)
        guard self.error == nil else { return }
        startRequest = nil
        startSources(meeting: meeting)
    }

    private func startSources(meeting: Meeting) {
        guard let app = activeApplication else { return }
        startSource(.application, meeting: meeting, application: app)
        if microphoneEnabled { startSource(.microphone, meeting: meeting, application: app) }
        else {
            captureStates[.microphone] = "已静音（仅本应用）"; cloudStates[.microphone] = "麦克风转录未启用"
            mutate(meeting.id) { current in
                if !current.intervals.contains(where: { $0.source == .microphone && $0.end == nil }) {
                    current.intervals.append(.init(kind: .missing, source: .microphone, start: current.offset(),
                        reason: "本应用麦克风已静音；仅采集会议应用声音"))
                }
            }
        }
        if captures.isEmpty {
            mutate(meeting.id) { current in
                current.closeIntervals(); current.endedAt = Date(); current.status = .failed
            }
        }
    }

    private func startSource(_ source: AudioSource, meeting: Meeting, application: MeetingApplication) {
        let capture = CaptureSession()
        let stream = TranscriptionStream()
        currentCaptureIDs[source] = stream.sessionID
        let offset = meeting.offset()
        let cachePath = "Audio/\(meeting.id.uuidString)/\(source.rawValue)-\(stream.sessionID).caf"
        let cacheURL = meeting.settings.cacheAudio ? directory.appendingPathComponent(cachePath) : nil
        let id = meeting.id
        let sessionSettings = meeting.settings
        let meetingStartedAt = meeting.startedAt
        let audioStartMarker = AudioStartMarker()
        watchdogs[source] = CaptureWatchdog(startedAt: Date())
        if source == .application { stalledApplicationInterval = nil }
        if transcribeEnabled {
            streams[stream.sessionID] = stream; currentStreamIDs[source] = stream.sessionID
            cloudStates[source] = "等待音频到达后连接"
        } else { cloudStates[source] = "本地采集验证 · 未上传" }
        let onData: @Sendable (Data) -> Void = { [weak self, cloud = transcribeEnabled] data in
            guard !data.isEmpty else { return }
            // A process tap can wait indefinitely for the application to begin audio IO.
            // Start AWS only on the first PCM chunk; preserve that chunk's meeting time instead of the permission-dialog time.
            let audioOffset = max(0, Date().timeIntervalSince(meetingStartedAt) - Double(data.count) / 32_000)
            if cacheURL != nil, audioStartMarker.claim() {
                Task { @MainActor in
                    self?.mutate(id) { meeting in
                        if let index = meeting.audioChunks.firstIndex(where: { $0.relativePath == cachePath }) {
                            meeting.audioChunks[index].audioStart = audioOffset
                        }
                    }
                }
            }
            guard cloud else { return }
            stream.start(settings: sessionSettings, source: source, offset: audioOffset) { [weak self] update in
                await self?.receive(update, meetingID: id, source: source, sessionID: stream.sessionID, offset: audioOffset)
            }
            stream.send(data)
        }
        let onLevel: @Sendable (Float) -> Void = { [weak self] level in
            Task { @MainActor in
                guard self?.active?.id == id, self?.active?.status == .recording,
                      self?.currentCaptureIDs[source] == stream.sessionID else { return }
                self?.levels[source] = level; self?.watchdogs[source]?.frameArrived(at: Date())
                self?.captureStates[source] = level > 0.008 ? "正在采集" : "已连接 · 暂无声音"
                if source == .application,
                   self?.stalledApplicationInterval != nil || self?.active?.issue == self?.waitingForApplicationAudio {
                    let intervalID = self?.stalledApplicationInterval
                    self?.stalledApplicationInterval = nil
                    self?.mutate(id) { current in
                        if let index = current.intervals.firstIndex(where: { $0.id == intervalID }) {
                            current.intervals[index].end = current.offset()
                        }
                        if current.issue == self?.waitingForApplicationAudio { current.issue = nil }
                    }
                }
            }
        }
        let onFailure: @Sendable (Error) -> Void = { [weak self] failure in
            Task { @MainActor in
                guard self?.currentCaptureIDs[source] == stream.sessionID else { return }
                self?.captureFailure(source, meetingID: id, message: failure.localizedDescription, from: offset)
            }
        }
        do {
            if source == .application {
                try capture.startApplication(application, cacheURL: cacheURL, onData: onData, onLevel: onLevel, onFailure: onFailure)
            } else {
                try capture.startMicrophone(deviceID: microphoneID, cacheURL: cacheURL, onData: onData, onLevel: onLevel, onFailure: onFailure)
            }
            // Permission dialogs and device startup can take time. Anchor service time only once capture is running.
            let sessionOffset = meeting.offset()
            captures[source] = capture
            captureStates[source] = "已连接 · 等待声音"
            mutate(id) { meeting in
                if cacheURL != nil { meeting.audioChunks.append(.init(source: source, relativePath: cachePath, start: sessionOffset)) }
                if source == .application {
                    meeting.applicationAudioDiagnostic = .init(bundleIDs: capture.scopedBundleIDs,
                        processCount: capture.scopedProcessCount, clockDeviceName: capture.clockDeviceName)
                }
                if !self.transcribeEnabled {
                    meeting.intervals.append(.init(kind: cacheURL == nil ? .missing : .pendingTranscription,
                        source: source, start: sessionOffset, reason: "\(source.title)：本地采集验证，未启用转录"))
                }
            }
        } catch {
            expectedEndSessions.insert(stream.sessionID)
            stream.finish()
            captureFailure(source, meetingID: id, message: error.localizedDescription, from: offset)
        }
    }

    private func receive(_ update: TranscriptionUpdate, meetingID: UUID, source: AudioSource, sessionID: String, offset: TimeInterval) async {
        let isCurrent = currentStreamIDs[source] == sessionID
        switch update {
        case .connected:
            if isCurrent { cloudStates[source] = "转录已连接" }
        case let .partial(id, text):
            if active?.id == meetingID { partials["\(sessionID)/\(id)"] = text }
        case let .final(resultID, segments):
            partials.removeValue(forKey: "\(sessionID)/\(resultID)")
            guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
            do {
                for segment in segments { try meetings[index].ingest(segment) }
                meetings[index].lastSavedAt = Date()
                await persist(meetings[index])
            } catch { self.error = error.localizedDescription }
        case .ended:
            if isCurrent { cloudStates[source] = "已收尾" }
            let unresolved = partials.keys.contains { $0.hasPrefix("\(sessionID)/") }
            if unresolved || !expectedEndSessions.contains(sessionID) {
                await receive(.failed(unresolved ? "仍有临时转录未收到确定结果，请核对收尾区间。" : "转录流意外结束，请暂停后恢复连接。"),
                              meetingID: meetingID, source: source, sessionID: sessionID, offset: offset)
            }
        case let .failed(message):
            if isCurrent { cloudStates[source] = message }
            mutate(meetingID) { meeting in
                let last = meeting.segments.filter { $0.sessionID == sessionID }.map(\.end).max() ?? offset
                let cached = meeting.settings.cacheAudio && meeting.audioChunks.contains { $0.source == source && $0.start <= offset + 1 }
                meeting.intervals.append(.init(kind: cached ? .pendingTranscription : .missing, source: source,
                    start: last, end: meeting.status == .recording ? nil : meeting.offset(at: meeting.endedAt ?? Date()),
                    reason: "\(source.title)：\(message)"))
                meeting.issue = message
            }
        }
    }

    private func captureFailure(_ source: AudioSource, meetingID: UUID, message: String, from offset: TimeInterval) {
        captures[source]?.stop(); captures.removeValue(forKey: source); currentCaptureIDs.removeValue(forKey: source)
        if let id = currentStreamIDs[source] { expectedEndSessions.insert(id); streams[id]?.finish() }
        captureStates[source] = message; levels[source] = 0
        mutate(meetingID) { meeting in
            meeting.issue = message
            meeting.intervals.append(.init(kind: .missing, source: source, start: offset, reason: "\(source.title)：\(message)"))
        }
    }

    func pause(reason: String = "用户暂停") {
        guard let meeting = active, meeting.status == .recording else { return }
        stopCapture()
        mutate(meeting.id) { meeting in
            meeting.closeIntervals()
            try? meeting.pause(reason: reason)
        }
        for source in AudioSource.allCases { levels[source] = 0; captureStates[source] = "已暂停" }
    }

    func resume(language: RecognitionLanguage? = nil) {
        guard let meeting = active, meeting.status == .paused else { return }
        guard let application = AudioDevices.meetingApplications().first(where: { $0.id == meeting.applicationBundleID }) else {
            error = "所选会议应用尚未运行，请打开它后再恢复。"; return
        }
        activeApplication = application
        if let language { mutate(meeting.id) { $0.settings.language = language } }
        mutate(meeting.id) { try? $0.resume() }
        if let current = active { startSources(meeting: current) }
    }

    func toggleMicrophone() async {
        guard !changingMicrophone, let meeting = active, meeting.status == .recording else { return }
        changingMicrophone = true
        defer { changingMicrophone = false }
        if microphoneEnabled {
            captures[.microphone]?.stop(); captures.removeValue(forKey: .microphone)
            currentCaptureIDs.removeValue(forKey: .microphone)
            if let id = currentStreamIDs[.microphone] { expectedEndSessions.insert(id); streams[id]?.finish() }
            microphoneEnabled = false; captureStates[.microphone] = "已静音（仅本应用）"; levels[.microphone] = 0
            mutate(meeting.id) { current in
                for i in current.audioChunks.indices where current.audioChunks[i].source == .microphone && current.audioChunks[i].end == nil {
                    current.audioChunks[i].end = current.offset()
                }
                current.intervals.append(.init(kind: .missing, source: .microphone, start: current.offset(), reason: "用户手动静音本应用麦克风；会议应用声音继续采集"))
            }
        } else {
            guard let app = activeApplication,
                  let microphone = AudioDevices.microphones().first(where: { $0.id == microphoneID }) else {
                error = "所选麦克风不可用。请结束本次记录后，在开始面板选择可用的麦克风。"
                return
            }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                error = CaptureError.microphoneDenied.localizedDescription; return
            }
            guard active?.id == meeting.id, active?.status == .recording else { return }
            microphoneEnabled = true
            mutate(meeting.id) { current in
                current.microphoneName = microphone.name
                for i in current.intervals.indices where current.intervals[i].source == .microphone && current.intervals[i].end == nil {
                    current.intervals[i].end = current.offset()
                }
            }
            startSource(.microphone, meeting: meeting, application: app)
            if captures[.microphone] == nil { microphoneEnabled = false }
        }
    }

    func finish(automaticallyProcess: Bool = true) async {
        guard let meeting = active, meeting.status != .finalizing else { return }
        stopCapture()
        mutate(meeting.id) { try? $0.finish() }
        let pending = Array(streams.values)
        // Explicit bounded drain. A timeout cancels streams and leaves incomplete intervals visible.
        let drained = await withCheckedContinuation { continuation in
            let latch = DrainLatch(continuation)
            Task {
                for stream in pending { await stream.waitUntilFinished() }
                latch.resolve(true)
            }
            Task {
                try? await Task.sleep(for: .seconds(12))
                if latch.resolve(false) { pending.forEach { $0.cancel() } }
            }
        }
        streams.removeAll(); currentStreamIDs.removeAll()
        mutate(meeting.id) { current in
            if !drained {
                current.issue = "转录收尾超过 12 秒。已保存收到的确定结果，最后一段可能不完整。"
                current.intervals.append(.init(kind: .missing,
                    start: current.segments.map(\.end).max() ?? 0, end: current.offset(at: current.endedAt ?? Date()),
                    reason: "转录收尾超时，最后的结果未确认"))
            }
            current.closeIntervals(now: current.endedAt ?? Date())
            current.status = current.issue == nil ? .pending : .failed
        }
        partials.removeAll()
        await saveTask?.value
        if automaticallyProcess, let completed = meetings.first(where: { $0.id == meeting.id }) {
            switch completed.postRecordingAction {
            case .batchReview:
                startBatch(meetingID: meeting.id, configuration: completed.settings,
                           bucket: completed.settings.batchTranscriptionBucket ?? "")
            case .generateMinutes: processAI(meeting.id, operation: .full)
            case .none: break
            }
        }
    }

    private func stopCapture() {
        for capture in captures.values { capture.stop() }
        captures.removeAll(); currentCaptureIDs.removeAll()
        for stream in streams.values { expectedEndSessions.insert(stream.sessionID); stream.finish() }
    }

    func mutate(_ id: UUID, _ operation: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        operation(&meetings[index]); meetings[index].lastSavedAt = Date()
        enqueueSave(meetings[index])
    }

    @discardableResult func enqueueSave(_ meeting: Meeting) -> Task<Void, Error> {
        let previous = saveTask
        let operation = Task { [weak self] in
            await previous?.value
            guard let self else { throw CancellationError() }
            try await self.write(meeting)
        }
        saveTask = Task { _ = try? await operation.value }
        return operation
    }
    private func persist(_ meeting: Meeting) async { _ = try? await enqueueSave(meeting).value }
    func flush() async { await saveTask?.value }
    private func write(_ meeting: Meeting) async throws {
        do {
            guard let repository else { throw StorageError.operation("本地资料库尚未初始化。") }
            try await repository.save(meeting)
        }
        catch {
            self.error = error.localizedDescription
            stopCapture()
            processingTasks.values.forEach { $0.cancel() }
            batchTasks.values.forEach { $0.cancel() }
            for index in meetings.indices where meetings[index].status.isActive || meetings[index].status.isProcessing {
                meetings[index].status = .failed
                meetings[index].issue = "本地保存失败，已停止采集。屏幕上未保存的内容仍可导出。"
            }
            throw error
        }
    }

    func processAI(_ id: UUID, operation: AIWorkflowOperation) {
        guard !isProcessing(id), let snapshot = meetings.first(where: { $0.id == id }), !snapshot.status.isActive else { return }
        processingTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.processingTasks.removeValue(forKey: id); self.objectWillChange.send() }
            do {
                try await MeetingAIWorkflow().run(meeting: snapshot, operation: operation) { [weak self] event in
                    try Task.checkCancellation()
                    try await self?.applyAI(event, meetingID: id)
                }
                if operation == .correction {
                    try await applyAI(.progress(.init(stage: .completed, progress: "校对已保存，可生成纪要")), meetingID: id)
                }
            } catch {
                let message = Task.isCancelled ? "AI 处理已取消，已保存的版本仍可查看。" : Self.aiMessage(error)
                try? await applyAI(.progress(.init(stage: Task.isCancelled ? .cancelled : .failed,
                    progress: "处理未完成", error: message)), meetingID: id)
            }
        }
        objectWillChange.send()
    }

    private func applyAI(_ event: AIWorkflowEvent, meetingID: UUID) async throws {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { throw CancellationError() }
        try meetings[index].applyAIEvent(event)
        try await enqueueSave(meetings[index]).value
    }

    func cancelAI(_ id: UUID) { processingTasks[id]?.cancel(); batchTasks[id]?.cancel() }
    func cancelAllAI() async {
        let ids = Array(processingTasks.keys)
        processingTasks.values.forEach { $0.cancel() }
        let batch = Array(batchTasks.values)
        batch.forEach { $0.cancel() }
        for task in batch { await task.value }
        for id in ids {
            try? await applyAI(.progress(.init(stage: .cancelled, progress: "退出时中断 AI 处理", error: "已保留完成的结果，可稍后重试。")), meetingID: id)
        }
        await flush()
    }
    static func aiMessage(_ error: Error) -> String {
        if error is AIError || error is StorageError || error is SummaryTemplateError { return error.localizedDescription }
        if let error = error as? URLError {
            return error.code == .timedOut ? "模型调用超时。请求可能已计费；已保存结果仍保留，可从失败阶段重试。" : "模型连接失败，请检查网络后重试。"
        }
        return "AI 处理失败，请检查 AWS profile 与模型访问权限；现有记录和已完成结果已保留。"
    }

    func review(_ meetingID: UUID, versionID: UUID, changeID: UUID, disposition: CorrectionDisposition) {
        mutate(meetingID) { meeting in
            do { try meeting.reviewCorrection(versionID: versionID, changeID: changeID, disposition: disposition) }
            catch { self.error = error.localizedDescription }
        }
    }

    func acceptAllCorrections(_ meetingID: UUID, versionID: UUID) {
        guard !isProcessing(meetingID) else { return }
        mutate(meetingID) { meeting in
            do { try meeting.acceptAllPendingCorrections(versionID: versionID) }
            catch { self.error = error.localizedDescription }
        }
    }

    func saveMeetingNotes(_ meetingID: UUID, glossary: String, note: String) async -> Bool {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return false }
        if meetings[index].glossary != glossary || meetings[index].note != note {
            meetings[index].glossary = glossary
            meetings[index].note = note
            meetings[index].revision += 1
        }
        meetings[index].lastSavedAt = Date()
        do {
            try await enqueueSave(meetings[index]).value
            return true
        } catch {
            // write() already exposes the storage error. Do not advance to correction after a failed save.
            return false
        }
    }

    func editMinutes(_ meetingID: UUID, version: MinutesVersion, markdown: String) {
        guard markdown != MeetingExport.minutesBody(version) else { return }
        mutate(meetingID) { meeting in
            let next = MinutesVersion(input: version.input, correctionVersionID: version.correctionVersionID,
                configuration: version.configuration, profile: version.profile, minutes: version.minutes, invocation: version.invocation,
                editedFromVersionID: version.id, editedMarkdown: markdown, language: version.language,
                summaryTemplate: version.summaryTemplate)
            if meeting.minuteVersions == nil { meeting.minuteVersions = [] }
            meeting.minuteVersions?.append(next)
        }
    }

    func exportMinutes(_ version: MinutesVersion, format: MeetingExport.Format) {
        saveExport(MeetingExport.minutes(version, format: format), title: version.input.title + "·纪要", format: format)
    }
    func exportCorrection(_ meeting: Meeting, version: CorrectionVersion, format: MeetingExport.Format) {
        saveExport(MeetingExport.correctedTranscript(meeting, version: version, format: format),
                   title: meeting.title + "·校对稿", format: format)
    }
    private func saveExport(_ text: String, title: String, format: MeetingExport.Format) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title.replacingOccurrences(of: "/", with: "-")).\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }

    func delete(_ meeting: Meeting) async {
        guard !meeting.status.isActive, !isProcessing(meeting.id) else { return }
        await saveTask?.value
        do {
            try await repository?.delete(meeting.id)
            meetings.removeAll { $0.id == meeting.id }
            if selection == meeting.id { selection = meetings.first?.id }
        } catch { self.error = error.localizedDescription }
    }

    func export(_ meeting: Meeting, original: Bool, format: MeetingExport.Format) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.title.replacingOccurrences(of: "/", with: "-")).\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MeetingExport.transcript(meeting, original: original, format: format, includeNotes: true).write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }

    func loadExample() {
        guard mayStart else { return }
        var example = Meeting(title: "产品周会 · 示例", applicationName: "示例数据", bundleID: "",
                              microphoneName: "未采集", settings: settings, now: Date().addingTimeInterval(-1800))
        example.isExample = true; example.status = .pending; example.endedAt = Date()
        let lines: [(String, String, Double)] = [
            ("remote-a", "我们今天确认一下会议记录工具的首版范围，先验证 Teams 和 Zoom 的双路音频。", 12),
            ("me", "我会先完成 native macOS 应用和实时转录，原文与人工修改要分开保存。", 27),
            ("remote-b", "Mixed-language transcription 需要实测。日期还没有定，不要在纪要里写成承诺。", 48),
            ("remote-a", "同意先做技术验证。外放效果和长会议稳定性也需要记录。", 75)
        ]
        for (i, line) in lines.enumerated() {
            try? example.ingest(.init(sessionID: "example", resultID: "\(i)", source: line.0 == "me" ? .microphone : .application,
                                     start: line.2, end: line.2 + 8, text: line.1, speakerID: line.0))
        }
        example.issue = "这是用于体验编辑、人物管理和导出的示例，不代表已验证 AWS 或音频能力。"
        meetings.insert(example, at: 0); selection = example.id; enqueueSave(example)
    }

    private func inspectSources() {
        let apps = AudioDevices.meetingApplications()
        let current = Set(apps.map(\.id))
        meetingReminders.refresh(applications: apps, enabled: settings.detectMeetings)
        guard let meeting = active, meeting.status == .recording else { return }
        if !current.contains(meeting.applicationBundleID), captures[.application] != nil {
            captureFailure(.application, meetingID: meeting.id, message: "会议应用已退出；请暂停并重新选择来源。", from: meeting.offset())
        }
        for source in Array(captures.keys) {
            let last = watchdogs[source]?.lastFrameAt ?? Date()
            switch watchdogs[source]?.poll(source: source, now: Date()) ?? .none {
            case .none: break
            case .waitForApplicationAudio:
                captureStates[source] = waitingForApplicationAudio
                let interval = TimelineInterval(kind: .missing, source: .application, start: meeting.offset(at: last),
                    reason: "未收到会议应用音频；此区间完整性待核对")
                stalledApplicationInterval = interval.id
                mutate(meeting.id) { current in
                    current.intervals.append(interval)
                    if current.issue == nil { current.issue = waitingForApplicationAudio }
                }
            case .stopUnavailableMicrophone:
                captureFailure(source, meetingID: meeting.id, message: "超过 8 秒未收到麦克风数据；设备可能已断开。请暂停后恢复。",
                               from: meeting.offset(at: last))
            }
        }
        // Lightweight checkpoint also bounds interruption recovery when no one is speaking.
        mutate(meeting.id) { _ in }
    }
}

private final class AudioStartMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !marked else { return false }; marked = true; return true
    }
}

@MainActor
private final class DrainLatch {
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    @discardableResult func resolve(_ drained: Bool) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: drained)
        return true
    }
}
