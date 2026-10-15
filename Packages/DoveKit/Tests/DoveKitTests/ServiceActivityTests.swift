import Foundation
import Testing
@testable import DoveKit

struct ServiceActivityTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func shelf(_ id: String, _ backend: BackendID = .torBox, hoursAgo: Double?, status: LibraryItem.Status) -> ShelfItem {
        ShelfItem(item: LibraryItem(
            id: id,
            backend: backend,
            name: "Release.\(id).1080p",
            status: status,
            addedAt: hoursAgo.map { now.addingTimeInterval(-$0 * 3_600) }
        ))
    }

    @Test func listsWorkingItemsWithFileChoiceFirstThenNewest() {
        let activity = ServiceActivity(items: [
            shelf("ready", hoursAgo: 1, status: .ready),
            shelf("old", hoursAgo: 10, status: .downloading(progress: 0.2)),
            shelf("new", hoursAgo: 2, status: .queued),
            shelf("choose", .realDebrid, hoursAgo: 20, status: .awaitingFileSelection),
        ], now: now)

        #expect(activity.active.map(\.item.id) == ["choose", "new", "old"])
        #expect(activity.failed.isEmpty)
    }

    @Test func keepsOnlyRecentFailures() {
        let activity = ServiceActivity(items: [
            shelf("recent", .nzbdav, hoursAgo: 5, status: .failed(reason: "Missing articles")),
            shelf("stale", hoursAgo: 24 * 4, status: .failed(reason: "dead")),
            shelf("undated", hoursAgo: nil, status: .failed(reason: "dead")),
        ], now: now)

        #expect(activity.failed.map(\.item.id) == ["recent"])
        #expect(activity.active.isEmpty)
        #expect(!activity.isEmpty)
    }

    @Test func leavesOutItemsOfDownloadOnlyJobs() {
        let job = DownloadJob(backend: .torBox, itemID: "mine", name: "Release.mine", pick: .largestVideo)
        let activity = ServiceActivity(items: [
            shelf("mine", hoursAgo: 1, status: .downloading(progress: 0.5)),
            shelf("mine", .realDebrid, hoursAgo: 1, status: .queued),
        ], jobs: [job], now: now)

        #expect(activity.active.map(\.item.backend) == [.realDebrid])
    }
}
