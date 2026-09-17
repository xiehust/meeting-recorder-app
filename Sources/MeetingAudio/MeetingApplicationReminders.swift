import Foundation

/// All running clients remain available until explicitly dismissed or they exit.
public struct MeetingApplicationReminders: Sendable {
    public private(set) var applications: [MeetingApplication] = []
    private var dismissedProcesses: [String: Int32] = [:]

    public init() {}

    public mutating func refresh(applications running: [MeetingApplication], enabled: Bool) {
        dismissedProcesses = dismissedProcesses.filter { entry in
            running.contains { $0.id == entry.key && $0.pid == entry.value }
        }
        var included = Set<String>()
        applications = enabled ? running.filter {
            dismissedProcesses[$0.id] != $0.pid && included.insert($0.id).inserted
        } : []
    }

    public mutating func dismissAll() {
        for application in applications { dismissedProcesses[application.id] = application.pid }
        applications = []
    }
}
