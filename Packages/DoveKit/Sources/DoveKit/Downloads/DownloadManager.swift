import Foundation
import Observation

/// Downloads library files to the device with a background `URLSession`: transfers continue while
/// the app is suspended, and iOS relaunches the app to deliver finished files.
///
/// - Pause cancels the task with resume data; resume continues from it. Without resume data
///   (or after it was used up) a retry asks `requestProvider` for a fresh link, because debrid links expire.
/// - Finished files go to `directory` under their service name (`name (2).mkv` when taken),
///   excluded from iCloud backup.
/// - Delegate callbacks arrive on the main queue, so the move out of the temporary location happens
///   before `didFinishDownloadingTo` returns, as URLSession requires.
@MainActor
@Observable
public final class DownloadManager: NSObject {
    public private(set) var records: [DownloadRecord] = []

    /// Builds a fresh request for a record (the backend's `downloadRequest`). Set by the app.
    @ObservationIgnored public var requestProvider: (@MainActor (DownloadRecord) async throws -> URLRequest)?
    /// Called when a download finishes or fails, in the order added (`DownloadJobs` deletes items after their
    /// downloads; the app notifies). Pausing and removing do not settle.
    @ObservationIgnored private var settledHandlers: [@MainActor (DownloadRecord) -> Void] = []
    /// Handed over by the app delegate when iOS relaunches the app for this session; called once events are delivered.
    @ObservationIgnored public var backgroundEventsCompletion: (() -> Void)?

