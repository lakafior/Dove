import DoveKit
import FileProvider
import Foundation

/// Dove's library as a location in the Files app: one folder per service, one per ready item, then its files.
/// Opening a file downloads it from the service (Files does not stream). Deleting an item folder deletes the
/// item from its service; everything else is read-only.
///
/// The app registers the domain (`FilesLocation`) when a service is configured and signals the working set
/// after the library changes; the extension then re-reads the keys and reports what changed.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let context: FilesContext
    private let manager: NSFileProviderManager?
    private let session = URLSession(configuration: .default)

    required init(domain: NSFileProviderDomain) {
        context = FilesContext()
        manager = NSFileProviderManager(for: domain)
        super.init()
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
    ) -> Progress {
        let reply = Unchecked(completionHandler)
        let browser = context.browser
        return run {
            do {
                guard let id = LibraryNodeID(identifier) else { throw FilesError.noSuchItem }
                reply.value(FileProviderItem(try await browser.node(id)), nil)
            } catch {
                reply.value(nil, FilesError.map(error))
            }
        }
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, (any Error)?) -> Void
    ) -> Progress {
        let reply = Unchecked(completionHandler)
        let browser = context.browser
        let progress = Progress(totalUnitCount: -1)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        let tracker = DownloadProgress(reporting: progress)
        let session = session
        // Thread-safe in practice; not marked Sendable.
        let manager = Unchecked(manager)
        let task = Task {
            do {
                guard let id = LibraryNodeID(itemIdentifier), let manager = manager.value else { throw FilesError.noSuchItem }
                let node = try await browser.node(id)
                filesLog.info("Download starting")
                let request = try await browser.downloadRequest(for: id)
                // Streams to a file on disk: extensions get little memory, and these files are large.
                let (downloaded, response) = try await session.download(for: request, delegate: tracker)
                if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                    try? FileManager.default.removeItem(at: downloaded)
                    throw BackendError.http(status: status)
                }
                let destination = try manager.temporaryDirectoryURL().appending(path: UUID().uuidString)
                try FileManager.default.moveItem(at: downloaded, to: destination)
                filesLog.info("Download finished")
                reply.value(destination, FileProviderItem(node), nil)
            } catch {
                filesLog.error("Download failed: \(error.localizedDescription, privacy: .public)")
                reply.value(nil, nil, FilesError.map(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// A `.torrent` or `.nzb` dropped into a service folder is added to that service; Files then removes the
    /// dropped file (a nil item means "taken, not kept"). Anything else stays on the device, excluded from sync.
    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        let reply = Unchecked(completionHandler)
        let browser = context.browser
        let name = itemTemplate.filename
        let parent = LibraryNodeID(itemTemplate.parentItemIdentifier)
        let data = url.flatMap { try? Data(contentsOf: $0) }
        let manager = Unchecked(manager)
        return run {
            guard case .backend(let backend)? = parent, let data,
                  let source = LibraryBrowser.source(fileNamed: name, data: data)
            else {
                reply.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                return
            }
            do {
                try await browser.add(source, to: backend)
                filesLog.info("Added a dropped file to \(backend.rawValue, privacy: .public)")
                reply.value(nil, [], false, nil)
                try? await manager.value?.signalEnumerator(for: .workingSet)
            } catch {
                filesLog.error("Add failed: \(error.localizedDescription, privacy: .public)")
                reply.value(nil, [], false, FilesError.map(error))
            }
        }
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        // Services take no edits: answer with the service's version, and fetch it again if the content changed.
        let reply = Unchecked(completionHandler)
        let browser = context.browser
        let identifier = item.itemIdentifier
        let contentChanged = changedFields.contains(.contents)
        return run {
            do {
                guard let id = LibraryNodeID(identifier) else { throw FilesError.noSuchItem }
                reply.value(FileProviderItem(try await browser.node(id)), [], contentChanged, nil)
            } catch {
                reply.value(nil, [], false, FilesError.map(error))
            }
        }
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any Error)?) -> Void
    ) -> Progress {
        let reply = Unchecked(completionHandler)
        let browser = context.browser
        return run {
            do {
                // Items excluded from sync (files dropped into Files) never reached a service.
                guard let id = LibraryNodeID(identifier) else {
                    reply.value(nil)
                    return
                }
                guard case .item = id else { throw NSFileProviderError(.deletionRejected) }
                try await browser.delete(id)
                reply.value(nil)
            } catch {
                reply.value(FilesError.map(error))
            }
        }
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet {
            return WorkingSetEnumerator(context: context)
        }
        guard let id = LibraryNodeID(containerItemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
        return FolderEnumerator(id: id, context: context)
    }

    /// Runs `work` and lets the system cancel it through the returned progress.
    private func run(_ work: @escaping @Sendable () async -> Void) -> Progress {
        let task = Task { await work() }
        let progress = Progress(totalUnitCount: 1)
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}

/// Copies a download's byte counts into the progress Files shows. A child progress would not do: its parent's
/// count moves only when the child finishes, so the system saw no progress, gave up and started over.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: Progress
    private var observation: NSKeyValueObservation?

    init(reporting progress: Progress) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let progress = progress
        observation = task.progress.observe(\.completedUnitCount) { taskProgress, _ in
            if taskProgress.totalUnitCount > 0 { progress.totalUnitCount = taskProgress.totalUnitCount }
            progress.completedUnitCount = taskProgress.completedUnitCount
        }
    }
}

/// Completion handlers from FileProvider are not marked `Sendable`; the system allows calling them from
/// any thread.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

enum FilesError {
    static let noSuchItem = NSFileProviderError(.noSuchItem)

    /// Errors Files understands; anything else keeps its readable message.
    static func map(_ error: any Error) -> any Error {
        switch error {
        case let error as BackendError:
            switch error {
            case .notFound: return NSFileProviderError(.noSuchItem)
            case .unauthorized: return NSFileProviderError(.notAuthenticated)
            case .rateLimited: return NSFileProviderError(.serverUnreachable)
            default: return NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                NSLocalizedDescriptionKey: error.localizedDescription,
            ])
            }
        case let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost].contains(error.code):
            return NSFileProviderError(.serverUnreachable)
        case is CancellationError:
            return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        default:
            return error
        }
    }
}
