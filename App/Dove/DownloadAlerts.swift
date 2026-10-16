import ActivityKit
import DoveKit
import Foundation
import UserNotifications

/// Tells the user about phone downloads: a local notification when a file or a download-only job ends
/// (`DownloadNotices`), and one Live Activity while files are downloading.
///
/// No push and no server: the background `URLSession` wakes the app when a file finishes, which is when the
/// notification is posted and the activity updated. While iOS keeps the app suspended mid-download, the session
/// reports no progress, so the activity's bar moves while Dove is open and jumps when a file finishes.
@MainActor
final class DownloadAlerts {
    private let downloads: DownloadManager
    private let jobs: DownloadJobs
    private let activity = DownloadActivityController()
    private var askedForPermission = false

    init(downloads: DownloadManager, jobs: DownloadJobs) {
        self.downloads = downloads
        self.jobs = jobs
        downloads.onSettled { [weak self] record in self?.settled(record) }
        jobs.onEnded = { [weak self] job, outcome in self?.post(DownloadNotices.notice(for: job, outcome: outcome)) }
        observe()
    }

    /// Re-armed after every change: `withObservationTracking` fires once.
    private func observe() {
        let records = withObservationTracking {
            downloads.records
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        recordsChanged(records)
    }

    private func recordsChanged(_ records: [DownloadRecord]) {
        if records.contains(where: { $0.state == .downloading }) { askForPermission() }
        activity.update(records)
    }

    private func settled(_ record: DownloadRecord) {
        // The job is looked up before `DownloadJobs` advances: a finished file still belongs to it here.
        if let notice = DownloadNotices.notice(for: record, job: jobs.job(for: record)) { post(notice) }
    }

    /// Asked once, at the first download: that is when a notification is worth something.
    private func askForPermission() {
        guard !askedForPermission else { return }
        askedForPermission = true
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    private func post(_ notice: DownloadNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.threadIdentifier = notice.thread
        content.sound = .default
        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// One Live Activity for every phone download: started with the first running download (only possible while the
/// app is in front, which is when downloads start), ended when none is left.
@MainActor
private final class DownloadActivityController {
    typealias Content = ActivityContent<DownloadActivitySummary>

    /// Kept by ID: `Activity` is not `Sendable`, so updates look it up off the main actor (`push`).
    private var activityID: String?
    private var covering: Set<DownloadRecord.ID> = []
    private var shown: DownloadActivitySummary?

    init() {
        // After a relaunch: pick up the activity a previous run started.
        let running = Activity<DownloadActivityAttributes>.activities.first
        activityID = running?.id
        shown = running?.content.state
    }

    func update(_ records: [DownloadRecord]) {
        let running = records.filter { $0.state == .downloading }.map(\.id)
        guard let activityID else {
            guard !running.isEmpty, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            covering = Set(running)
            let summary = DownloadActivitySummary(records: records, covering: covering)
            self.activityID = try? Activity.request(attributes: DownloadActivityAttributes(), content: Self.content(summary)).id
            shown = summary
            return
        }
        covering.formUnion(running)
        let summary = DownloadActivitySummary(records: records, covering: covering)
        if summary.isDone {
            // Stays on the Lock Screen a few minutes with the final count, then goes.
            self.activityID = nil
            covering = []
            shown = nil
            Task { await Self.push(Self.content(summary), to: activityID, ending: true) }
        } else if shown.map(summary.differs) ?? true {
            shown = summary
            Task { await Self.push(Self.content(summary), to: activityID, ending: false) }
        }
    }

    private nonisolated static func push(_ content: Content, to id: String, ending: Bool) async {
        guard let activity = Activity<DownloadActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        if ending {
            await activity.end(content, dismissalPolicy: .after(.now + 5 * 60))
        } else {
            await activity.update(content)
        }
    }

    /// Stale after a while without news: the Lock Screen then says the numbers may be old.
    private static func content(_ summary: DownloadActivitySummary) -> Content {
        ActivityContent(state: summary, staleDate: summary.isDone ? nil : .now + 10 * 60)
    }
}
