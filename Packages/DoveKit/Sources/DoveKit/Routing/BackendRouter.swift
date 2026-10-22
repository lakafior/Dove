import Foundation

/// Picks the backend for a source. The source type decides the family
/// (torrent/hoster go to debrid, NZB goes to nzbdav and debrids with Usenet); the user's priority order decides within it.
/// A private tracker's `.torrent` only goes to services that seed and that the user allows (`LibraryBackend.supports`).
public struct BackendRouter: Sendable {
    public var backends: [any LibraryBackend]
    /// Highest priority first. Backends missing from the list keep their relative order after the listed ones.
    public var order: [BackendID]
    /// Priority for NZBs (Settings › Order and fallback › NZBs). Empty: nzbdav first, then `order`.
    public var usenetOrder: [BackendID]
    /// Only services that seed: for releases an indexer says come from a private tracker, which may arrive
    /// as a bare magnet that `TorrentFile.isPrivate` cannot see.
    public var seedingOnly = false
    /// Which hosters each service unlocks (`HostCatalog`). Hoster links skip services whose list says no;
    /// a service without a list is still tried.
    public var hostLists: [BackendID: HostList] = [:]

    public init(
        backends: [any LibraryBackend],
        order: [BackendID] = [],
        usenetOrder: [BackendID] = [],
        hostLists: [BackendID: HostList] = [:]
    ) {
        self.backends = backends
        self.order = order
        self.usenetOrder = usenetOrder
        self.hostLists = hostLists
    }

    /// Compatible backends, in priority order. NZBs follow `usenetOrder`; without one they go to Usenet
    /// backends (nzbdav) before debrids that also take them (TorBox/Offcloud with Usenet on). Hoster links go only
    /// to services that unlock the site (`verdict`); `compatible(with:)` lists the rest too, for a manual pick.
    public func candidates(for source: Source) -> [any LibraryBackend] {
        compatible(with: source).filter { verdict(for: source, on: $0.id).isWorthTrying }
    }

    /// What a service's host list says about a hoster link: `.unknown` without a list, and for other sources.
    public func verdict(for source: Source, on backend: BackendID) -> HostVerdict {
        guard case .hosterURL(let url, _) = source, let list = hostLists[backend] else { return .unknown }
        return list.verdict(for: url)
    }

    /// Every service that takes this kind of source, in priority order, whatever its host list says.
    public func compatible(with source: Source) -> [any LibraryBackend] {
        let compatible = backends.filter { $0.supports(source) && (!seedingOnly || $0.takesPrivateTorrents) }
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
        if case .hosterURL(let url, _) = source, !compatible(with: source).isEmpty {
            return .api(message: "None of your services unlocks \(url.host() ?? "this site").")
        }
        return (seedingOnly || source.isPrivateTorrent) && backends.contains { $0.supportedSources.contains(.torrent) }
            ? .privateTorrent
            : .unsupportedSource(source.kind)
    }

    /// This router limited to services that seed (see `seedingOnly`) when `privateTracker` is true.
    public func forPrivateTracker(_ privateTracker: Bool) -> BackendRouter {
        var router = self
        router.seedingOnly = privateTracker
        return router
    }

    /// This router limited to the given services, keeping its order.
    public func only(_ ids: [BackendID]) -> BackendRouter {
        var router = self
        router.backends = backends.filter { ids.contains($0.id) }
        return router
    }

    public struct Failure: Sendable {
        public let backend: BackendID
        public let error: any Error
    }

    public struct AddResult: Sendable {
        public let backend: BackendID
        /// The first item; a folder link adds one per file (`itemIDs`).
        public var itemID: LibraryItem.ID { itemIDs[0] }
        public let itemIDs: [LibraryItem.ID]
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
                let ids = try await backend.addAll(source, category: category, privateTracker: seedingOnly)
                guard !ids.isEmpty else { throw BackendError.invalidResponse }
                return AddResult(backend: backend.id, itemIDs: ids, skipped: failures)
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
