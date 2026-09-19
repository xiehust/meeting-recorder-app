import SwiftUI
import MeetingCore

struct MeetingLibraryList: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @State private var expansion: [MeetingDateGroup.Period: Bool] = [:]
    @State private var searchExpansion: [MeetingDateGroup.Period: Bool] = [:]
    let meetings: [Meeting]
    let search: String
    let onDelete: (Meeting) -> Void

    private var localCalendar: Calendar {
        var value = calendar
        value.timeZone = timeZone
        return value
    }

    var body: some View {
        // Re-evaluate relative groups when an open window crosses midnight.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let groups = MeetingDateGroup.group(meetings, now: context.date, calendar: localCalendar)
            let selectedGroup = groups.first { $0.meetings.contains { $0.id == store.selection } }?.id
            List(selection: $store.selection) {
                ForEach(groups) { group in
                    Section(isExpanded: Binding(
                        get: {
                            search.isEmpty ? (expansion[group.id] ?? (group.initiallyExpanded || group.id == selectedGroup))
                                : (searchExpansion[group.id] ?? true)
                        },
                        set: { setExpanded($0, for: group.id) }
                    )) {
                        ForEach(group.meetings) { meeting in
                            row(meeting, showsDate: group.showsDateInRows)
                        }
                    } header: {
                        HStack {
                            Text(group.title(locale: store.interfaceLocale, calendar: localCalendar))
                            Spacer()
                            Text("\(group.meetings.count)").monospacedDigit().foregroundStyle(.tertiary)
                        }.font(.caption.weight(.semibold))
                    }
                }
            }.listStyle(.sidebar)
                .onChange(of: search) { _, value in
                    searchExpansion = [:]
                    if value.isEmpty, let selectedGroup { expansion[selectedGroup] = true }
                }
                .onChange(of: selectedGroup, initial: true) { _, value in
                    if let value { setExpanded(true, for: value) }
                }
                .onChange(of: store.selection) { _, _ in
                    if let selectedGroup { setExpanded(true, for: selectedGroup) }
                }
        }
    }

    private func setExpanded(_ value: Bool, for period: MeetingDateGroup.Period) {
        if search.isEmpty { expansion[period] = value }
        else { searchExpansion[period] = value }
    }

    private func row(_ meeting: Meeting, showsDate: Bool) -> some View {
        let locale = store.interfaceLocale
        let time = Date.FormatStyle(locale: locale, calendar: localCalendar, timeZone: timeZone).hour().minute()
        return VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
            HStack(spacing: 6) {
                Circle().fill(meeting.status == .recording ? Color.red : Color.teal.opacity(0.6)).frame(width: 5, height: 5)
                Text(L10n.text(meeting.status.title, locale: locale))
                Spacer()
                Text(meeting.startedAt, format: showsDate ? time.month(.twoDigits).day(.twoDigits) : time)
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 7).tag(meeting.id)
            .contextMenu {
                Button(L10n.tr("删除本地资料", locale: locale), role: .destructive) { onDelete(meeting) }
                    .disabled(meeting.status.isActive || store.isProcessing(meeting.id))
            }
    }
}
