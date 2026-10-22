import DoveKit
import Foundation

/// Tells the user about phone downloads: a local notification when a file or a download-only job ends
/// (`DownloadNotices`), and the platform's progress outside the app (iOS: one Live Activity while files download).
///
/// No push and no server: the background `URLSession` wakes the app when a file finishes, which is when the
/// notification is posted and the activity updated. While iOS keeps the app suspended mid-download, the session
/// reports no progress, so the activity's bar moves while Dove is open and jumps when a file finishes.
@MainActor
public final class DownloadAlerts {
    private let downloads: DownloadManager
    private let jobs: DownloadJobs
    private let platform: any AppPlatform

    public init(downloads: DownloadManager, jobs: DownloadJobs, platform: any AppPlatform) {
        self.downloads = downloads
        self.jobs = jobs
        self.platform = platform
        downloads.onSettled { [weak self] record in self?.settled(record) }
        jobs.onEnded = { [weak self] job, outcome in self?.post(DownloadNotices.notice(for: job, outcome: outcome), kind: .downloadOnly) }
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
        if records.contains(where: { $0.state == .downloading }) { LocalNotifications.askIfNeeded(for: .downloads) }
        platform.downloadsChanged(records)
    }

    private func settled(_ record: DownloadRecord) {
        // The job is looked up before `DownloadJobs` advances: a finished file still belongs to it here.
        let job = jobs.job(for: record)
        if let notice = DownloadNotices.notice(for: record, job: job) { post(notice, kind: job == nil ? .downloads : .downloadOnly) }
    }

    /// Each kind can be turned off in Settings › Notifications.
    private func post(_ notice: DownloadNotice, kind: NotificationKind) {
        LocalNotifications.post(kind, id: notice.id, title: notice.title, body: notice.body, thread: notice.thread)
    }
}
