import Foundation

/// Backends whose download needs headers a player cannot send (nzbdav's WebDAV Basic Auth).
/// They give players a URL that carries the credentials itself.
public protocol PlaybackLinking: LibraryBackend {
    func playbackURL(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URL
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
