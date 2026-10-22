import ActivityKit
import DoveAppCore
import DoveKit
import Foundation
import MediaPlayer
import UIKit

/// The iOS side of `AppPlatform`: system services through UIKit, and the integrations iOS has (the Files location,
/// Spotlight, widgets, the downloads' Live Activity, Siri suggestions). Owns the router the tabs follow.
@MainActor
final class IOSPlatform: AppPlatform {
    let router = AppRouter()
    private let activity = DownloadActivityController()

    /// Documents, which Files shows under On My iPhone › Dove.
    var downloadsDirectory: URL { .documentsDirectory }

    func canOpen(_ url: URL) -> Bool { UIApplication.shared.canOpenURL(url) }

    func open(_ url: URL) async -> Bool { await UIApplication.shared.open(url) }

    func show(_ destination: AppModel.Destination) { router.show(destination) }

    func libraryChanged() { FilesLocation.libraryChanged() }

    func servicesChanged(hasServices: Bool) async { await FilesLocation.update(hasServices: hasServices) }

    func libraryUpdated(_ app: AppModel) {
        SpotlightIndex.update(using: app)
        WidgetSnapshotWriter.update(using: app)
    }

    func accountsUpdated(_ app: AppModel) { WidgetSnapshotWriter.update(using: app) }

    func downloadsChanged(_ records: [DownloadRecord]) {
        activity.update(NotificationKind.liveActivity.isOn ? records : [])
    }

    func audiobookStarted() { SiriSuggestions.listened() }

    func nowPlayingArtwork(from data: Data) -> MPMediaItemArtwork? {
        UIImage(data: data).map(Self.artwork)
    }

    /// Built outside the main actor: the system asks for the image on a background queue, and a closure made in a
    /// main-actor method would trap there.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
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
