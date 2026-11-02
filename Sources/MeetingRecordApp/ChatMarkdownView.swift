import AppKit
import SwiftUI
import MarkdownUI
import MeetingCore

/// Native GFM rendering shared by questions, answers and saved minutes excerpts.
/// Parsing and highlighting are local; rendering a message never fetches an image URL.
struct ChatMarkdownView: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    var body: some View {
        Markdown(text)
            .markdownTheme(.gitHub.text {
                FontSize(14)
                ForegroundColor(.primary)
                BackgroundColor(nil)
            }.codeBlock { configuration in
                ChatCodeBlock(configuration: configuration)
            }.table { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: true, vertical: true)
                        .markdownTableBorderStyle(.init(color: .secondary.opacity(0.3)))
                        .markdownTableBackgroundStyle(.alternatingRows(.clear, .secondary.opacity(0.06)))
                }
                .markdownMargin(top: 0, bottom: 16)
            })
            .markdownCodeSyntaxHighlighter(ChatCodeSyntaxHighlighter(dark: colorScheme == .dark))
            .markdownImageProvider(ChatImagePlaceholder(locale: locale))
            .markdownInlineImageProvider(ChatInlineImagePlaceholder())
            .environment(\.openURL, OpenURLAction { url in
                ChatMarkdownLinks.isAllowed(url) ? .systemAction(url) : .discarded
            })
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatCodeBlock: View {
    let configuration: CodeBlockConfiguration
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(ChatSyntaxHighlighting.languageName(configuration.language) ?? L10n.tr("纯文本", locale: locale))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    copied = ChatCodeClipboard.copy(configuration.content)
                } label: {
                    Label(copied ? L10n.tr("已复制", locale: locale) : L10n.tr("复制代码", locale: locale),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(.borderless).font(.caption)
            }.padding(.horizontal, 14).padding(.vertical, 9).textSelection(.disabled)
            Divider()
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: true)
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(13)
                    }
                    .padding(14)
            }
        }
        .background(colorScheme == .dark
            ? Color(red: 40 / 255, green: 44 / 255, blue: 52 / 255)
            : Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.secondary.opacity(0.2), lineWidth: 1))
        .markdownMargin(top: 0, bottom: 16)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }
}

enum ChatCodeClipboard {
    @MainActor @discardableResult
    static func copy(_ code: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(code, forType: .string)
    }
}

enum ChatMarkdownLinks {
    static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https", "http": return url.host?.isEmpty == false && url.user == nil && url.password == nil
        case "mailto": return !url.path.isEmpty
        default: return false
        }
    }
}

private struct ChatImagePlaceholder: ImageProvider {
    let locale: Locale
    func makeImage(url: URL?) -> some View {
        Label(L10n.tr("图片（未加载）", locale: locale), systemImage: "photo")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct ChatInlineImagePlaceholder: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        Image(nsImage: NSImage(systemSymbolName: "photo", accessibilityDescription: label) ?? NSImage())
    }
}