    public let directory: URL
    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var tasks: [DownloadRecord.ID: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var lastProgress: [DownloadRecord.ID: Date] = [:]
    /// Progress redraws at most this often; state changes are immediate.
    private static let progressInterval: TimeInterval = 0.3

    public static func backgroundConfiguration(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        #if os(iOS)
        configuration.sessionSendsLaunchEvents = true
        #endif
        return configuration
    }

    /// - Parameters:
    ///   - configuration: `backgroundConfiguration(identifier:)` in the app; an ephemeral one in tests.
    ///   - directory: where finished files go (the app's Documents, so they show in Files).
    ///   - store: records and resume data.
    public init(configuration: URLSessionConfiguration, directory: URL, store: DownloadStore) {
        self.directory = directory
        self.store = store
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        records = store.load()
        Task { await reconnect() }
    }

    public func onSettled(_ handler: @escaping @MainActor (DownloadRecord) -> Void) {
        settledHandlers.append(handler)
    }

    // MARK: - Actions

    /// Starts downloading a file, or returns the record already downloading or holding it.
    @discardableResult
    public func start(
        _ request: URLRequest,
        backend: BackendID,
        itemID: LibraryItem.ID,
        file: LibraryFile
    ) throws -> DownloadRecord.ID {
        if let existing = records.first(where: { $0.isSameFile(backend: backend, itemID: itemID, fileID: file.id) }) {
            switch existing.state {
            case .downloading, .finished: return existing.id
            case .paused, .failed: remove(existing.id)
            }
        }
        if let size = file.size { try checkSpace(for: size) }
        let record = DownloadRecord(backend: backend, itemID: itemID, fileID: file.id, name: file.name, totalBytes: file.size)
        records.insert(record, at: 0)
        run(session.downloadTask(with: request), for: record.id)
        return record.id
    }

    /// Starts a direct download (a link from a direct-download site), or returns the record already downloading
    /// or holding that file.
    @discardableResult
    public func start(_ request: URLRequest, direct: DirectDownloadRef, name: String, size: Int64? = nil) throws -> DownloadRecord.ID {
        if let existing = records.first(where: { $0.direct == direct }) {
            switch existing.state {
            case .downloading, .finished: return existing.id
            case .paused, .failed: remove(existing.id)
            }
        }
        if let size { try checkSpace(for: size) }
        let record = DownloadRecord(
            backend: nil, direct: direct, itemID: "direct:\(direct.md5)", fileID: direct.md5, name: name, totalBytes: size
        )
        records.insert(record, at: 0)
        run(session.downloadTask(with: request), for: record.id)
        return record.id
    }

    public func pause(_ id: DownloadRecord.ID) {
        guard let task = tasks[id], self[id]?.state == .downloading else { return }
        // Marked first, so the cancellation that follows is not reported as a failure.
        update(id) { $0.state = .paused }
        tasks[id] = nil
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in self?.store.setResumeData(data, for: id) }
        })
    }

    /// Continues a paused or failed download: from resume data when there is some, otherwise from a fresh link.
    public func resume(_ id: DownloadRecord.ID) async throws {
        guard let record = self[id], record.state != .downloading, record.state != .finished else { return }
        if let data = store.resumeData(for: id) {
            store.setResumeData(nil, for: id)
            update(id) { $0.state = .downloading }
            run(session.downloadTask(withResumeData: data), for: id)
            return
        }
        guard let requestProvider else { throw BackendError.api(message: "This service is no longer configured.") }
        let request = try await requestProvider(record)
        guard self[id] != nil else { return }
        update(id) {
            $0.state = .downloading
            $0.bytesWritten = 0
        }
        run(session.downloadTask(with: request), for: id)
    }

    /// Stops the transfer if any and deletes the record, its resume data and the downloaded file.
    public func remove(_ id: DownloadRecord.ID) {
        tasks.removeValue(forKey: id)?.cancel()
        store.setResumeData(nil, for: id)
        if let url = self[id].flatMap(fileURL) { try? FileManager.default.removeItem(at: url) }
        records.removeAll { $0.id == id }
        save()
    }

    /// The downloaded file, once finished and still on disk.
    public func fileURL(for record: DownloadRecord) -> URL? {
        guard record.state == .finished, let localName = record.localName else { return nil }
        let url = directory.appending(path: localName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public subscript(id: DownloadRecord.ID) -> DownloadRecord? {
        records.first { $0.id == id }
    }

    // MARK: - Internals

    private func run(_ task: URLSessionDownloadTask, for id: DownloadRecord.ID) {
        task.taskDescription = id
        tasks[id] = task
        save()
        task.resume()
    }

    /// After a relaunch: reattach tasks the session kept running, and settle records whose task is gone.
    private func reconnect() async {
        let running = await session.allTasks
        for task in running {
            guard let id = task.taskDescription, let download = task as? URLSessionDownloadTask, self[id] != nil else {
                task.cancel()
                continue
            }
            tasks[id] = download
        }
        for record in records where record.state == .downloading && tasks[record.id] == nil {
            update(record.id) {
                $0.state = store.resumeData(for: record.id) != nil ? .paused : .failed(reason: "Interrupted.")
            }
        }
        save()
    }

    private func checkSpace(for size: Int64) throws {
        // Volume values need an existing path.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return }
        guard free > size else {
            let needed = size.formatted(.byteCount(style: .file))
            let available = free.formatted(.byteCount(style: .file))
            throw BackendError.api(message: "Not enough space: the file needs \(needed), \(available) is free.")
        }
    }

    private func update(_ id: DownloadRecord.ID, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
    }

    private func save() {
        store.save(records)
    }

    private func finish(_ id: DownloadRecord.ID, downloadedTo location: URL, response: URLResponse?) {
        tasks[id] = nil
        guard let record = self[id] else { return }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            update(id) { $0.state = .failed(reason: "The server answered \(http.statusCode). Try again for a fresh link.") }
            settled(id)
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = DownloadNaming.unique(DownloadNaming.sanitized(record.name)) {
                FileManager.default.fileExists(atPath: self.directory.appending(path: $0).path)
            }
            var destination = directory.appending(path: name)
            try FileManager.default.moveItem(at: location, to: destination)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? destination.setResourceValues(values)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            update(id) {
                $0.state = .finished
                $0.localName = name
                if let size {
                    $0.bytesWritten = size
                    $0.totalBytes = size
                }
            }
        } catch {
            update(id) { $0.state = .failed(reason: "Could not save the file: \(error.localizedDescription)") }
        }
        settled(id)
    }

    private func settled(_ id: DownloadRecord.ID) {
        save()
        guard let record = self[id] else { return }
        for handler in settledHandlers { handler(record) }
    }

    private func complete(_ id: DownloadRecord.ID, error: (any Error)?) {
        guard let error, let record = self[id] else { return }
        tasks[id] = nil
        // Pausing and removing cancel on purpose.
        guard record.state == .downloading else { return }
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            store.setResumeData(data, for: id)
        }
        update(id) { $0.state = .failed(reason: error.localizedDescription) }
        settled(id)
    }

    private func progress(_ id: DownloadRecord.ID, written: Int64, expected: Int64) {
        let now = Date.now
        if let last = lastProgress[id], now.timeIntervalSince(last) < Self.progressInterval { return }
        lastProgress[id] = now
        update(id) {
            guard $0.state == .downloading else { return }
            $0.bytesWritten = written
            if expected > 0 { $0.totalBytes = expected }
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription else { return }
        let response = downloadTask.response
        MainActor.assumeIsolated { finish(id, downloadedTo: location, response: response) }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        MainActor.assumeIsolated { progress(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let id = task.taskDescription else { return }
        MainActor.assumeIsolated { complete(id, error: error) }
    }

    #if os(iOS)
    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundEventsCompletion?()
            backgroundEventsCompletion = nil
        }
    }
    #endif
}
