import DoveKit
import Foundation
import Observation

/// App-wide state: which backends are configured and how sources are routed.
@MainActor
@Observable
final class AppModel {
    /// Shared with the share extension through the `keychain-access-groups` entitlement.
    let keychain = SharedConfiguration.keychain()
    let library = LibraryModel()
    private(set) var backends: [any LibraryBackend] = []

    /// A magnet or file opened from another app; RootView shows the add sheet for it.
    var openedSource: Source?

    /// Handles `onOpenURL`. Copies iOS made into Documents/Inbox are removed once read,
    /// so they do not pile up next to downloads in Files.
    func open(_ url: URL) {
        openedSource = SourceDetector.source(opening: url)
        if url.isFileURL, url.deletingLastPathComponent().lastPathComponent == "Inbox",
           url.resolvingSymlinksInPath().path.hasPrefix(URL.documentsDirectory.resolvingSymlinksInPath().path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static let downloadSessionID = "net.smigi.dove.downloads"
    /// Finished files go to Documents, which Files shows under On My iPhone › Dove.
    let downloads = DownloadManager(
        configuration: DownloadManager.backgroundConfiguration(identifier: AppModel.downloadSessionID),
        directory: .documentsDirectory,
        store: DownloadStore(directory: .applicationSupportDirectory.appending(path: "Dove/Downloads"))
    )
    /// "Download only" adds: wait for the service, download, delete from the service. Set up in `init`.
    private(set) var downloadJobs: DownloadJobs!

    private static let downloadOnlyKey = "addDownloadOnly"
    /// Adds from search and the add sheet go through `downloadJobs` instead of staying in the library.
    var downloadOnly = UserDefaults.standard.bool(forKey: AppModel.downloadOnlyKey) {
        didSet { UserDefaults.standard.set(downloadOnly, forKey: Self.downloadOnlyKey) }
    }

    /// Debrid priority, highest first. "Automatic" adds try them in this order and fall through on any error.
    /// NZBs always go to nzbdav. Not a secret, so it lives in UserDefaults.
    var debridOrder: [BackendID] {
        didSet { SharedConfiguration.saveDebridOrder(debridOrder, to: keychain) }
    }

    /// Where the order lived before the share extension needed it.
    private static let legacyOrderKey = "debridOrder"
    private static let migratedKey = "keychainMovedToSharedGroup"
    // v2: the default sort became "largest first"; older saves had "addon order" written in.
    private static let filterKey = "sourceFilter.v2"
    private static let variantKey = "aioStreamsVariant"

    /// Source list filters. Kept between screens and launches: "PL only, DV" is a standing preference.
    var sourceFilter = SourceFilter() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(sourceFilter), forKey: Self.filterKey) }
    }

    /// AIOStreams config variant for Dove's searches (e.g. one without filters). Not a secret.
    var aioStreamsVariant: String = "" {
        didSet {
            UserDefaults.standard.set(aioStreamsVariant, forKey: Self.variantKey)
            rebuildAddonSet()
        }
    }
    static let debrids = SharedConfiguration.debrids

    /// Stremio addons in the user's order. Manifests load in the background (`loadAddons`).
    private(set) var addonEntries: [AddonEntry] = []
    private(set) var addonSet = AddonSet(addons: [])

    struct AddonEntry: Identifiable {
        let url: URL
        var addon: StremioAddon?
        var error: String?
        var id: String { url.absoluteString }
        /// AIOStreams-shaped URL, and (once the manifest is in) an addon that actually serves streams.
        var isAIOStreams: Bool {
            AIOStreamsSearch.instance(from: url) != nil && (addon?.manifest.provides("stream") ?? true)
        }
    }

    init() {
        // Keys saved before the shared Keychain group existed move into it once, so the extension sees them.
        if SharedConfiguration.keychainGroup != nil, !UserDefaults.standard.bool(forKey: Self.migratedKey) {
            keychain.migrateToAccessGroup()
            if let legacy = UserDefaults.standard.stringArray(forKey: Self.legacyOrderKey) {
                SharedConfiguration.saveDebridOrder(legacy.compactMap(BackendID.init(rawValue:)), to: keychain)
            }
            UserDefaults.standard.set(true, forKey: Self.migratedKey)
        }
        debridOrder = SharedConfiguration.debridOrder(from: keychain)
        if let data = UserDefaults.standard.data(forKey: Self.filterKey),
           let filter = try? JSONDecoder().decode(SourceFilter.self, from: data) {
            sourceFilter = filter
        }
        aioStreamsVariant = UserDefaults.standard.string(forKey: Self.variantKey) ?? ""
        reloadBackends()
        reloadNewznab()
        addonEntries = storedAddonURLs().map { AddonEntry(url: $0) }
        downloads.requestProvider = { [weak self] record in
            guard let backend = self?.backend(record.backend) else {
                throw BackendError.api(message: "\(record.backend.displayName) is no longer configured.")
            }
            return try await backend.downloadRequest(itemID: record.itemID, fileID: record.fileID)
        }
        downloadJobs = DownloadJobs(
            store: DownloadJobStore(fileURL: .applicationSupportDirectory.appending(path: "Dove/Downloads/jobs.json")),
            downloads: downloads
        ) { [weak self] id in self?.backend(id) }
    }

    /// After an add in "download only" mode: hand the item to `downloadJobs`. Returns the message to show.
    func startDownloadOnly(
        _ itemID: LibraryItem.ID,
        on backend: BackendID,
        name: String,
        pick: DownloadJob.Pick
    ) async -> String {
        await downloadJobs.add(backend: backend, itemID: itemID, name: name, pick: pick)
        // Starts with "Added", which the search field takes as success.
        return "Added to \(backend.displayName). Dove downloads it to this iPhone, then removes it from \(backend.displayName)."
    }

    /// Asks the service for a link and starts downloading the file to the device.
    func download(_ file: LibraryFile, of item: LibraryItem) async throws {
        guard let backend = backend(item.backend) else { return }
        let request = try await backend.downloadRequest(itemID: item.id, fileID: file.id)
        try downloads.start(request, backend: item.backend, itemID: item.id, file: file)
    }

    /// Rebuilds backends from the Keychain. Call after credentials change.
    func reloadBackends() {
        backends = SharedConfiguration.backends(from: keychain)
    }

    // MARK: - Newznab indexers

    /// Usenet indexers searched from the phone. Their API keys make the list a Keychain item.
    private(set) var newznabIndexers: [NewznabIndexer] = []
    /// Rebuilt whenever the list changes; usage and caps persist in its state file.
    private(set) var newznab = NewznabSearch(indexers: [], stateURL: nil)
    private static let newznabStateURL = URL.applicationSupportDirectory.appending(path: "Dove/newznab.json")

    func reloadNewznab() {
        newznabIndexers = SharedConfiguration.newznabIndexers(from: keychain)
        newznab = NewznabSearch(indexers: newznabIndexers, stateURL: Self.newznabStateURL)
    }

    func saveNewznabIndexers(_ indexers: [NewznabIndexer]) throws {
        try SharedConfiguration.saveNewznabIndexers(indexers, to: keychain)
        reloadNewznab()
    }

    var router: BackendRouter {
        BackendRouter(backends: backends, order: debridOrder)
    }

    /// Same priority list, but services that already have the release cached go first:
    /// adding there is instant and costs nothing.
    func router(preferring cached: [BackendID]) -> BackendRouter {
        let first = debridOrder.filter(cached.contains)
        return BackendRouter(backends: backends, order: first + debridOrder.filter { !first.contains($0) })
    }

    /// Configured backends that can check cache status without adding anything (TorBox, Offcloud).
    var cacheCheckers: [any CacheChecking] {
        backends.compactMap { $0 as? any CacheChecking }
    }

    func backend(_ id: BackendID) -> (any LibraryBackend)? {
        backends.first { $0.id == id }
    }

    /// Where NZBs go: nzbdav first, then TorBox with a Usenet plan (the router's order for NZBs).
    var usenetBackend: BackendID? {
        let takesNZB = backends.filter { $0.supportedSources.contains(.nzb) }
        return (takesNZB.first { $0.id.isUsenet } ?? takesNZB.first)?.id
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
        (try? keychain.get(.aioStreamsPassword)) ?? ""
    }

    /// Checks the password against the user's AIOStreams instance before keeping it. Empty removes it.
    func saveAIOStreamsPassword(_ password: String) async throws {
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if !password.isEmpty {
            guard let instance = aioStreamsInstance else {
                throw BackendError.api(message: "Add your AIOStreams addon first.")
            }
            try await AIOStreamsSearch(origin: instance.origin, uuid: instance.uuid, password: password).validate()
        }
        try keychain.set(password, for: .aioStreamsPassword)
        aioStreamsPasswordRevision += 1
        rebuildAddonSet()
    }

    /// Bumped on every password save, so views that depend on it (the variant list) reload.
    private(set) var aioStreamsPasswordRevision = 0

    /// Variants defined in the user's AIOStreams configuration (needs the password).
    func aioStreamsVariants() async throws -> [AIOStreamsSearch.Variant] {
        let password = aioStreamsPassword
        guard !password.isEmpty,
              let instance = aioStreamsInstance
        else { return [] }
        return try await AIOStreamsSearch(origin: instance.origin, uuid: instance.uuid, password: password).variants()
    }

    /// Adds Dove's unfiltered variant to the user's AIOStreams configuration and selects it.
    func createUnfilteredAIOStreamsVariant() async throws {
        let password = aioStreamsPassword
        guard !password.isEmpty,
              let instance = aioStreamsInstance
        else { throw BackendError.api(message: "Save your AIOStreams password first.") }
        try await AIOStreamsSearch(origin: instance.origin, uuid: instance.uuid, password: password).saveDoveVariant()
        aioStreamsVariant = AIOStreamsSearch.unfilteredVariantID
    }

    /// The first AIOStreams addon in the list (by URL shape and manifest).
    private var aioStreamsInstance: (origin: URL, uuid: String, variant: String?)? {
        addonEntries.lazy.filter(\.isAIOStreams).compactMap { AIOStreamsSearch.instance(from: $0.url) }.first
    }

    private func rebuildAddonSet() {
        let addons = addonEntries.compactMap(\.addon)
        var search: AIOStreamsSearch?
        let password = aioStreamsPassword
        if !password.isEmpty, let instance = aioStreamsInstance {
            let variant = aioStreamsVariant.isEmpty ? instance.variant : aioStreamsVariant
            search = AIOStreamsSearch(origin: instance.origin, uuid: instance.uuid, password: password, variant: variant)
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
