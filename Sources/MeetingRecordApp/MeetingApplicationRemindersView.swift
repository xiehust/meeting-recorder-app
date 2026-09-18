import SwiftUI
import MeetingCore
import MeetingAudio

struct MeetingApplicationRemindersView: View {
    @EnvironmentObject var store: AppStore
    private var interfaceLocale: Locale { store.interfaceLocale }
    let applications: [MeetingApplication]
    let mayStart: Bool
    let prepare: (MeetingApplication) -> Void
    let dismiss: () -> Void

    var body: some View {
        let interfaceLocale = self.interfaceLocale
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.tr("检测到 \(applications.count) 个会议应用正在运行", locale: interfaceLocale), systemImage: "video.badge.waveform")
                    .font(.callout).fontWeight(.medium)
                Spacer()
                Button(L10n.tr("暂不提醒", locale: interfaceLocale), action: dismiss)
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.tr("选择本次要记录的应用", locale: interfaceLocale)).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(applications) { application in
                    Button { prepare(application) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "video").foregroundStyle(.teal)
                            Text(application.name).lineLimit(1).foregroundStyle(Color.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Color.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered).disabled(!mayStart)
                    .help(L10n.tr("准备记录 \(application.name)", locale: interfaceLocale))
                    .accessibilityLabel(L10n.tr("准备记录 \(application.name)", locale: interfaceLocale))
                }
            }
        }.padding(14).background(.teal.opacity(0.08))
    }
}
