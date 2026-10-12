import DoveKit
import Foundation
import Observation

/// App-wide state: which backends are configured and how sources are routed.
@MainActor
@Observable
final class AppModel {
    let keychain = KeychainStore()
    private(set) var backends: [any LibraryBackend] = []

    /// Default backend for torrents and hoster links. NZBs always go to nzbdav.
    var preferredDebrid: BackendID = .torBox

    init() {
        reloadBackends()
    }

    /// Rebuilds backends from the Keychain. Call after credentials change.
    func reloadBackends() {
        var list: [any LibraryBackend] = []
        if let key = try? keychain.get(.torBoxAPIKey), !key.isEmpty {
            list.append(TorBoxBackend(apiKey: key))
        }
        if let key = try? keychain.get(.realDebridAPIKey), !key.isEmpty {
            list.append(RealDebridBackend(apiKey: key))
        }
        // TODO(stage-1): Offcloud once its adapter is implemented.
        // TODO(stage-3): nzbdav (URL, API key, WebDAV user and password).
        backends = list
    }

    var router: BackendRouter {
        BackendRouter(backends: backends, preferred: [.torrent: preferredDebrid, .hoster: preferredDebrid])
    }

    func backend(_ id: BackendID) -> (any LibraryBackend)? {
        backends.first { $0.id == id }
    }

    func backends(usenet: Bool) -> [any LibraryBackend] {
        backends.filter { $0.id.isUsenet == usenet }
    }
}
