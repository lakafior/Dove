import Foundation
import Testing
@testable import DoveKit

struct DownloadJobPickTests {
    private let pack = LibraryItem(
        id: "torrent:1", backend: .torBox, name: "Show.S01", status: .ready,
        files: [
            LibraryFile(id: "1", name: "Show.S01/Show.S01E01.1080p.mkv", size: 100),
            LibraryFile(id: "2", name: "Show.S01/Show.S01E02.1080p.mkv", size: 120),
            LibraryFile(id: "3", name: "Show.S01/Sample/show.s01e01.sample.mkv", size: 5),
            LibraryFile(id: "4", name: "Show.S01/RARBG.txt", size: 1),
        ]
    )

    private func pick(_ pick: DownloadJob.Pick, in item: LibraryItem) -> [String] {
        DownloadJob(backend: .torBox, itemID: item.id, name: item.name, pick: pick).files(in: item).map(\.id)
    }

    @Test func episodePicksTheMatchingFile() {
        #expect(pick(.episode(season: 1, episode: 2), in: pack) == ["2"])
    }

    @Test func missingEpisodeFallsBackToTheLargestVideo() {
        #expect(pick(.episode(season: 3, episode: 1), in: pack) == ["2"])
    }

    @Test func allVideosSkipsSamplesAndExtras() {
        #expect(pick(.allVideos, in: pack) == ["1", "2"])
    }

    @Test func largestVideoForMovies() {
        #expect(pick(.largestVideo, in: pack) == ["2"])
    }

    @Test func withoutVideosEverythingIsDownloaded() {
        let album = LibraryItem(id: "torrent:2", backend: .torBox, name: "Album", status: .ready, files: [
            LibraryFile(id: "1", name: "01.flac"), LibraryFile(id: "2", name: "cover.jpg"),
        ])
        #expect(pick(.allVideos, in: album) == ["1", "2"])
        #expect(pick(.largestVideo, in: album) == ["1", "2"])
    }
}

/// A backend whose item and answers the test controls.
actor JobBackend: LibraryBackend {
    nonisolated let id: BackendID
    nonisolated let supportedSources: Set<SourceKind> = [.torrent]
    var current: LibraryItem
    var links: [LibraryFile.ID: URL] = [:]
    var deleteError: BackendError?
    private(set) var deleted: [LibraryItem.ID] = []

    init(_ id: BackendID = .torBox, item: LibraryItem) {
        self.id = id
        current = item
    }

    func set(_ item: LibraryItem) { current = item }
    func setLink(_ url: URL, for fileID: LibraryFile.ID) { links[fileID] = url }
    func failDeletes(_ error: BackendError?) { deleteError = error }

    func validateCredentials() async throws {}
    private(set) var added = 0
    func add(_ source: Source) async throws -> LibraryItem.ID {
        added += 1
        return current.id
    }
    func items() async throws -> [LibraryItem] { [current] }
    func item(_ itemID: LibraryItem.ID) async throws -> LibraryItem { current }

    func delete(_ itemID: LibraryItem.ID) async throws {
        if let deleteError { throw deleteError }
        deleted.append(itemID)
    }

    func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        guard let url = links[fileID] else { throw BackendError.notFound }
        return URLRequest(url: url)
    }
}

@MainActor
@Suite(.serialized)
struct DownloadJobsTests {
    private func make(_ backend: JobBackend) throws -> (DownloadJobs, DownloadManager) {
        let root = FileManager.default.temporaryDirectory.appending(path: "DoveKitTests-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let downloads = DownloadManager(
            configuration: configuration,
            directory: root.appending(path: "Documents"),
            store: DownloadStore(directory: root.appending(path: "Support"))
        )
        let jobs = DownloadJobs(
            store: DownloadJobStore(fileURL: root.appending(path: "Support/jobs.json")),
            downloads: downloads,
            pollInterval: .milliseconds(20),
            backend: { $0 == backend.id ? backend : nil }
        )
        return (jobs, downloads)
    }

