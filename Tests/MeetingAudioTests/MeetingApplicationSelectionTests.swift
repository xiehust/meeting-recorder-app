import Testing
@testable import MeetingAudio

private let teams = MeetingApplication(id: "com.microsoft.teams2", name: "Microsoft Teams", pid: 100)
private let zoom = MeetingApplication(id: "us.zoom.xos", name: "Zoom", pid: 200)
private let feishu = MeetingApplication(id: "com.bytedance.macos.feishu", name: "Feishu", pid: 300)
private let tencent = MeetingApplication(id: "com.tencent.meeting", name: "腾讯会议", pid: 400)
private let dingTalk = MeetingApplication(id: "5ZSL2CJU2T.com.dingtalk.mac", name: "钉钉", pid: 500)
private let clients = [feishu, teams, zoom, tencent, dingTalk]

@Test func openingFromEachMeetingReminderSelectsThatClientInsteadOfTheFirstApp() {
    for client in clients {
        var selection = MeetingApplicationSelection(preferred: client)
        selection.refresh(applications: clients)
        #expect(selection.selected == client)
        #expect(selection.unavailable == nil)
    }
}

@Test func deviceRefreshPreservesManualSelectionAndExplicitlyClearedSelection() {
    var selection = MeetingApplicationSelection(preferred: teams)
    selection.refresh(applications: clients)
    selection.select(id: tencent.id, applications: clients)
    selection.refresh(applications: Array(clients.reversed()))
    #expect(selection.selected == tencent)
    selection.select(id: "", applications: clients)
    selection.refresh(applications: clients)
    #expect(selection.selected == nil)
    #expect(selection.unavailable == nil)
}

@Test func unavailableReminderNeverFallsBackToAnotherRunningMeetingClient() {
    var selection = MeetingApplicationSelection(preferred: dingTalk)
    selection.refresh(applications: [feishu, teams, zoom])
    #expect(selection.selected == nil)
    #expect(selection.unavailable == dingTalk)
    selection.refresh(applications: [tencent, teams])
    #expect(selection.selected == nil)
    selection.refresh(applications: clients)
    #expect(selection.selected == dingTalk)
    #expect(selection.unavailable == nil)
}

@Test func appExitClearsSelectionAndRestartUsesCurrentProcessIdentity() {
    var selection = MeetingApplicationSelection(preferred: zoom)
    selection.refresh(applications: clients)
    selection.select(id: teams.id, applications: clients)
    selection.refresh(applications: [zoom])
    #expect(selection.selected == nil)
    #expect(selection.unavailable == teams)
    let restarted = MeetingApplication(id: teams.id, name: teams.name, pid: 900)
    selection.refresh(applications: [zoom, restarted])
    #expect(selection.selected == restarted)
    #expect(selection.unavailable == nil)
}

@Test func reminderResolvesFreshPIDAndSeparatePreparationDoesNotReusePreviousSelection() {
    let restarted = MeetingApplication(id: dingTalk.id, name: dingTalk.name, pid: 800)
    var firstWindow = MeetingApplicationSelection(preferred: dingTalk)
    firstWindow.refresh(applications: [feishu, restarted])
    #expect(firstWindow.selected == restarted)
    var secondWindow = MeetingApplicationSelection(preferred: tencent)
    secondWindow.refresh(applications: clients)
    #expect(secondWindow.selected == tencent)
}

@Test func manualStartWithoutReminderCanDefaultOnceAnApplicationAppears() {
    var selection = MeetingApplicationSelection()
    selection.refresh(applications: [])
    #expect(selection.selected == nil)
    #expect(selection.unavailable == nil)
    selection.refresh(applications: [zoom])
    #expect(selection.selected == zoom)
    selection.refresh(applications: [teams, zoom])
    #expect(selection.selected == zoom)
}

@Test func multipleRunningClientsRequireUserChoiceWithoutAnExplicitReminderSelection() {
    var selection = MeetingApplicationSelection()
    selection.refresh(applications: clients)
    #expect(selection.selected == nil)
    #expect(selection.unavailable == nil)
    selection.refresh(applications: [teams])
    #expect(selection.selected == nil)
    selection.select(id: tencent.id, applications: clients)
    selection.refresh(applications: Array(clients.reversed()))
    #expect(selection.selected == tencent)
}
