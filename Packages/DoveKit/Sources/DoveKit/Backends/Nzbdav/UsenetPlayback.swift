import Foundation

/// Play an NZB through a Usenet backend: add it, wait until the job is mounted, hand back the main video's URL.
///
/// Addon play links (AIOStreams → nzbdav) only answer once nzbdav has the job ready, and Infuse gives up
/// before that ("Server is not responding"). nzbdav needs seconds for a healthy release, so Dove waits
/// itself and gives Infuse a link that answers at once; a release with missing articles fails here, with
/// nzbdav's reason, instead of in the player.
public enum UsenetPlayback {
    public struct Prepared: Sendable, Equatable {
        public let itemID: LibraryItem.ID
        public let url: URL
    }

    /// - Parameters:
    ///   - itemID: a job added earlier (Play tapped twice); nil adds `source`, filed under `category`.
    public static func prepare(
        _ source: Source,
        itemID: LibraryItem.ID? = nil,
        category: AddCategory? = nil,
        on backend: any LibraryBackend,
        timeout: Duration = .seconds(120),
        interval: Duration = .seconds(2)
    ) async throws -> Prepared {
        let id: LibraryItem.ID
        if let itemID { id = itemID } else { id = try await backend.add(source, category: category) }
        let deadline = ContinuousClock.now + timeout
        while true {
            let item = try await backend.item(id)
            switch item.status {
            case .failed(let reason):
                throw BackendError.api(message: "\(backend.id.displayName) could not get this release: \(reason) Try another one.")
            case .ready:
                if let file = mainVideo(in: item.files) {
                    return Prepared(itemID: id, url: try await backend.playbackURL(itemID: id, fileID: file.id))
                }
            case .queued, .awaitingFileSelection, .downloading:
                break
            }
            guard ContinuousClock.now < deadline else {
                throw BackendError.api(message: "\(backend.id.displayName) is still preparing it. Try Play again in a moment, or open it from the Library.")
            }
            try await Task.sleep(for: interval)
        }
    }

    /// The largest video that is not a sample.
    static func mainVideo(in files: [LibraryFile]) -> LibraryFile? {
        files
            .filter { FileKind.isVideo($0.name) && !FileKind.isSample($0.name) }
            .max { ($0.size ?? 0) < ($1.size ?? 0) }
    }
}
