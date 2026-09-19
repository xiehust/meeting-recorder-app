import Foundation

public struct MeetingDateGroup: Identifiable, Sendable {
    public enum Period: Hashable, Sendable {
        case today, yesterday, lastSevenDays, lastThirtyDays
        case month(Date)
        case day(Date)
    }

    public let id: Period
    public let meetings: [Meeting]

    public var initiallyExpanded: Bool {
        switch id {
        case .today, .yesterday, .lastSevenDays, .day: true
        case .lastThirtyDays, .month: false
        }
    }

    public var showsDateInRows: Bool {
        switch id {
        case .today, .yesterday, .day: false
        case .lastSevenDays, .lastThirtyDays, .month: true
        }
    }

    public func title(locale: Locale, calendar: Calendar) -> String {
        switch id {
        case .today: L10n.text("今天", locale: locale)
        case .yesterday: L10n.text("昨天", locale: locale)
        case .lastSevenDays: L10n.text("近 7 天", locale: locale)
        case .lastThirtyDays: L10n.text("近 30 天", locale: locale)
        case .month(let date):
            date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).year().month(.wide))
        case .day(let date):
            date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale,
                                           calendar: calendar, timeZone: calendar.timeZone))
        }
    }

    /// Non-overlapping calendar-day windows, including today; older meetings are grouped by month.
    public static func group(_ meetings: [Meeting], now: Date = Date(), calendar: Calendar = .current) -> [Self] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let sevenDays = calendar.date(byAdding: .day, value: -6, to: today)!
        let thirtyDays = calendar.date(byAdding: .day, value: -29, to: today)!
        let grouped = Dictionary(grouping: meetings) { meeting -> Period in
            let day = calendar.startOfDay(for: meeting.startedAt)
            if day > today { return .day(day) }
            if day == today { return .today }
            if day == yesterday { return .yesterday }
            if day >= sevenDays { return .lastSevenDays }
            if day >= thirtyDays { return .lastThirtyDays }
            return .month(calendar.dateInterval(of: .month, for: day)!.start)
        }
        return grouped.map { period, meetings in
            Self(id: period, meetings: meetings.sorted {
                $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
            })
        }.sorted { $0.meetings[0].startedAt > $1.meetings[0].startedAt }
    }
}
