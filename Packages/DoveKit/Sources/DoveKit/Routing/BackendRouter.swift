import Foundation

/// Picks the backend for a source. The source type decides the family
/// (torrent/hoster go to debrid, NZB goes to nzbdav and debrids with Usenet); the user's priority order decides within it.
/// A private tracker's `.torrent` only goes to services that seed (`LibraryBackend.supports`).
public struct BackendRouter: Sendable {
    public var backends: [any LibraryBackend]
    /// Highest priority first. Backends missing from the list keep their relative order after the listed ones.
    public var order: [BackendID]
    /// Priority for NZBs (Settings › Usenet › Priority). Empty: nzbdav first, then `order`.
    public var usenetOrder: [BackendID]
    /// Only services that seed: for releases an indexer says come from a private tracker, which may arrive
    /// as a bare magnet that `TorrentFile.isPrivate` cannot see.
    public var seedingOnly = false

    public init(backends: [any LibraryBackend], order: [BackendID] = [], usenetOrder: [BackendID] = []) {
        self.backends = backends
        self.order = order
        self.usenetOrder = usenetOrder
    }

    /// Compatible backends, in priority order. NZBs follow `usenetOrder`; without one they go to Usenet
    /// backends (nzbdav) before debrids that also take them (TorBox/Offcloud with Usenet on).
    public func candidates(for source: Source) -> [any LibraryBackend] {
        let compatible = backends.filter { $0.supports(source) && (!seedingOnly || $0.seedsTorrents) }
        let order = source.kind == .nzb && !usenetOrder.isEmpty ? usenetOrder : self.order
        let rank = { (id: BackendID) in order.firstIndex(of: id) ?? order.count }
        let family = { (id: BackendID) in source.kind == .nzb && usenetOrder.isEmpty && id.isUsenet ? 0 : 1 }
        return compatible.enumerated()
            .sorted { (family($0.element.id), rank($0.element.id), $0.offset) < (family($1.element.id), rank($1.element.id), $1.offset) }
            .map(\.element)
    }

    public func backend(for source: Source) throws -> any LibraryBackend {
        guard let first = candidates(for: source).first else { throw noCandidate(for: source) }
        return first
    }

    private func noCandidate(for source: Source) -> BackendError {
        (seedingOnly || source.isPrivateTorrent) && backends.contains { $0.supportedSources.contains(.torrent) }
            ? .privateTorrent
            : .unsupportedSource(source.kind)
    }

    /// This router limited to services that seed (see `seedingOnly`) when `privateTracker` is true.
    public func forPrivateTracker(_ privateTracker: Bool) -> BackendRouter {
        var router = self
        router.seedingOnly = privateTracker
        return router
    }

    public struct Failure: Sendable {
        public let backend: BackendID
        public let error: any Error
    }

    public struct AddResult: Sendable {
        public let backend: BackendID
        public let itemID: LibraryItem.ID
        /// Backends tried before the one that took the source, with what they answered.
        public let skipped: [Failure]
    }

    /// Tries compatible backends in priority order until one accepts the source.
    /// Any error moves on to the next backend, except cancellation. `category` files NZBs on nzbdav.
    public func add(_ source: Source, category: AddCategory? = nil) async throws -> AddResult {
        let candidates = candidates(for: source)
        guard !candidates.isEmpty else { throw noCandidate(for: source) }
        var failures: [Failure] = []
        for backend in candidates {
            try Task.checkCancellation()
            do {
                let id = try await backend.add(source, category: category)
                return AddResult(backend: backend.id, itemID: id, skipped: failures)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(Failure(backend: backend.id, error: error))
            }
        }
        throw RoutingError.allFailed(failures)
    }
}

public enum RoutingError: Error, LocalizedError {
    case allFailed([BackendRouter.Failure])

    public var errorDescription: String? {
        switch self {
        case .allFailed(let failures):
            failures
                .map { "\($0.backend.displayName): \($0.error.localizedDescription)" }
                .joined(separator: "\n")
        }
    }
}
