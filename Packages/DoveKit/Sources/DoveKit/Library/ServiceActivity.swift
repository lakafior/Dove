import Foundation

/// What the services are still fetching, for the Downloads tab: torrents without cache, NZB jobs, hoster links.
/// Built from the library list Dove already has; it costs no calls of its own.
public struct ServiceActivity: Sendable, Equatable {
    /// Queued, downloading or waiting for the user to choose files. Files to choose first, then newest.
    public var active: [ShelfItem]
    /// Failed lately, so the user sees what did not make it (missing articles, dead torrents).
    public var failed: [ShelfItem]

    /// How long a failed item stays in the Downloads tab. Older ones live on in the Library only.
    public static let failedWindow: TimeInterval = 3 * 86_400
    /// How often the Downloads tab lists the services again while something is active and the tab is open.
    /// Real-Debrid allows 250 requests a minute; one refresh is one list call per service.
    public static let pollInterval: TimeInterval = 20

    public var isEmpty: Bool { active.isEmpty && failed.isEmpty }

    /// - Parameter jobs: download-only jobs; their items already have a row of their own.
    public init(items: [ShelfItem], jobs: [DownloadJob] = [], now: Date = .now) {
        let owned = Set(jobs.map { ShelfItem.id(backend: $0.backend, itemID: $0.itemID) })
        let newestFirst = items
            .filter { !owned.contains($0.id) }
            .sorted { ($0.item.addedAt ?? .distantPast) > ($1.item.addedAt ?? .distantPast) }
        let working = newestFirst.filter { LibraryFilter.Status(of: $0.item.status) == .active }
        active = working.filter { $0.item.status == .awaitingFileSelection }
            + working.filter { $0.item.status != .awaitingFileSelection }
        failed = newestFirst.filter { shelf in
            guard case .failed = shelf.item.status, let added = shelf.item.addedAt else { return false }
            return now.timeIntervalSince(added) <= Self.failedWindow
        }
    }
}
