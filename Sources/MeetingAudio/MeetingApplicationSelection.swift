import Foundation

/// Selection for one preparation window. Resolve by bundle ID so a restarted client uses its current PID.
public struct MeetingApplicationSelection: Sendable {
    public private(set) var selected: MeetingApplication?
    public private(set) var unavailable: MeetingApplication?
    private var preferred: MeetingApplication?
    private var mayChooseDefault: Bool

    public init(preferred: MeetingApplication? = nil) {
        self.preferred = preferred
        mayChooseDefault = preferred == nil
    }

    public mutating func refresh(applications: [MeetingApplication]) {
        let intended = selected ?? unavailable ?? preferred
        preferred = nil
        if let intended {
            selected = applications.first { $0.id == intended.id }
            unavailable = selected == nil ? intended : nil
        } else if mayChooseDefault {
            selected = applications.first
            mayChooseDefault = selected == nil
        }
    }

    public mutating func select(id: String, applications: [MeetingApplication]) {
        selected = applications.first { $0.id == id }
        unavailable = nil
        preferred = nil
        mayChooseDefault = false
    }
}