    private func link(_ name: String, status: Int = 200) -> URL {
        let url = URL(string: "https://dl.test/\(UUID().uuidString)/\(name)")!
        StubProtocol.set(url, status: status, body: Data(name.utf8))
        return url
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 where !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await condition())
    }

    private static func episodePack(status: LibraryItem.Status) -> LibraryItem {
        LibraryItem(id: "torrent:9", backend: .torBox, name: "Show.S01", status: status, files: [
            LibraryFile(id: "1", name: "Show.S01E01.mkv", size: 10),
            LibraryFile(id: "2", name: "Show.S01E02.mkv", size: 10),
        ])
    }

    @Test func cachedItemIsDownloadedThenDeletedFromTheService() async throws {
        let backend = JobBackend(item: Self.episodePack(status: .ready))
        await backend.setLink(link("e02.mkv"), for: "2")
        let (jobs, downloads) = try make(backend)
        var ended: [DownloadJob.Outcome] = []
        jobs.onEnded = { _, outcome in ended.append(outcome) }

        await jobs.add(backend: .torBox, itemID: "torrent:9", name: "Show.S01", pick: .episode(season: 1, episode: 2))

        try await waitUntil { await backend.deleted == ["torrent:9"] }
        #expect(jobs.jobs.isEmpty)
        #expect(ended == [.finished(files: 1)])
        #expect(downloads.records.map(\.fileID) == ["2"])
        #expect(downloads.records.first?.state == .finished)
    }

    @Test func waitingItemIsPolledUntilReady() async throws {
        let backend = JobBackend(item: Self.episodePack(status: .downloading(progress: 0.5)))
        await backend.setLink(link("e01.mkv"), for: "1")
        await backend.setLink(link("e02.mkv"), for: "2")
        let (jobs, downloads) = try make(backend)

        await jobs.add(backend: .torBox, itemID: "torrent:9", name: "Show.S01", pick: .allVideos)
        #expect(jobs.jobs.first?.state == .waiting)
        await backend.set(Self.episodePack(status: .ready))

        try await waitUntil { await backend.deleted == ["torrent:9"] }
        #expect(Set(downloads.records.map(\.fileID)) == ["1", "2"])
    }

    @Test func failedDownloadKeepsTheItemUntilARetrySucceeds() async throws {
        let backend = JobBackend(item: Self.episodePack(status: .ready))
        await backend.setLink(link("expired.mkv", status: 403), for: "1")
        let (jobs, downloads) = try make(backend)
        downloads.requestProvider = { record in
            try await backend.downloadRequest(itemID: record.itemID, fileID: record.fileID)
        }

        await jobs.add(backend: .torBox, itemID: "torrent:9", name: "Show.S01", pick: .episode(season: 1, episode: 1))
        let id = try #require(downloads.records.first?.id)
        try await waitUntil { if case .failed = downloads[id]?.state { true } else { false } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await backend.deleted.isEmpty)
        #expect(jobs.jobs.count == 1)

        await backend.setLink(link("fresh.mkv"), for: "1")
        try await downloads.resume(id)

        try await waitUntil { await backend.deleted == ["torrent:9"] }
        #expect(jobs.jobs.isEmpty)
    }

    @Test func removingADownloadAbandonsTheJobAndKeepsTheItem() async throws {
        let backend = JobBackend(item: Self.episodePack(status: .ready))
        await backend.setLink(link("bad.mkv", status: 500), for: "1")
        let (jobs, downloads) = try make(backend)

        await jobs.add(backend: .torBox, itemID: "torrent:9", name: "Show.S01", pick: .episode(season: 1, episode: 1))
        let id = try #require(downloads.records.first?.id)
        try await waitUntil { if case .failed = downloads[id]?.state { true } else { false } }
        downloads.remove(id)
        await jobs.refresh()

        #expect(jobs.jobs.isEmpty)
        #expect(await backend.deleted.isEmpty)
    }

    @Test func serviceFailureFailsTheJob() async throws {
        let backend = JobBackend(item: Self.episodePack(status: .failed(reason: "dead torrent")))
        let (jobs, _) = try make(backend)
        var ended: [DownloadJob.Outcome] = []
        jobs.onEnded = { _, outcome in ended.append(outcome) }

        await jobs.add(backend: .torBox, itemID: "torrent:9", name: "Show.S01", pick: .allVideos)

        #expect(jobs.jobs.first?.state == .failed(reason: "TorBox: dead torrent"))
        #expect(ended == [.failed(reason: "TorBox: dead torrent")])
    }

    @Test func deleteErrorIsReportedAndRetryFinishesTheJob() async throws {
        let backend = JobBackend(item: Self.episodePack(status: .ready))
        await backend.setLink(link("e01.mkv"), for: "1")
        await backend.failDeletes(.rateLimited)
        let (jobs, downloads) = try make(backend)

        await jobs.add(backend: .torBox, itemID: "torrent:9", name: "Show.S01", pick: .episode(season: 1, episode: 1))
        try await waitUntil { if case .failed = jobs.jobs.first?.state { true } else { false } }
        #expect(downloads.records.count == 1)

        await backend.failDeletes(nil)
        let job = try #require(jobs.jobs.first)
        await jobs.retry(job.id)

        try await waitUntil { await backend.deleted == ["torrent:9"] }
        #expect(downloads.records.count == 1, "the finished file is not downloaded again")
    }

    @Test func jobsSurviveARelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DoveKitTests-\(UUID().uuidString)")
        let store = DownloadJobStore(fileURL: root.appending(path: "jobs.json"))
        let job = DownloadJob(backend: .realDebrid, itemID: "torrent:A", name: "A", pick: .episode(season: 2, episode: 5))
        store.save([job])
        #expect(store.load() == [job])
    }
}
