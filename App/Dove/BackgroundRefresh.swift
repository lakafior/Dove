import BackgroundTasks
import DoveKit
import Foundation

/// iOS's occasional background time (`BGAppRefreshTask`, about 30 s, when iOS decides; never promised). Dove uses it
/// for what is cheap and only needs metadata: premium days (at most every 6 h), the watchlist's and library's episode
/// lists and movie dates (only stale ones), the watchlist's notices, and the widgets' snapshot. It never lists the
/// services' libraries (Real-Debrid's rate limits, and nothing there needs to be fresh before Dove is opened).
enum BackgroundRefresh {
    static let identifier = "net.smigi.dove.refresh"
    /// iOS treats this as "not before": the real time depends on how the phone is used.
    private static let interval: TimeInterval = 3 * 3600

    /// Call before the app finishes launching. The handler runs on the main queue.
    nonisolated static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            handle(task, model: model)
        }
    }

    nonisolated static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private nonisolated static func handle(_ task: BGTask, model: AppModel) {
        // Only touched here and in the expiration handler, which iOS calls on the same queue.
        nonisolated(unsafe) let task = task
        schedule()
        let work = Task { @MainActor in
            await run(using: model)
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    @MainActor
    private static func run(using app: AppModel) async {
        // A background launch has no scene, so the addons (and TMDB with them) were never loaded.
        if !app.addonSet.canSearch { await app.loadAddons() }
        await app.refreshAccounts()
        guard !Task.isCancelled else { return }
        await app.review.run(using: app)
        guard !Task.isCancelled else { return }
        await app.watchlist.refresh(using: app)
        await WidgetSnapshotWriter.write(using: app)
    }
}
