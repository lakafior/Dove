import Foundation

/// Picks the backend for a source. The source type decides the family
/// (torrent/hoster go to debrid, NZB goes to nzbdav); the user's preference decides within it.
public struct BackendRouter: Sendable {
    public var backends: [any LibraryBackend]
    public var preferred: [SourceKind: BackendID]

    public init(backends: [any LibraryBackend], preferred: [SourceKind: BackendID] = [:]) {
        self.backends = backends
        self.preferred = preferred
    }

    public func candidates(for source: Source) -> [any LibraryBackend] {
        backends.filter { $0.supports(source) }
    }

    public func backend(for source: Source) throws -> any LibraryBackend {
        let candidates = candidates(for: source)
        if let preferredID = preferred[source.kind],
           let match = candidates.first(where: { $0.id == preferredID }) {
            return match
        }
        guard let first = candidates.first else {
            throw BackendError.unsupportedSource(source.kind)
        }
        return first
    }
}
