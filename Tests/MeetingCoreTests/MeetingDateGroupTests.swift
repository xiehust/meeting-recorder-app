import Foundation
import Testing
@testable import MeetingCore

private func libraryCalendar(_ zone: String = "Asia/Shanghai") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private func libraryDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func libraryMeeting(_ date: Date) -> Meeting {
    Meeting(title: "日期分区测试", applicationName: "Teams", bundleID: "teams", microphoneName: "mic", settings: .init(), now: date)
}

@Test func librarySectionsCoverWeekMonthAndOlderYearsWithoutOverlaps() throws {
    let calendar = libraryCalendar()
    let now = libraryDate("2026-09-18T12:00:00+08:00")
    let dates = ["2026-09-18T11:00:00+08:00", "2026-09-18T09:00:00+08:00", "2026-09-17T23:59:00+08:00",
                 "2026-09-12T00:00:00+08:00", "2026-09-11T23:59:00+08:00", "2026-08-20T00:00:00+08:00",
                 "2026-08-19T23:59:00+08:00", "2026-07-01T10:00:00+08:00", "2025-07-01T10:00:00+08:00"]
    let meetings = dates.map { libraryMeeting(libraryDate($0)) }
    let groups = MeetingDateGroup.group(Array(meetings.reversed()), now: now, calendar: calendar)
    #expect(groups.map(\.id) == [.today, .yesterday, .lastSevenDays, .lastThirtyDays,
        .month(libraryDate("2026-08-01T00:00:00+08:00")), .month(libraryDate("2026-07-01T00:00:00+08:00")),
        .month(libraryDate("2025-07-01T00:00:00+08:00"))])
    #expect(groups.map { $0.meetings.count } == [2, 1, 1, 2, 1, 1, 1])
    #expect(groups.flatMap(\.meetings).map(\.id) == meetings.map(\.id))
    #expect(groups[3].showsDateInRows)
    #expect(!groups[0].showsDateInRows)
    #expect(!groups[4].initiallyExpanded)
    #expect(groups[0].initiallyExpanded)
    #expect(groups[4].title(locale: Locale(identifier: "zh-CN"), calendar: calendar).contains("2026"))
    #expect(groups[6].title(locale: Locale(identifier: "en-US"), calendar: calendar).contains("2025"))
}

@Test func libraryUsesLocalCalendarDaysAcrossMidnightAndDaylightSaving() throws {
    let now = libraryDate("2026-09-18T00:30:00+08:00")
    let meeting = libraryMeeting(libraryDate("2026-09-17T23:59:00+08:00"))
    #expect(MeetingDateGroup.group([meeting], now: now, calendar: libraryCalendar()).first?.id == .yesterday)
    #expect(MeetingDateGroup.group([meeting], now: now, calendar: libraryCalendar("UTC")).first?.id == .today)

    let springNow = libraryDate("2026-03-09T00:30:00-07:00")
    let beforeClockChange = libraryMeeting(libraryDate("2026-03-07T23:45:00-08:00"))
    let yesterday = libraryMeeting(libraryDate("2026-03-08T00:15:00-08:00"))
    let groups = MeetingDateGroup.group([beforeClockChange, yesterday], now: springNow, calendar: libraryCalendar("America/Los_Angeles"))
    #expect(groups.map(\.id) == [.yesterday, .lastSevenDays])
}

@Test func libraryOmitsEmptySectionsAndRetainsOnlyTheFilteredMeetings() {
    let now = libraryDate("2026-09-18T12:00:00+08:00")
    let old = libraryMeeting(libraryDate("2024-01-03T10:00:00+08:00"))
    let groups = MeetingDateGroup.group([old], now: now, calendar: libraryCalendar())
    #expect(groups.count == 1)
    #expect(groups.first?.meetings.first?.id == old.id)
    #expect(MeetingDateGroup.group([], now: now, calendar: libraryCalendar()).isEmpty)
    let future = libraryMeeting(libraryDate("2026-09-20T10:00:00+08:00"))
    #expect(MeetingDateGroup.group([old, future], now: now, calendar: libraryCalendar()).first?.id
        == .day(libraryDate("2026-09-20T00:00:00+08:00")))
}
