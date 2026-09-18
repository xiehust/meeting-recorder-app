import Foundation
import Testing
@testable import MeetingCore

@Suite struct LocalizationTests {
    @Test func systemLanguageResolution() {
        #expect(AppLanguage.system.resolved(preferredLanguages: ["ja-JP", "en-US"]) == .japanese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh_Hant_TW", "en"]) == .chinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "ja"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "ja-JP"]) == .japanese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["de-DE"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: []) == .english)
        #expect(AppLanguage.chinese.resolved(preferredLanguages: ["en-US"]) == .chinese)
        #expect(AppLanguage.english.resolved(preferredLanguages: ["ja-JP"]) == .english)
        #expect(AppLanguage.japanese.resolved(preferredLanguages: ["zh-CN"]) == .japanese)
        #expect(AppLanguage.system.title(locale: Locale(identifier: "ja-JP")) == "システムに合わせる")
        #expect(L10n.text(RecognitionLanguage.mixed.title, locale: Locale(identifier: "ja-JP")) == "中国語・英語混在")
        #expect(L10n.text(RecognitionLanguage.mixed.title, locale: Locale(identifier: "en-US")) == "Chinese + English")
    }

    @Test func packagedCatalogIsCompleteAndInterpolationsMatch() throws {
        #expect(L10n.catalog.count > 650)
        let pattern = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func placeholders(_ text: String) -> [String] {
            pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range) }.sorted()
        }
        for (key, translations) in L10n.catalog {
            for language in [AppLanguage.english, .japanese] {
                let translated = try #require(translations[language.rawValue], "Missing \(language): \(key)")
                #expect(!translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(!translated.contains("\u{FFFD}"))
                #expect(placeholders(key) == placeholders(translated), "Placeholder mismatch: \(key)")
            }
            #expect(L10n.text(key, language: .chinese) == key)
        }
    }

    @Test func interpolationPreservesUserContentLiterally() {
        let note = "会议记录 {1} %@ $HOME **日本語** [link](#ref)\n中文"
        #expect(L10n.tr("人工备注 · \(note)", language: .english) == "Manual note · " + note)
        #expect(L10n.tr("人工备注 · \(note)", language: .japanese) == "手動メモ · " + note)
        #expect(L10n.tr("人工备注 · \(note)", language: .chinese) == "人工备注 · " + note)
        #expect(L10n.tr("\(7) 位发言人", language: .english) == "Speakers: 7")
        #expect(L10n.tr("\(7) 位发言人", language: .japanese) == "話者：7 人")
        #expect(L10n.text("Unknown future label", language: .japanese) == "Unknown future label")
    }

    @Test func storedDiagnosticsLocalizeWithoutRewritingHistory() {
        let message = "创建词汇表失败（profile：test-profile，区域：us-west-2）。\nAWS 访问凭证无效或已过期。请重新登录或更新所选 profile 的凭证。"
        let english = L10n.message(message, language: .english)
        #expect(english.contains("Create vocabulary failed"))
        #expect(english.contains("test-profile"))
        #expect(english.contains("us-west-2"))
        #expect(english.contains("invalid or expired"))
        #expect(L10n.message("批量转录 V12", language: .japanese) == "バッチ文字起こし V12")
        #expect(L10n.message("中文 4 条", language: .english) == "Chinese · Entries: 4")
        #expect(L10n.message("批量结果已保存，请复核后采用。 部分云端文件未清理，可重试清理。", language: .english)
            == "Batch results saved. Review them before adopting. Some cloud files were not cleaned up. You can retry cleanup.")
        #expect(L10n.message("英文错误 from AWS", language: .english) == "英文错误 from AWS")
        #expect(L10n.message(message, language: .chinese) == message)
    }

    @Test func interfaceDisplayDoesNotChangeMeetingOrTemplateSnapshots() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let custom = SummaryTemplate(name: "会议记录", instructions: "原文", sections: [.init(title: "主要议题")])
        #expect(custom.displayName == custom.name)
        #expect(custom.displayInstructions == custom.instructions)
        #expect(custom.displaySectionTitles == custom.sections.map(\.title))
        let before = try encoder.encode(SummaryTemplate.builtIns)
        for template in SummaryTemplate.builtIns {
            _ = template.displayName; _ = template.displayInstructions; _ = template.displaySectionTitles
        }
        #expect(try encoder.encode(SummaryTemplate.builtIns) == before)
        let settings = AppSettings()
        let data = try encoder.encode(settings)
        #expect(!(String(decoding: data, as: UTF8.self)).contains(AppLanguage.preferenceKey))
        #expect(settings.summaryLanguage == "中文")
        #expect(settings.language == .mixed)
    }
}
