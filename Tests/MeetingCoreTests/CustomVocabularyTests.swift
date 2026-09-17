import Foundation
import Testing
@testable import MeetingCore

private let scope = VocabularyScope(profile: "default", region: "us-west-2")
private func term(_ phrase: String, display: String = "", language: VocabularyLanguage = .english) -> VocabularyEntry {
    var entry = VocabularyEntry(); entry.phrase = phrase; entry.displayAs = display; entry.language = language
    return entry
}

@Test func vocabularyTablesSeparateLanguagesNormalizePhrasesAndExcludeNotes() throws {
    var library = CustomVocabularyLibrary()
    var english = term("Amazon Bedrock", display: "Amazon Bedrock")
    english.note = "local-only-note"
    try library.save(english)
    try library.save(term("亚马逊", display: "亚马逊", language: .chinese))
    var disabled = term("Disabled"); disabled.enabled = false
    try library.save(disabled)
    let plans = try library.plans()
    #expect(plans.count == 2)
    let plan = try #require(plans.first { $0.binding.language == .english })
    #expect(String(decoding: plan.table, as: UTF8.self) == "Phrase\tSoundsLike\tIPA\tDisplayAs\nAmazon-Bedrock\t\t\tAmazon Bedrock\n")
    #expect(plan.binding.entryCount == 1)
    #expect(!String(decoding: plan.table, as: UTF8.self).contains("local-only-note"))
    #expect(plan.binding.name.hasPrefix(library.resourcePrefix))
    #expect(plan.key.hasPrefix(library.objectPrefix))
    let restored = try JSONDecoder().decode(CustomVocabularyLibrary.self, from: JSONEncoder().encode(library))
    #expect(restored.entries == library.entries)
    #expect(restored.id == library.id)
    #expect(try restored.plans().map(\.binding) == plans.map(\.binding))
}

@Test func vocabularyContentVersionsIgnoreNotesAndOrderingButChangeForOutputEdits() throws {
    var library = CustomVocabularyLibrary()
    var entry = term("A.W.S.", display: "AWS")
    try library.save(entry); try library.save(term("Bedrock"))
    let first = try #require(library.plans().first)
    library.entries.reverse()
    entry.note = "changed locally"; try library.save(entry)
    #expect(try library.plans().first?.binding == first.binding)
    entry.displayAs = "AWS Cloud"; try library.save(entry)
    #expect(try library.plans().first?.binding.name != first.binding.name)
    #expect(try library.plans().first?.binding.digest != first.binding.digest)
}

@Test func vocabularyRejectsInvalidEntriesDuplicateImportsAndOversizeTablesAtomically() throws {
    var library = CustomVocabularyLibrary()
    #expect(throws: VocabularyError.self) { try library.save(term("GPT5")) }
    #expect(throws: VocabularyError.self) { try library.save(term("C++")) }
    #expect(throws: VocabularyError.self) { try library.save(term("Valid", display: "bad\toutput")) }
    try library.save(term("G.P.T.-five", display: "GPT5"))
    #expect(throws: VocabularyError.self) { try library.importLines("New\nNew", language: .english) }
    #expect(library.entries.count == 1)
    #expect(try library.importLines("A.W.S.\tAWS\nAmazon Bedrock\tAmazon Bedrock", language: .english) == 2)
    var oversized = CustomVocabularyLibrary()
    for index in 0..<100 {
        // Distinct letters, no numeric Phrase input; each entry stays below the per-row character limit.
        let suffix = String(UnicodeScalar(0x4e00 + index)!)
        oversized.entries.append(term(String(repeating: "词", count: 200) + suffix, language: .chinese))
    }
    #expect(throws: VocabularyError.self) { try oversized.plans() }
}

@Test func onlyReadyMatchingScopeAndCurrentContentCanBeUsedByNewRecordings() throws {
    var library = CustomVocabularyLibrary()
    let entry = term("A.W.S.", display: "AWS")
    try library.save(entry)
    let plan = try #require(library.plans().first)
    #expect(throws: VocabularyError.self) { try library.snapshot(language: .english, scope: scope) }
    library.record(.init(plan: plan, scope: scope, bucket: "example-bucket", state: .pending))
    #expect(throws: VocabularyError.self) { try library.snapshot(language: .english, scope: scope) }
    library.record(.init(plan: plan, scope: scope, bucket: "example-bucket", state: .ready))
    let snapshot = try #require(try library.snapshot(language: .mixed, scope: scope))
    #expect(snapshot.bindings == [plan.binding])
    #expect(try library.snapshot(language: .chinese, scope: scope) == nil)
    #expect(throws: VocabularyError.self) {
        try library.snapshot(language: .english, scope: .init(profile: "other", region: "us-west-2"))
    }
    var edited = entry; edited.displayAs = "AWS Cloud"; try library.save(edited)
    #expect(throws: VocabularyError.self) { try library.snapshot(language: .english, scope: scope) }
    #expect(snapshot.bindings == [plan.binding])
}

@Test func vocabularySnapshotDecodesWithSettingsAndOldSettingsNeedNoMigration() throws {
    var settings = AppSettings()
    let old = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(old.transcriptionVocabulary == nil)
    settings.transcriptionVocabulary = .init(scope: scope, bindings: [.init(language: .english, name: "mr-test-en",
                                                                           digest: "content", entryCount: 1)])
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(restored.transcriptionVocabulary == settings.transcriptionVocabulary)
    #expect(throws: VocabularyError.self) {
        try restored.transcriptionVocabulary?.validate(scope: .init(profile: "default", region: "us-east-1"))
    }
}

@Test func cleanupProtectsCurrentVersionsAndMeetingReferencesAcrossProfileAliases() throws {
    var library = CustomVocabularyLibrary()
    var entry = term("A.W.S.", display: "AWS"); try library.save(entry)
    let old = try #require(library.plans().first)
    let oldDeployment = VocabularyDeployment(plan: old, scope: scope, bucket: "example-bucket", state: .ready)
    library.record(oldDeployment)
    entry.displayAs = "AWS Cloud"; try library.save(entry)
    let current = try #require(library.plans().first)
    library.record(.init(plan: current, scope: scope, bucket: "example-bucket", state: .ready))
    #expect(try library.cleanupCandidates(scope: scope, retained: []).map(\.id) == [oldDeployment.id])
    let retained = VocabularySnapshot(scope: .init(profile: "alias-for-same-account", region: scope.region), bindings: [old.binding])
    #expect(try library.cleanupCandidates(scope: scope, retained: [retained]).isEmpty)
}
