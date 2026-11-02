import AppKit
import SwiftUI
import Testing
@testable import MeetingRecordApp

/// Optional visual smoke test. Saves synthetic content only; never opens the meeting repository.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETINGRECORD_MARKDOWN_SNAPSHOTS"] != nil), arguments: [false, true])
@MainActor func markdownRendersNativeBlocksAndSyntaxColors(dark: Bool) async throws {
    let destination = try #require(ProcessInfo.processInfo.environment["MEETINGRECORD_MARKDOWN_SNAPSHOTS"])
    let markdown = #"""
    # 会议问答 · Markdown

    **重点结论**：支持 *强调*、~~删除线~~、`行内代码` 和 [参考链接](https://example.com)。[O1]

    > 引用：保留原始记录，复核后再确认行动项。

    1. 查看转录与纪要
    2. 确认责任人
       - 子任务：核对日期

    - [x] 保留引用
    - [ ] 完成复核

    | 事项 | 负责人 | 状态 |
    | :--- | :---: | ---: |
    | 转录校对 | 张三 | 已完成 |
    | 纪要复核 | 李四 | 待确认 |

    ## Swift

    ```swift
    // 保留中文与缩进
    let title = "会议记录 📝"
    print(title)
    ```

    ## Python

    ```python
    def greet(name):
        # 注释应与字符串使用不同颜色
        return f"你好，{name}"
    ```

    ```json
    {"ready": true, "count": 42, "title": "会议"}
    ```
    """#
    _ = NSApplication.shared
    let view = ChatMarkdownView(text: markdown)
        .padding(24)
        .frame(width: 700, alignment: .leading)
        .background(dark ? Color.black : Color.white)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let size = host.fittingSize
    #expect(size.width == 700 && size.height > 500 && size.height < 3000)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: image)
    let png = try #require(image.representation(using: .png, properties: [:]))
    let folder = URL(fileURLWithPath: destination, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try png.write(to: folder.appendingPathComponent(dark ? "chat-markdown-dark.png" : "chat-markdown-light.png"))
    window.orderOut(nil)
}
