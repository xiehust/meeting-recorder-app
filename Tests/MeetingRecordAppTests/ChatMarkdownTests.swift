import AppKit
import SwiftUI
import Testing
@testable import MeetingRecordApp

@Suite struct ChatMarkdownTests {
    private func colors(_ text: NSAttributedString) -> Set<String> {
        var result = Set<String>()
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let color = value as? NSColor, let rgb = color.usingColorSpace(.sRGB) {
                result.insert("\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent)")
            }
        }
        return result
    }

    @Test(arguments: ["swift", "python", "javascript", "typescript", "json", "bash", "sql", "yaml"])
    func supportedCodeHasColorsAndPreservesEveryCharacter(language: String) {
        let examples = [
            "swift": "// 注释\nlet title = \"会议 📝\"\nprint(title)",
            "python": "# 注释\ndef greet(name):\n    return f\"你好 {name}\"\n",
            "javascript": "// 注释\nconst title = \"会议\";\nconsole.log(title);",
            "typescript": "// 注释\nconst count: number = 42;\nconsole.log(count);",
            "json": "{\"title\": \"会议\", \"count\": 42, \"ready\": true}",
            "bash": "#!/bin/bash\n# 注释\nprintf '%s\\n' \"会议\"",
            "sql": "-- 注释\nSELECT name FROM meetings WHERE id = 42;",
            "yaml": "# 注释\ntitle: \"会议\"\nready: true\ncount: 42"
        ]
        let code = examples[language]!
        for dark in [false, true] {
            let result = ChatSyntaxHighlighting.shared.highlight(code, language: language, dark: dark)
            #expect(result.string.utf8.elementsEqual(code.utf8))
            #expect(colors(result).count >= 2, "No syntax colors for \(language), dark=\(dark)")
            let display = ChatSyntaxHighlighting.displayText(result)
            #expect(display.runs.contains(where: { $0.swiftUI.foregroundColor != nil }))
            #expect(String(display.characters).utf8.elementsEqual(code.utf8))
        }
    }

    @Test func darkAndLightResultsUseDifferentColorsAndCacheCorrectly() {
        let code = "let message = \"hello\""
        let renderer = ChatSyntaxHighlighting()
        let light = renderer.highlight(code, language: "swift", dark: false)
        let dark = renderer.highlight(code, language: "swift", dark: true)
        #expect(colors(light) != colors(dark))
        #expect(renderer.highlight(code, language: "swift", dark: false).isEqual(to: light))
    }

    @Test func missingUnknownAndLargeLanguagesFallbackWithoutChangingCode() {
        let code = "<script>alert('test')</script>\n& \" </span> 📝\t会议\n"
        for language: String? in [nil, "", "unknown-language", "text"] {
            let result = ChatSyntaxHighlighting.shared.highlight(code, language: language, dark: false)
            #expect(result.string.utf8.elementsEqual(code.utf8))
            #expect(colors(result).isEmpty)
        }
        let large = String(repeating: "let a = 1\n", count: 10_000)
        let result = ChatSyntaxHighlighting.shared.highlight(large, language: "swift", dark: false)
        #expect(result.string == large && colors(result).isEmpty)
        #expect(ChatSyntaxHighlighting.languageName("PY title=example.py") == "python")
        #expect(ChatSyntaxHighlighting.languageName("ts") == "typescript")
    }

    @Test @MainActor func copyingCodePreservesIndentationAndUnicode() {
        let pasteboard = NSPasteboard(name: .init("MeetingRecordTest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let code = "  let text = \"原文 📝\"\n\tprint(text)\n"
        #expect(ChatCodeClipboard.copy(code, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == code)
    }

    @Test func linksCannotLaunchFilesScriptsOrOtherApplications() {
        for raw in ["https://example.com/docs?q=markdown", "http://example.com", "mailto:hello@example.com"] {
            #expect(ChatMarkdownLinks.isAllowed(URL(string: raw)!))
        }
        for raw in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,test", "x-apple.systempreferences:settings", "#O1", "https://user:password@example.com"] {
            #expect(!ChatMarkdownLinks.isAllowed(URL(string: raw)!))
        }
    }

    @Test func inlineImagesReturnLocalPlaceholderEvenForUnreachableURLs() async throws {
        _ = try await ChatInlineImagePlaceholder().image(with: URL(string: "https://192.0.2.1/private-image")!, label: "image")
    }
}
