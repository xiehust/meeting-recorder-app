import Testing
@testable import MeetingAudio

@Test func meetingClientDiscoveryPreservesIdentityForCaptureAndResume() throws {
    let clients = [
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("us.zoom.xos", "Zoom"),
        ("com.bytedance.macos.feishu", "飞书"),
        ("com.tencent.meeting", "腾讯会议"),
        ("5ZSL2CJU2T.com.dingtalk.mac", "钉钉")
    ]
    for (bundleID, name) in clients {
        let app = try #require(MeetingApplication.recognized(bundleID: bundleID, localizedName: name, pid: 123))
        #expect(app.id == bundleID)
        #expect(app.name == name)
        #expect(app.pid == 123)
        #expect(MeetingApplication.recognized(bundleID: bundleID, localizedName: nil, pid: 123)?.name == name)
    }
    #expect(MeetingApplication.recognized(bundleID: "com.bytedance.macos.feishu",
                                         localizedName: "Lark", pid: 456)?.name == "Lark")
}

@Test func meetingClientDiscoveryExcludesHelpersOtherVendorAppsAndBrowsers() {
    for bundleID in [
        "com.bytedance.macos.feishu.helper", "com.bytedance.macos.feishu.iron",
        "com.bytedance.macos.feishu-notifier", "com.bytedance.macos.feishu-copy",
        "com.tencent.meeting.services.wmexternal", "com.tencent.meeting.Transcode",
        "com.tencent.meeting-copy", "com.tencent.xinWeChat", "com.tencent.wemeet.FileDelta",
        "5ZSL2CJU2T.com.dingtalk.mac.tblive", "5ZSL2CJU2T.com.dingtalk.mac-copy",
        "com.dingtalk.mac", "com.alibaba.DingTalk",
        "us.zoom.xos.helper", "com.microsoft.teams2.helper", "com.apple.Safari", "com.google.Chrome", ""
    ] {
        #expect(MeetingApplication.recognized(bundleID: bundleID, localizedName: "飞书 / 腾讯会议", pid: 123) == nil)
    }
    #expect(MeetingApplication.recognized(bundleID: nil, localizedName: "TencentMeeting", pid: 123) == nil)
}
