import Foundation
import Testing
@testable import MeetingCore

@Test func newRecordingsOfferTwoMixedPairsAndKeepLegacyMeetingsDecodable() throws {
    #expect(RecognitionLanguage.selectableCases == [.chinese, .english, .japanese, .mixed, .englishJapanese])
    #expect(RecognitionLanguage.multilingual.forNewRecording == .mixed)
    for value in RecognitionLanguage.selectableCases { #expect(value.forNewRecording == value) }
    #expect(try JSONDecoder().decode(RecognitionLanguage.self, from: Data("\"multilingual\"".utf8)) == .multilingual)
    #expect(try JSONDecoder().decode(RecognitionLanguage.self, from: Data("\"englishJapanese\"".utf8)) == .englishJapanese)
    #expect(L10n.text(RecognitionLanguage.englishJapanese.title, language: .english) == "English + Japanese")
    #expect(L10n.text(RecognitionLanguage.englishJapanese.title, language: .japanese) == "英語・日本語混在")
}

@Test func englishJapaneseVocabularyReadinessDoesNotRequireChinese() throws {
    var library = CustomVocabularyLibrary()
    _ = try library.importLines("队列", language: .chinese)
    _ = try library.importLines("queue", language: .english)
    _ = try library.importLines("キュー", language: .japanese)
    let scope = VocabularyScope(profile: "default", region: "us-west-2")
    for plan in try library.plans() where plan.binding.language != .chinese {
        library.record(.init(plan: plan, scope: scope, bucket: "fixture-bucket", state: .ready))
    }
    #expect(try library.snapshot(language: .englishJapanese, scope: scope)?.bindings.map(\.language) == [.english, .japanese])
    #expect(throws: VocabularyError.self) { try library.snapshot(language: .mixed, scope: scope) }
}

@Test func japaneseVocabularyImportsKanaAndKeepsLanguageScopesSeparate() throws {
    var library = CustomVocabularyLibrary()
    #expect(try library.importLines("アマゾンベッドロック\tAmazon Bedrock\nぎじろく\t議事録\nキュー\tQueue", language: .japanese) == 3)
    #expect(try library.importLines("キュー\tQueue", language: .chinese) == 1)
    let plans = try library.plans()
    #expect(plans.count == 2)
    let plan = try #require(plans.first { $0.binding.language == .japanese })
    #expect(plan.binding.name.contains("-ja-jp-"))
    #expect(String(decoding: plan.table, as: UTF8.self).contains("ぎじろく\t\t\t議事録"))
    #expect(!VocabularyLanguage.japanese.applies(to: .mixed))
    #expect(VocabularyLanguage.japanese.applies(to: .multilingual))
    let scope = VocabularyScope(profile: "default", region: "us-west-2")
    #expect(throws: VocabularyError.self) { try library.snapshot(language: .japanese, scope: scope) }
    for plan in plans { library.record(.init(plan: plan, scope: scope, bucket: "fixture-bucket", state: .ready)) }
    #expect(try library.snapshot(language: .japanese, scope: scope)?.bindings.map(\.language) == [.japanese])
    #expect(try library.snapshot(language: .mixed, scope: scope)?.bindings.map(\.language) == [.chinese])
    #expect(try library.snapshot(language: .multilingual, scope: scope)?.bindings.count == 2)
    let before = library.entries
    #expect(throws: VocabularyError.self) { try library.importLines("ぎじろく\t別表記", language: .japanese) }
    #expect(library.entries == before)
    let decoded = try JSONDecoder().decode(CustomVocabularyLibrary.self, from: JSONEncoder().encode(library))
    #expect(decoded.entries == library.entries)
}

@Test func japaneseLanguagesRoundTripWithoutChangingLegacyMixedMode() throws {
    var settings = AppSettings()
    #expect(settings.language == .mixed)
    settings.language = .japanese; settings.summaryLanguage = SummaryLanguage.japanese.rawValue
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.language == .japanese)
    #expect(decoded.summaryLanguage == "日本語")
    #expect(try JSONDecoder().decode(RecognitionLanguage.self, from: Data("\"mixed\"".utf8)) == .mixed)
    #expect(SummaryTemplate.interview.outputOverviewTitle(language: "日本語") == "面接の概要")
    let custom = SummaryTemplate(name: "Custom", instructions: "Keep title", sections: [.init(title: "My title")])
    #expect(custom.outputTitle(for: custom.sections[0], language: "日本語") == "My title")
}
