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
    /// iCloud Drive › Dove's folder, when this device has iCloud Drive for Dove (set by the app; resolving it
    /// must not happen on the main thread). Downloads meant for iCloud go to `directory` while it is nil.
    @ObservationIgnored public var iCloudDirectory: URL?
    /// Turns a picked folder's id into its URL, with access to it opened (`PickedFolders`; the app sets it). A nil
    /// answer (the disk is gone, the bookmark is stale) sends the download to `directory`.
    @ObservationIgnored public var folderResolver: ((String) -> URL?)?
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
        // Demo mode's records have no tasks behind them on purpose (`showDemo`).
        if !DemoMode.isActive { Task { await reconnect() } }
    }

    #if DEBUG
    /// Demo mode (`DemoMode`): made-up downloads to show, frozen where they are. Never saved.
    public func showDemo(_ demo: [DownloadRecord]) {
        records = demo
    }
    #endif

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
        file: LibraryFile,
        destination: DownloadDestination = .device,
        placement: LibraryFolderLayout.Placement? = nil
    ) throws -> DownloadRecord.ID {
        if let existing = records.first(where: {
            $0.isSameFile(backend: backend, itemID: itemID, fileID: file.id) && $0.destination == destination
        }) {
            switch existing.state {
            case .downloading, .finished: return existing.id
            case .paused, .failed: remove(existing.id)
            }
        }
        if let size = file.size { try checkSpace(for: size) }
        let record = DownloadRecord(
            backend: backend, itemID: itemID, fileID: file.id, name: placement?.fileName ?? file.name, totalBytes: file.size,
            destination: destination, subfolder: placement?.folder
        )
        records.insert(record, at: 0)
        run(session.downloadTask(with: request), for: record.id)
        return record.id
    }

    /// Starts downloading a file a plugin found, or returns the record already downloading or holding it.
    @discardableResult
    public func start(
        _ request: URLRequest,
        plugin: PluginFileRef,
        name: String,
        size: Int64? = nil,
        destination: DownloadDestination = .device,
        subfolder: String? = nil
    ) throws -> DownloadRecord.ID {
        if let existing = records.first(where: { $0.plugin == plugin && $0.destination == destination }) {
            switch existing.state {
            case .downloading, .finished: return existing.id
            case .paused, .failed: remove(existing.id)
            }
        }
        if let size { try checkSpace(for: size) }
        let record = DownloadRecord(
            backend: nil, plugin: plugin, itemID: "plugin:\(plugin.pluginID)", fileID: plugin.fileID, name: name, totalBytes: size,
            destination: destination, subfolder: subfolder
        )
        records.insert(record, at: 0)
        run(session.downloadTask(with: request), for: record.id)
        return record.id
    }

    /// Starts downloading a stream addon's direct link, or returns the record already downloading or holding it.
    @discardableResult
    public func start(
        _ request: URLRequest,
        stream: StreamFileRef,
        name: String,
        destination: DownloadDestination = .device,
        subfolder: String? = nil
    ) throws -> DownloadRecord.ID {
        if let existing = records.first(where: { $0.stream == stream && $0.destination == destination }) {
            switch existing.state {
            case .downloading, .finished: return existing.id
            case .paused, .failed: remove(existing.id)
            }
        }
        if let size = stream.size { try checkSpace(for: size) }
        let record = DownloadRecord(
            backend: nil, stream: stream, itemID: "stream:\(stream.source)", fileID: "\(stream.streamID)/\(stream.fileName)",
            name: name, totalBytes: stream.size, destination: destination, subfolder: subfolder
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

    /// Stops the transfer if any and deletes the record, its resume data and the downloaded file. With
    /// `deletingFile` false a finished file stays where it is (the Mac's "Remove from List": files in Downloads are
    /// the user's).
    public func remove(_ id: DownloadRecord.ID, deletingFile: Bool = true) {
        tasks.removeValue(forKey: id)?.cancel()
        store.setResumeData(nil, for: id)
        if deletingFile, let url = self[id].flatMap(fileURL) { try? FileManager.default.removeItem(at: url) }
        records.removeAll { $0.id == id }
        save()
    }

    /// The downloaded file, once finished and still on disk.
    public func fileURL(for record: DownloadRecord) -> URL? {
        guard record.state == .finished, let localName = record.localName else { return nil }
        let url = folder(for: record).appending(path: localName)
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
        // Without iCloud Drive (signed out, or a sideloaded build without the entitlement) the file stays here.
        let place: DownloadDestination
        switch record.destination {
        case .iCloud where iCloudDirectory == nil: place = .device
        case .folder(let id) where folderResolver?(id) == nil: place = .device
        default: place = record.destination
        }
        let folder = folder(for: place, subfolder: record.subfolder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A placed name (`subfolder` set) may hold a path inside its item (`CD1/01.mp3`): its folders go under
            // `folder`. Otherwise only the file's own name counts, as services name files with their paths.
            let parts = record.subfolder == nil ? [record.name] : record.name.split(separator: "/").map(String.init)
            let folder = parts.dropLast().reduce(folder) { $0.appending(path: DownloadNaming.sanitized($1)) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let leaf = DownloadNaming.unique(DownloadNaming.sanitized(parts.last ?? record.name)) {
                FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
                    || FileManager.default.fileExists(atPath: folder.appending(path: ".\($0).icloud").path)
            }
            let name = (parts.dropLast().map(DownloadNaming.sanitized) + [leaf]).joined(separator: "/")
            var destination = folder.appending(path: leaf)
            try FileManager.default.moveItem(at: location, to: destination)
            if place == .device {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? destination.setResourceValues(values)
            }
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            update(id) {
                $0.state = .finished
                $0.localName = name
                $0.destination = place
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

    private func folder(for destination: DownloadDestination, subfolder: String? = nil) -> URL {
        let root: URL
        switch destination {
        case .device: root = directory
        case .iCloud: root = iCloudDirectory ?? directory
        case .folder(let id): root = folderResolver?(id) ?? directory
        }
        guard let subfolder, !subfolder.isEmpty else { return root }
        return subfolder.split(separator: "/").reduce(root) { $0.appending(path: DownloadNaming.sanitized(String($1))) }
    }

    private func folder(for record: DownloadRecord) -> URL {
        folder(for: record.destination, subfolder: record.subfolder)
    }

    private func settled(_ id: DownloadRecord.ID) {
        save()
        guard let record = self[id] else { return }
        defer {
            // A file kept in iCloud Drive belongs to the Library's iCloud place, not to this device's
            // downloads: the record goes once everyone has heard about it (failures stay, to retry).
            if record.state == .finished, record.destination == .iCloud {
                records.removeAll { $0.id == id }
                save()
            }
        }
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
        update(id) { $0.state = .failed(reason: Self.reason(for: nsError)) }
        settled(id)
    }

    /// iOS refuses plain `http://` links (App Transport Security), also after a redirect: some addons' files
    /// sit on such hosts. A cloud service fetches them fine.
    nonisolated static func reason(for error: NSError) -> String {
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            return "The file is served over plain HTTP, which iOS does not allow. Send it to a cloud service instead."
        }
        return error.localizedDescription
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
