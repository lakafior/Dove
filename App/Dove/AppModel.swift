import DoveKit
import Foundation
import Observation

/// App-wide state: which backends are configured and how sources are routed.
@MainActor
@Observable
final class AppModel {
    let keychain = KeychainStore()
    private(set) var backends: [any LibraryBackend] = []

    /// Debrid priority, highest first. "Automatic" adds try them in this order and fall through on any error.
    /// NZBs always go to nzbdav. Not a secret, so it lives in UserDefaults.
    var debridOrder: [BackendID] {
        didSet { UserDefaults.standard.set(debridOrder.map(\.rawValue), forKey: Self.orderKey) }
    }

    private static let orderKey = "debridOrder"
    static let debrids = BackendID.allCases.filter { !$0.isUsenet }

    /// Stremio addons in the user's order. Manifests load in the background (`loadAddons`).
    private(set) var addonEntries: [AddonEntry] = []
    private(set) var addonSet = AddonSet(addons: [])

    struct AddonEntry: Identifiable {
        let url: URL
        var addon: StremioAddon?
        var error: String?
        var id: String { url.absoluteString }
        var isAIOStreams: Bool { AIOStreamsSearch.instance(from: url) != nil }
    }

    init() {
        let stored = (UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []).compactMap(BackendID.init(rawValue:))
        // Keep the stored order, append services added in later versions.
        debridOrder = stored.filter(Self.debrids.contains) + Self.debrids.filter { !stored.contains($0) }
        reloadBackends()
        addonEntries = storedAddonURLs().map { AddonEntry(url: $0) }
    }

    /// Rebuilds backends from the Keychain. Call after credentials change.
    func reloadBackends() {
        var list: [any LibraryBackend] = []
        if let key = try? keychain.get(.realDebridAPIKey), !key.isEmpty {
            list.append(RealDebridBackend(apiKey: key))
        }
        if let key = try? keychain.get(.torBoxAPIKey), !key.isEmpty {
            list.append(TorBoxBackend(apiKey: key))
        }
        if let key = try? keychain.get(.offcloudAPIKey), !key.isEmpty {
            list.append(OffcloudBackend(apiKey: key))
        }
        // TODO(stage-3): nzbdav (URL, API key, WebDAV user and password).
        backends = list
    }

    var router: BackendRouter {
        BackendRouter(backends: backends, order: debridOrder)
    }

    func backend(_ id: BackendID) -> (any LibraryBackend)? {
        backends.first { $0.id == id }
    }

    func isConfigured(_ id: BackendID) -> Bool {
        backend(id) != nil
    }

    /// Configured backends of one family, in priority order.
    func backends(usenet: Bool) -> [any LibraryBackend] {
        let rank = { (id: BackendID) in self.debridOrder.firstIndex(of: id) ?? Int.max }
        return backends.filter { $0.id.isUsenet == usenet }.sorted { rank($0.id) < rank($1.id) }
    }

    // MARK: - Stremio addons

    /// Fetches every manifest in parallel. Call on launch and after the list changes.
    func loadAddons() async {
        let urls = addonEntries.map(\.url)
        let loaded = await withTaskGroup(of: (URL, Result<StremioAddon, any Error>).self) { group in
            for url in urls {
                group.addTask {
                    do { return (url, .success(try await StremioAddon.load(manifestURL: url))) }
                    catch { return (url, .failure(error)) }
                }
            }
            var results: [URL: Result<StremioAddon, any Error>] = [:]
            for await (url, result) in group { results[url] = result }
            return results
        }
        addonEntries = urls.map { url in
            switch loaded[url] {
            case .success(let addon): AddonEntry(url: url, addon: addon)
            case .failure(let error): AddonEntry(url: url, error: error.localizedDescription)
            case nil: AddonEntry(url: url)
            }
        }
        rebuildAddonSet()
    }

    /// Validates the manifest before saving, so a typo never lands in the list.
    func addAddon(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "stremio://", with: "https://")
        guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http" else {
            throw BackendError.api(message: "Paste the addon's manifest URL.")
        }
        guard !addonEntries.contains(where: { $0.url == url }) else { return }
        let addon = try await StremioAddon.load(manifestURL: url)
        addonEntries.append(AddonEntry(url: url, addon: addon))
        saveAddonURLs()
        rebuildAddonSet()
    }

    func removeAddons(at offsets: IndexSet) {
        addonEntries.remove(atOffsets: offsets)
        saveAddonURLs()
        rebuildAddonSet()
    }

    func moveAddons(from source: IndexSet, to destination: Int) {
        addonEntries.move(fromOffsets: source, toOffset: destination)
        saveAddonURLs()
        rebuildAddonSet()
    }

    var aioStreamsPassword: String {
        get { (try? keychain.get(.aioStreamsPassword)) ?? "" }
        set {
            try? keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: .aioStreamsPassword)
            rebuildAddonSet()
        }
    }

    private func rebuildAddonSet() {
        let addons = addonEntries.compactMap(\.addon)
        var search: AIOStreamsSearch?
        let password = aioStreamsPassword
        if !password.isEmpty, let instance = addonEntries.lazy.compactMap({ AIOStreamsSearch.instance(from: $0.url) }).first {
            search = AIOStreamsSearch(origin: instance.origin, uuid: instance.uuid, password: password)
        }
        addonSet = AddonSet(addons: addons, aioStreams: search)
    }

    private func storedAddonURLs() -> [URL] {
        guard let json = try? keychain.get(.stremioAddons),
              let strings = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
        else { return [] }
        return strings.compactMap(URL.init(string:))
    }

    private func saveAddonURLs() {
        let strings = addonEntries.map(\.url.absoluteString)
        guard let data = try? JSONEncoder().encode(strings) else { return }
        try? keychain.set(String(decoding: data, as: UTF8.self), for: .stremioAddons)
    }
}
