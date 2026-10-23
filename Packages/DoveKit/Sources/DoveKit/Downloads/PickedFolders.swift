import Foundation

/// A folder the user picked as a place for downloads (a NAS share, an external disk, a Plex or Jellyfin library): a
/// security-scoped bookmark, since the sandboxed Mac app may only reach a folder again through one.
public struct PickedFolder: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var bookmark: Data

    public init(id: String = UUID().uuidString, name: String, bookmark: Data) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
    }
}

/// The picked folders, kept in a file on this Mac (bookmarks mean nothing on another device, so they never sync), and
/// their resolved URLs. A resolved folder stays open for access until the app quits: downloads finish in the
/// background, long after the picker closed.
public final class PickedFolders: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var folders: [PickedFolder]
    private var open: [String: URL] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        folders = (try? JSONDecoder().decode([PickedFolder].self, from: Data(contentsOf: fileURL))) ?? []
    }

    public var all: [PickedFolder] {
        lock.withLock { folders }
    }

    public func folder(_ id: String) -> PickedFolder? {
        lock.withLock { folders.first { $0.id == id } }
    }

    /// Remembers a folder the user chose in the open panel. Choosing it again gives back the same entry.
    @discardableResult
    public func add(_ url: URL) throws -> PickedFolder {
        let bookmark = try Self.bookmark(for: url)
        return lock.withLock {
            if let index = folders.firstIndex(where: { Self.resolve($0.bookmark)?.url.standardizedFileURL == url.standardizedFileURL }) {
                folders[index].bookmark = bookmark
                save()
                return folders[index]
            }
            let folder = PickedFolder(name: url.lastPathComponent, bookmark: bookmark)
            folders.append(folder)
            save()
            return folder
        }
    }

    public func remove(_ id: String) {
        lock.withLock {
            folders.removeAll { $0.id == id }
            if let url = open.removeValue(forKey: id) { url.stopAccessingSecurityScopedResource() }
            save()
        }
    }

    /// The folder's URL with access opened, or nil when it cannot be reached (an unmounted disk, a deleted folder).
    public func resolve(_ id: String) -> URL? {
        lock.withLock {
            if let url = open[id], FileManager.default.fileExists(atPath: url.path) { return url }
            guard let index = folders.firstIndex(where: { $0.id == id }),
                  let (url, stale) = Self.resolve(folders[index].bookmark) else { return nil }
            guard url.startAccessingSecurityScopedResource() || !Self.isScoped else { return nil }
            guard FileManager.default.fileExists(atPath: url.path) else {
                url.stopAccessingSecurityScopedResource()
                return nil
            }
            if stale, let fresh = try? Self.bookmark(for: url) {
                folders[index].bookmark = fresh
                save()
            }
            open[id] = url
            return url
        }
    }

    /// Whether the folder can be reached now (without keeping it open).
    public func isReachable(_ id: String) -> Bool {
        resolve(id) != nil
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(folders).write(to: fileURL, options: .atomic)
    }

    #if os(macOS)
    private static let isScoped = true
    private static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    private static func resolve(_ bookmark: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }
    #else
    private static let isScoped = false
    private static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    private static func resolve(_ bookmark: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }
    #endif
}
