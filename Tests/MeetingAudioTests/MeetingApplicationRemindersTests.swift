import Testing
@testable import MeetingAudio

private let clients = [
    MeetingApplication(id: "com.bytedance.macos.feishu", name: "Feishu", pid: 100),
    MeetingApplication(id: "com.microsoft.teams2", name: "Microsoft Teams", pid: 200),
    MeetingApplication(id: "us.zoom.xos", name: "Zoom", pid: 300),
    MeetingApplication(id: "com.tencent.meeting", name: "腾讯会议", pid: 400),
    MeetingApplication(id: "5ZSL2CJU2T.com.dingtalk.mac", name: "钉钉", pid: 500)
]

@Test func allRunningMeetingClientsAppearTogetherAndEachCanBeSelected() {
    var reminders = MeetingApplicationReminders()
    reminders.refresh(applications: clients, enabled: true)
    #expect(reminders.applications == clients)
    for application in reminders.applications {
        var selection = MeetingApplicationSelection(preferred: application)
        selection.refresh(applications: clients)
        #expect(selection.selected == application)
    }
    reminders.refresh(applications: clients, enabled: true)
    #expect(reminders.applications == clients)
}

@Test func meetingRemindersFollowLaunchExitAndCurrentProcessIdentity() {
    var reminders = MeetingApplicationReminders()
    reminders.refresh(applications: Array(clients.prefix(2)), enabled: true)
    #expect(reminders.applications.count == 2)
    reminders.refresh(applications: clients, enabled: true)
    #expect(reminders.applications.count == 5)
    let restarted = MeetingApplication(id: clients[1].id, name: clients[1].name, pid: 900)
    reminders.refresh(applications: [restarted, clients[2]], enabled: true)
    #expect(reminders.applications == [restarted, clients[2]])
    reminders.refresh(applications: [], enabled: true)
    #expect(reminders.applications.isEmpty)
}

@Test func dismissingCurrentRemindersDoesNotHideNewClientsOrRestartedClients() {
    var reminders = MeetingApplicationReminders()
    reminders.refresh(applications: Array(clients.prefix(2)), enabled: true)
    reminders.dismissAll()
    reminders.refresh(applications: clients, enabled: true)
    #expect(reminders.applications == Array(clients.dropFirst(2)))
    reminders.refresh(applications: [clients[2]], enabled: true)
    reminders.refresh(applications: [clients[0], clients[2]], enabled: true)
    #expect(reminders.applications == [clients[0], clients[2]])
    reminders.dismissAll()
    let restarted = MeetingApplication(id: clients[0].id, name: clients[0].name, pid: 900)
    reminders.refresh(applications: [restarted, clients[2]], enabled: true)
    #expect(reminders.applications == [restarted])
}

@Test func disablingRemindersHidesTheListAndDuplicateInstancesDoNotDuplicateButtons() {
    var reminders = MeetingApplicationReminders()
    reminders.refresh(applications: clients, enabled: false)
    #expect(reminders.applications.isEmpty)
    reminders.refresh(applications: clients + [clients[0]], enabled: true)
    #expect(reminders.applications == clients)
}
