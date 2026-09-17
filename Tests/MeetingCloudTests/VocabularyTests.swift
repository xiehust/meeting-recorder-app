import Foundation
import Testing
import MeetingCore
@testable import MeetingCloud

private let scope = VocabularyScope(profile: "default", region: "us-west-2")
private func plan() throws -> VocabularyPlan {
    var library = CustomVocabularyLibrary()
    var entry = VocabularyEntry(); entry.phrase = "A.W.S."; entry.displayAs = "AWS"
    try library.save(entry)
    return try #require(library.plans().first)
}

private actor Remote: VocabularyRemoteAPI {
    var calls: [String] = []
    var results: [RemoteVocabularyStatus?]
    let region: String
    init(_ results: [RemoteVocabularyStatus?], region: String = "us-west-2") { self.results = results; self.region = region }
    func bucketRegion(_ bucket: String) -> String { calls.append("region"); return region }
    func upload(_ plan: VocabularyPlan, bucket: String) { calls.append("upload") }
    func get(_ name: String) -> RemoteVocabularyStatus? {
        calls.append("get")
        return results.count > 1 ? results.removeFirst() : results.first ?? nil
    }
    func submit(_ plan: VocabularyPlan, bucket: String, replaceFailed: Bool) {
        calls.append(replaceFailed ? "rebuild" : "create")
    }
    func delete(_ deployment: VocabularyDeployment) { calls.append("delete") }
}

private actor Received {
    var values: [VocabularyDeployment] = []
    func append(_ value: VocabularyDeployment) { values.append(value) }
}

@Test func vocabularySynchronizationWaitsForReadyAndCanResumeWithoutRecreating() async throws {
    let remote = Remote([nil, .init(language: .english, state: .pending), .init(language: .english, state: .ready)])
    let received = Received()
    try await VocabularyService(remote: remote, pollLimit: 3, pollDelay: .zero)
        .synchronize(plans: [plan()], scope: scope, bucket: "example-bucket") { await received.append($0) }
    #expect(await remote.calls == ["region", "get", "upload", "create", "get", "get"])
    #expect(await received.values.map(\.state) == [.pending, .pending, .ready])
    let pending = Remote([.init(language: .english, state: .pending), .init(language: .english, state: .ready)])
    try await VocabularyService(remote: pending, pollDelay: .zero)
        .synchronize(plans: [plan()], scope: scope, bucket: "example-bucket") { _ in }
    #expect(await pending.calls == ["region", "get", "get"])
}

@Test func vocabularySynchronizationRejectsWrongRegionBeforeUploading() async throws {
    let remote = Remote([nil], region: "us-east-1")
    await #expect(throws: VocabularyError.self) {
        try await VocabularyService(remote: remote).synchronize(plans: [plan()], scope: scope, bucket: "example-bucket") { _ in }
    }
    #expect(await remote.calls == ["region"])
}

@Test func vocabularyFailedBuildIsVisibleAndPendingWaitIsBounded() async throws {
    let remote = Remote([nil, .init(language: .english, state: .failed, failure: "Unsupported character")])
    let received = Received()
    await #expect(throws: VocabularyError.self) {
        try await VocabularyService(remote: remote, pollDelay: .zero)
            .synchronize(plans: [plan()], scope: scope, bucket: "example-bucket") { await received.append($0) }
    }
    #expect(await received.values.last?.state == .failed)
    let pending = Remote([.init(language: .english, state: .pending)])
    await #expect(throws: VocabularyError.self) {
        try await VocabularyService(remote: pending, pollLimit: 2, pollDelay: .zero)
            .synchronize(plans: [plan()], scope: scope, bucket: "example-bucket") { _ in }
    }
    #expect(await pending.calls.filter { $0 == "get" }.count == 3)
}

@Test func existingReadyVocabularyIsReusedAndWrongLanguageIsRejected() async throws {
    let ready = Remote([.init(language: .english, state: .ready)])
    let plan = try plan()
    let prior = VocabularyDeployment(plan: plan, scope: scope, bucket: "original-bucket", state: .ready)
    let received = Received()
    try await VocabularyService(remote: ready).synchronize(plans: [plan], scope: scope, bucket: "example-bucket",
                                                          previous: [prior]) { await received.append($0) }
    #expect(await ready.calls == ["region", "get"])
    #expect(await received.values.last?.bucket == "original-bucket")
    let wrong = Remote([.init(language: .chinese, state: .ready)])
    await #expect(throws: VocabularyError.self) {
        try await VocabularyService(remote: wrong).synchronize(plans: [plan], scope: scope, bucket: "example-bucket") { _ in }
    }
}

@Test func streamingUsesVocabularyNamesForMixedAndOneMatchingNameForFixedLanguage() {
    let snapshot = VocabularySnapshot(scope: scope, bindings: [
        .init(language: .chinese, name: "mr-zh", digest: "zh", entryCount: 2),
        .init(language: .english, name: "mr-en", digest: "en", entryCount: 3)
    ])
    for source in [AudioSource.microphone, .application] {
        let mixed = TranscriptionStream.makeInput(language: .mixed, source: source, sessionID: "s", vocabulary: snapshot)
        #expect(mixed.vocabularyNames == "mr-zh,mr-en")
        #expect(mixed.vocabularyName == nil)
        #expect(mixed.identifyMultipleLanguages == true)
        let english = TranscriptionStream.makeInput(language: .english, source: source, sessionID: "s", vocabulary: snapshot)
        #expect(english.vocabularyName == "mr-en")
        #expect(english.vocabularyNames == nil)
        #expect(english.identifyMultipleLanguages != true)
        let chinese = TranscriptionStream.makeInput(language: .chinese, source: source, sessionID: "s", vocabulary: snapshot)
        #expect(chinese.vocabularyName == "mr-zh")
    }
    let ordinary = TranscriptionStream.makeInput(language: .mixed, source: .application, sessionID: "s")
    #expect(ordinary.vocabularyName == nil && ordinary.vocabularyNames == nil)
}

@Test func failedVocabularyCanBeRebuiltAndStartPreflightRejectsMissingOrWrongLanguage() async throws {
    let plan = try plan()
    let retry = Remote([.init(language: .english, state: .failed), .init(language: .english, state: .ready)])
    try await VocabularyService(remote: retry, pollDelay: .zero)
        .synchronize(plans: [plan], scope: scope, bucket: "example-bucket") { _ in }
    #expect(await retry.calls == ["region", "get", "upload", "rebuild", "get"])
    let snapshot = VocabularySnapshot(scope: scope, bindings: [plan.binding])
    try await VocabularyService(remote: retry).verifyReady(snapshot)
    let results: [RemoteVocabularyStatus?] = [nil, .init(language: .english, state: .pending), .init(language: .chinese, state: .ready)]
    for result in results {
        await #expect(throws: VocabularyError.self) {
            try await VocabularyService(remote: Remote([result])).verifyReady(snapshot)
        }
    }
}
