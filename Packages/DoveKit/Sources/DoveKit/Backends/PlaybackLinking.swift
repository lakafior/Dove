import Foundation

/// Backends whose download needs headers a player cannot send (nzbdav's WebDAV Basic Auth).
/// They give players a URL that carries the credentials itself.
public protocol PlaybackLinking: LibraryBackend {
    func playbackURL(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URL
}

/// Backends that can hand back the NZB an item was made from (nzbdav, InfiniDysk), so it can be added again
/// or to another Usenet service.
public protocol NZBProviding: LibraryBackend {
    /// Whether `nzb(of:)` can work for this item (it has a stored NZB).
    func providesNZB(for item: LibraryItem) -> Bool
    func nzb(of item: LibraryItem) async throws -> Source
    /// Re-queues a failed job on the server from its stored NZB. Returns the new item, or nil when the server
    /// cannot (older nzbdav), so the caller fetches the NZB and adds it itself.
    func retry(_ item: LibraryItem) async throws -> LibraryItem.ID?
}

extension LibraryBackend {
    /// A URL to play or share: the backend's playback link when it has one, the download URL otherwise.
    public func playbackURL(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URL {
        if let linking = self as? any PlaybackLinking {
            return try await linking.playbackURL(itemID: itemID, fileID: fileID)
        }
        guard let url = try await downloadRequest(itemID: itemID, fileID: fileID).url else {
            throw BackendError.invalidResponse
        }
        return url
    }
}
