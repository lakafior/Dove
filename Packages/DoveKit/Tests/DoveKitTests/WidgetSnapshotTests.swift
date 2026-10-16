import Foundation
import Testing
@testable import DoveKit

struct WidgetSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func countsItemsSizeAndActivePerService() {
        let items = [
            LibraryItem(id: "1", backend: .torBox, name: "A", size: 1_000, status: .ready),
            LibraryItem(id: "2", backend: .torBox, name: "B", size: 500, status: .downloading(progress: 0.5)),
            LibraryItem(id: "3", backend: .nzbdav, name: "C", size: nil, status: .queued),
            LibraryItem(id: "4", backend: .nzbdav, name: "D", size: 2_000, status: .failed(reason: "x")),
        ]
        let counts = WidgetSnapshot.libraryCounts(items)
        #expect(counts[.torBox]?.items == 2 && counts[.torBox]?.bytes == 1_500 && counts[.torBox]?.active == 1)
        #expect(counts[.nzbdav]?.items == 2 && counts[.nzbdav]?.bytes == 2_000 && counts[.nzbdav]?.active == 1)
    }

    @Test func lightsFollowTheLastRefreshAndThePlan() {
        let long = AccountStatus(isPremium: true, premiumUntil: now.addingTimeInterval(86_400 * 40))
        let short = AccountStatus(isPremium: true, premiumUntil: now.addingTimeInterval(86_400 * 3))
        #expect(WidgetSnapshot.light(failed: false, account: long, now: now) == .good)
        #expect(WidgetSnapshot.light(failed: false, account: short, now: now) == .warning)
        #expect(WidgetSnapshot.light(failed: false, account: AccountStatus(isPremium: false), now: now) == .warning)
        #expect(WidgetSnapshot.light(failed: true, account: long, now: now) == .failed)
        #expect(WidgetSnapshot.light(failed: nil, account: nil, now: now) == .unknown)
    }

    @Test func savesOnlyRealChangesAndFindsTheSoonestExpiry() throws {
        let container = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        var snapshot = WidgetSnapshot(generatedAt: now, services: [
            .init(backend: .realDebrid, light: .good, daysLeft: 56, items: 3, bytes: 10),
            .init(backend: .torBox, light: .warning, daysLeft: 4, items: 1, bytes: 5),
            .init(backend: .nzbdav, light: .good, items: 2, bytes: 1),
        ])
        #expect(snapshot.soonestExpiry?.backend == .torBox)
        #expect(snapshot.totalItems == 6 && snapshot.totalBytes == 16)
        #expect(try snapshot.save(to: container))
        snapshot.generatedAt = now.addingTimeInterval(60)
        #expect(try !snapshot.save(to: container), "only the date changed")
        snapshot.services[0].items = 4
        #expect(try snapshot.save(to: container))
        #expect(WidgetSnapshot.load(from: container) == snapshot)
    }
}
