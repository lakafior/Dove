import DoveKit
import FileProvider
import Foundation
import os

/// Service IDs and error messages only: never URLs, keys or file names.
let filesLog = Logger(subsystem: "net.smigi.dove", category: "files")

/// State shared by the extension and its enumerators: the browser built from the Keychain, and the
/// working set snapshot in the App Group container.
final class FilesContext: @unchecked Sendable {
    private let lock = NSLock()
    private var current: LibraryBrowser
    let snapshots: SnapshotStore

    init() {
        current = Self.makeBrowser()
        let group = Bundle.main.object(forInfoDictionaryKey: "DoveAppGroup") as? String
        let container = group.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            ?? .temporaryDirectory
        snapshots = SnapshotStore(fileURL: container.appending(path: "Files/working-set.json"))
    }

    var browser: LibraryBrowser {
        lock.withLock { current }
    }

    /// Re-reads the keys: the app signals the working set after services are added or removed.
    @discardableResult
    func reload() -> LibraryBrowser {
        let browser = Self.makeBrowser()
        lock.withLock { current = browser }
        return browser
    }

    private static func makeBrowser() -> LibraryBrowser {
        let keychain = SharedConfiguration.keychain()
        let backends = SharedConfiguration.backends(from: keychain)
        if !backends.contains(where: { $0.id == .nzbdav }) {
            // Which nzbdav fields this process can read (yes/no only, never the values).
            let fields: [CredentialKey] = [.nzbdavURL, .nzbdavAPIKey, .nzbdavWebDAVUser, .nzbdavWebDAVPassword]
            let seen = fields.map { key in
                do { return "\(key.rawValue)=\((try keychain.get(key))?.isEmpty == false)" } catch { return "\(key.rawValue)=\(error)" }
            }
            filesLog.info("No nzbdav: \(seen.joined(separator: " "), privacy: .public)")
        }
        filesLog.info("Services: \(backends.map(\.id.rawValue).joined(separator: ","), privacy: .public)")
        return LibraryBrowser(backends: backends)
    }
}

/// One change enumeration at a time, so two never diff against the same snapshot.
actor SnapshotStore {
    private let fileURL: URL
    private var cached: LibrarySnapshot?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func current() -> LibrarySnapshot {
        if let cached { return cached }
        let loaded = LibrarySnapshot.load(from: fileURL) ?? LibrarySnapshot()
        cached = loaded
        return loaded
    }

    /// Diffs against a fresh listing, saves, and returns what changed. Nil when `generation` is stale.
    func advance(from generation: Int, using browser: LibraryBrowser) async -> LibrarySnapshot.Changes? {
        guard current().generation == generation else { return nil }
        let top = await browser.topLevel()
        let changes = current().changes(to: top.nodes, failed: top.failed)
        cached = changes.snapshot
        try? changes.snapshot.save(to: fileURL)
        return changes
    }
}

extension NSFileProviderSyncAnchor {
    init(generation: Int) {
        self.init(Data(String(generation).utf8))
    }

    var generation: Int? {
        Int(String(decoding: rawValue, as: UTF8.self))
    }
}

/// Lists one folder. Folders have no change tracking of their own: asking for changes expires the anchor,
/// so Files lists the folder again (cheap, thanks to the browser's cache).
final class FolderEnumerator: NSObject, NSFileProviderEnumerator {
    private let id: LibraryNodeID
    private let context: FilesContext

    init(id: LibraryNodeID, context: FilesContext) {
        self.id = id
        self.context = context
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observer = Unchecked(observer)
        let browser = id == .root ? context.reload() : context.browser
        let id = id
        Task {
            do {
                let nodes = try await browser.children(of: id)
                filesLog.debug("Listed \(nodes.count) entries")
                observer.value.didEnumerate(nodes.map(FileProviderItem.init))
                observer.value.finishEnumerating(upTo: nil)
            } catch {
                filesLog.error("List failed: \(error.localizedDescription, privacy: .public)")
                observer.value.finishEnumeratingWithError(FilesError.map(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(generation: 0))
    }
}

/// Services and their ready items, the part of the tree whose changes Files hears about.
/// Item contents are listed when opened (`FolderEnumerator`); deleting an item removes its subtree.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let context: FilesContext

    init(context: FilesContext) {
        self.context = context
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observer = Unchecked(observer)
        let browser = context.reload()
        Task {
            let top = await browser.topLevel()
            filesLog.info("Working set: \(top.nodes.count) entries, failed: \(top.failed.map(\.rawValue).joined(separator: ","), privacy: .public)")
            for chunk in stride(from: 0, to: top.nodes.count, by: 200) {
                observer.value.didEnumerate(top.nodes[chunk..<min(chunk + 200, top.nodes.count)].map(FileProviderItem.init))
            }
            observer.value.finishEnumerating(upTo: nil)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let observer = Unchecked(observer)
        let browser = context.reload()
        let snapshots = context.snapshots
        Task {
            guard let generation = anchor.generation,
                  let changes = await snapshots.advance(from: generation, using: browser)
            else {
                observer.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            if !changes.updated.isEmpty {
                observer.value.didUpdate(changes.updated.map(FileProviderItem.init))
            }
            if !changes.deleted.isEmpty {
                observer.value.didDeleteItems(withIdentifiers: changes.deleted.map(\.providerIdentifier))
            }
            observer.value.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(generation: changes.snapshot.generation), moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let reply = Unchecked(completionHandler)
        let snapshots = context.snapshots
        Task { reply.value(NSFileProviderSyncAnchor(generation: await snapshots.current().generation)) }
    }
}
