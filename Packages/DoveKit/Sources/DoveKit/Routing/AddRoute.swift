import Foundation

/// What "Add" sends for a source row, and through which router.
///
/// A private tracker's release that a torrent service already has cached goes there as a bare magnet:
/// nothing is downloaded, so the tracker never sees the passkey, the user's ratio does not move, and nothing
/// has to seed. Otherwise an indexer's "private" limits the add to services that seed (`forPrivateTracker`),
/// with the indexer's `.torrent` so the service announces with the user's passkey.
public struct AddRoute: Sendable {
    public var source: Source
    public var router: BackendRouter
    /// Passed to `LibraryBackend.add(_:category:privateTracker:)` for a pick by hand (TorBox seeds then).
    public var privateTracker: Bool { router.seedingOnly }
}

extension StreamGroup {
    /// Automatic: cached private releases as a magnet to the services that have them, the rest as usual.
    public func route(through router: BackendRouter) -> AddRoute? {
        cachedPrivateRoute(through: router) ?? regularRoute(through: router)
    }

    /// "Add only to <backend>": a service that has a private release cached gets the magnet, any other the usual source.
    public func route(to backend: BackendID, through router: BackendRouter) -> AddRoute? {
        if cachedTorrentBackends.contains(backend), let route = cachedPrivateRoute(through: router.only([backend])) {
            return route
        }
        return regularRoute(through: router)
    }

    /// Services the "Add only to" menu offers, in the router's order: the usual candidates plus, for a private
    /// release, services that have it cached even though they do not seed.
    public func addTargets(through router: BackendRouter) -> [BackendID] {
        var ids: [BackendID] = []
        for route in [cachedPrivateRoute(through: router), regularRoute(through: router)].compactMap({ $0 }) {
            ids += route.router.candidates(for: route.source).map(\.id)
        }
        var seen = Set<BackendID>()
        let rank = { (id: BackendID) in router.order.firstIndex(of: id) ?? router.order.count }
        return ids.filter { seen.insert($0).inserted }.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private func regularRoute(through router: BackendRouter) -> AddRoute? {
        librarySource.map { AddRoute(source: $0, router: router.forPrivateTracker(isPrivate == true)) }
    }

    private func cachedPrivateRoute(through router: BackendRouter) -> AddRoute? {
        guard isPrivate == true, let infoHash, !cachedTorrentBackends.isEmpty else { return nil }
        let route = AddRoute(
            source: .magnet(infoHash: infoHash, name: releaseName),
            router: router.only(cachedTorrentBackends).forPrivateTracker(false)
        )
        return route.router.candidates(for: route.source).isEmpty ? nil : route
    }
}
