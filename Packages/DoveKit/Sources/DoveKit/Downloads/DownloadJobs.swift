import Foundation
import Observation

/// Runs "download only" jobs: waits until the service has the item, downloads the picked files through
/// `DownloadManager`, then deletes the item from the service.
///
/// iOS gives no background polling, so waiting jobs are checked while the app is open (`startPolling`)
/// and on launch. Downloads run in the background; the delete happens when the last one settles, or on
/// the next launch if the app was not running then. A failed download keeps the item so it can be retried.
@MainActor
@Observable
public final class DownloadJobs {
    public private(set) var jobs: [DownloadJob]

    @ObservationIgnored private let store: DownloadJobStore
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let backend: @MainActor (BackendID) -> (any LibraryBackend)?
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Jobs being advanced right now, so overlapping refreshes do not start or delete twice.
    @ObservationIgnored private var inFlight: Set<DownloadJob.ID> = []

    public init(
        store: DownloadJobStore,
        downloads: DownloadManager,
        pollInterval: Duration = .seconds(10),
        backend: @escaping @MainActor (BackendID) -> (any LibraryBackend)?
    ) {
        self.store = store
        self.downloads = downloads
        self.pollInterval = pollInterval
        self.backend = backend
        jobs = store.load()
        downloads.onSettled = { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// Starts a job for an item just added to a service and makes a first attempt right away
    /// (a cached torrent is usually ready at once).
    public func add(backend: BackendID, itemID: LibraryItem.ID, name: String, pick: DownloadJob.Pick) async {
        let job = DownloadJob(backend: backend, itemID: itemID, name: name, pick: pick)
        jobs.insert(job, at: 0)
        save()
        await advance(job.id)
        startPolling()
    }

    /// Tries a failed job again. Files already downloaded or downloading are not fetched twice.
    public func retry(_ id: DownloadJob.ID) async {
        update(id) { $0.state = .waiting }
        save()
        await advance(id)
        startPolling()
    }

    /// Forgets the job. With `deleteItem` the item is removed from the service too; downloads stay.
    public func cancel(_ id: DownloadJob.ID, deleteItem: Bool) async throws {
        guard let job = self[id] else { return }
        if deleteItem, let service = backend(job.backend) {
            try await service.delete(job.itemID)
        }
        remove(id)
    }

    public subscript(id: DownloadJob.ID) -> DownloadJob? {
        jobs.first { $0.id == id }
    }

    /// The job a download belongs to, if any.
    public func job(for record: DownloadRecord) -> DownloadJob? {
        jobs.first {
            if case .downloading(let ids) = $0.state { ids.contains(record.id) } else { false }
        }
    }

    // MARK: - Polling

    /// Checks every job now, then waiting ones every `pollInterval` until none is left. Call when the app becomes active.
    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                guard self.jobs.contains(where: { $0.state == .waiting }) else { break }
                try? await Task.sleep(for: self.pollInterval)
            }
            self?.pollTask = nil
        }
    }

    /// Call when the app goes to the background.
    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh() async {
        for job in jobs {
            await advance(job.id)
        }
    }

    // MARK: - Steps

    private func advance(_ id: DownloadJob.ID) async {
        guard let job = self[id], !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        switch job.state {
        case .waiting: await startWhenReady(job)
        case .downloading(let ids): await finishWhenDownloaded(job, ids: ids)
        case .failed: break
        }
    }

    private func startWhenReady(_ job: DownloadJob) async {
        guard let service = backend(job.backend) else {
            return fail(job.id, "\(job.backend.displayName) is no longer configured.")
        }
        do {
            let item = try await service.item(job.itemID)
            switch item.status {
            case .queued, .downloading:
                return
            case .awaitingFileSelection:
                // Nobody is looking at the item; take what Dove would suggest.
                guard let selecting = service as? any FileSelecting else { return }
                let selection = try await selecting.selectableFiles(job.itemID)
                try await selecting.selectFiles(job.itemID, fileIDs: selection.suggested)
            case .failed(let reason):
                fail(job.id, "\(job.backend.displayName): \(reason)")
            case .ready:
                let files = job.files(in: item)
                guard !files.isEmpty else { return fail(job.id, "There are no files to download.") }
                var ids: [DownloadRecord.ID] = []
                for file in files {
                    let request = try await service.downloadRequest(itemID: job.itemID, fileID: file.id)
                    ids.append(try downloads.start(request, backend: job.backend, itemID: job.itemID, file: file))
                }
                update(job.id) {
                    $0.name = item.name
                    $0.state = .downloading(ids)
                }
                save()
            }
        } catch {
            fail(job.id, error.localizedDescription)
        }
    }

    private func finishWhenDownloaded(_ job: DownloadJob, ids: [DownloadRecord.ID]) async {
        let records = ids.map { downloads[$0] }
        // The user removed one of its downloads: leave the item on the service.
        guard records.allSatisfy({ $0 != nil }) else { return remove(job.id) }
        guard records.allSatisfy({ $0?.state == .finished }) else { return }
        do {
            guard let service = backend(job.backend) else {
                return fail(job.id, "\(job.backend.displayName) is no longer configured.")
            }
            try await service.delete(job.itemID)
            remove(job.id)
        } catch {
            fail(job.id, "Downloaded, but not removed from \(job.backend.displayName): \(error.localizedDescription)")
        }
    }

    private func fail(_ id: DownloadJob.ID, _ reason: String) {
        update(id) { $0.state = .failed(reason: reason) }
        save()
    }

    private func remove(_ id: DownloadJob.ID) {
        jobs.removeAll { $0.id == id }
        save()
    }

    private func update(_ id: DownloadJob.ID, _ change: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func save() {
        store.save(jobs)
    }
}
