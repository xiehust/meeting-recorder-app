import SwiftUI
import AppKit
import MeetingCore

@main
struct MeetingRecordApp: App {
    @StateObject private var store = AppStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("会议记录", id: "main") {
            ContentView().environmentObject(store)
                .onAppear { delegate.store = store }
                .frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会议记录…") { store.prepareToStart() }
                    .keyboardShortcut("n").disabled(!store.mayStart)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.showSettings = true }.keyboardShortcut(",")
            }
        }
        MenuBarExtra {
            MenuPanel().environmentObject(store)
        } label: {
            Label(store.active?.status.title ?? store.processingMeeting?.status.title ?? "会议记录",
                  systemImage: store.active == nil ? "waveform" : "record.circle.fill")
        }.menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if store.active == nil && !store.starting && !store.hasAIProcessing {
            Task { await store.flush(); sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        let alert = NSAlert()
        alert.messageText = store.active == nil ? "中断处理并退出？" : "结束当前记录并退出？"
        alert.informativeText = "已保存的资料和版本会保留。退出停止录音和本地等待；已提交的 AWS 批量任务可能仍在运行并计费，可稍后继续。"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "结束并退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        Task {
            await store.finish(automaticallyProcess: false)
            await store.cancelAllAI()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MenuPanel: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("会议记录", systemImage: "waveform").font(.headline)
            if let meeting = store.active {
                Text(meeting.title).font(.title3)
                HStack {
                    StatusPill(status: meeting.status)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(TimeLabel.format(meeting.offset(at: context.date))).monospacedDigit()
                    }
                }
                HStack {
                    Button(meeting.status == .paused ? "恢复" : "暂停") {
                        if meeting.status == .paused { store.resume() } else { store.pause() }
                    }.disabled(meeting.status == .finalizing)
                    Button("结束记录") { Task { await store.finish() } }.disabled(meeting.status == .finalizing)
                }
                MicrophoneToggleButton()
                Text("本应用麦克风：\(store.captureStates[.microphone] ?? "等待")")
                    .font(.caption).foregroundStyle(.secondary)
                Text("与会议软件静音独立。").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("未记录 · 等待你开始").foregroundStyle(.secondary)
                if let processing = store.processingMeeting {
                    Text("\(processing.title) · \(processing.status.title)").font(.caption).foregroundStyle(.teal)
                }
                Button("开始记录…") { showMain(); store.prepareToStart() }.disabled(!store.mayStart)
            }
            Divider()
            Button("打开会议与历史") { showMain() }
            Button("设置…") { showMain(); store.showSettings = true }
            Button("退出") { NSApp.terminate(nil) }
        }.padding(20).frame(width: 280).buttonStyle(.bordered)
    }
    private func showMain() {
        openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
    }
}

struct MicrophoneToggleButton: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Button {
            Task { await store.toggleMicrophone() }
        } label: {
            Label(store.microphoneEnabled ? "静音麦克风" : "取消静音",
                  systemImage: store.microphoneEnabled ? "mic.slash" : "mic")
        }
        .disabled(store.active?.status != .recording || store.changingMicrophone)
        .accessibilityLabel(store.microphoneEnabled ? "静音本应用麦克风" : "取消本应用麦克风静音")
        .help("只停止或恢复本应用的麦克风采集，不改变会议软件的静音状态。静音前已发送的音频仍可能返回转录。")
    }
}
