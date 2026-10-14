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
    /// Online/offline from library refreshes, and premium days left.
    let services = ServiceStatusModel()
    private(set) var backends: [any LibraryBackend] = []

    /// A magnet or file opened from another app; RootView shows the add sheet for it.
    var openedSource: Source?

    /// The tab on screen, so the home screen can send the user to Downloads or Settings.
    var selectedTab: AppTab = .search
    /// A shelf tapped on the home screen: the Library opens filtered to it, then clears this.
    var libraryCategoryRequest: LibraryFilter.Category?

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

    /// Adds from search and the add sheet go through `downloadJobs` instead of staying in the library.
    var downloadOnly = false {
        didSet { savePreferences() }
    }

    /// Debrid priority, highest first. "Automatic" adds try them in this order and fall through on any error.
    /// NZBs follow `usenetOrder`. Not a secret; in the Keychain so the share extension and iCloud Keychain see it.
    var debridOrder: [BackendID] {
        didSet { SharedConfiguration.saveDebridOrder(debridOrder, to: keychain) }
    }

    /// NZB priority, highest first: nzbdav, TorBox and Offcloud (the last two only with Usenet on). Stored like
    /// `debridOrder`.
    var usenetOrder: [BackendID] {
        didSet { SharedConfiguration.saveUsenetOrder(usenetOrder, to: keychain) }
    }

    /// TorBox plan as `user/me` reported it (`refreshAccounts`) or as picked in Settings. Decides TorBox Usenet
    /// and whether TorBox may take private trackers' torrents. Kept in the Keychain for the share extension.
    var torBoxPlan = TorBoxPlanSetting() {
        didSet {
            guard torBoxPlan != oldValue else { return }
            SharedConfiguration.saveTorBoxPlan(torBoxPlan, to: keychain)
            reloadBackends()
        }
    }

    /// Where private trackers' torrents go (Settings › Debrid › Private trackers).
    var privateTrackers: PrivateTrackerTarget = .automatic {
        didSet {
            guard privateTrackers != oldValue else { return }
            try? keychain.set(privateTrackers == .automatic ? nil : privateTrackers.rawValue, for: .privateTrackers)
            reloadBackends()
        }
    }

    /// Where the order lived before the share extension needed it.
    private static let legacyOrderKey = "debridOrder"
    private static let migratedKey = "keychainMovedToSharedGroup"
    /// Set once every Keychain item was rewritten as synchronizable (iCloud Keychain).
    private static let synchronizedKey = "keychainSynchronizable.v1"
    // Where preferences lived before they moved to the synced Keychain item.
    private static let legacyFilterKey = "sourceFilter.v2"
    private static let legacyVariantKey = "aioStreamsVariant"
    private static let legacyDownloadOnlyKey = "addDownloadOnly"

    /// Source list filters. Kept between screens and launches: "PL only, DV" is a standing preference.
    var sourceFilter = SourceFilter() {
        didSet { savePreferences() }
    }

    /// AIOStreams config variant for Dove's searches (e.g. one without filters). Not a secret.
    var aioStreamsVariant: String = "" {
        didSet {
            savePreferences()
            rebuildAddonSet()
        }
    }

    /// Adult items (Library, Files) and the Adult search category. Hidden by default.
    var showAdult = false {
        didSet {
            guard showAdult != oldValue else { return }
            library.showAdult = showAdult
            savePreferences()
            // The Files extension re-reads the preference when the working set is signalled.
            FilesLocation.libraryChanged()
        }
    }

    /// Filters, variant and "download only" travel with the keys through iCloud Keychain.
    private func savePreferences() {
        var preferences = SyncedPreferences()
        preferences.downloadOnly = downloadOnly
        preferences.sourceFilter = sourceFilter
        preferences.aioStreamsVariant = aioStreamsVariant
        preferences.showAdult = showAdult
        SharedConfiguration.savePreferences(preferences, to: keychain)
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
        // Items written before iCloud Keychain sync are rewritten as synchronizable, once.
        if !UserDefaults.standard.bool(forKey: Self.synchronizedKey) {
            keychain.migrateToAccessGroup()
            UserDefaults.standard.set(true, forKey: Self.synchronizedKey)
        }
        debridOrder = SharedConfiguration.debridOrder(from: keychain)
        usenetOrder = SharedConfiguration.usenetOrder(from: keychain)
        torBoxPlan = SharedConfiguration.torBoxPlan(from: keychain)
        privateTrackers = SharedConfiguration.privateTrackers(from: keychain)
        if let preferences = SharedConfiguration.preferences(from: keychain) {
            downloadOnly = preferences.downloadOnly
            sourceFilter = preferences.sourceFilter
            aioStreamsVariant = preferences.aioStreamsVariant
            showAdult = preferences.showAdult
        } else {
            // First launch of this build: bring the old UserDefaults values along, then save them synced.
            // A fresh install has none: it saves nothing, so it cannot overwrite preferences that iCloud
            // Keychain has not delivered yet.
            let defaults = UserDefaults.standard
            let legacyKeys = [Self.legacyDownloadOnlyKey, Self.legacyFilterKey, Self.legacyVariantKey]
            let hasLegacy = legacyKeys.contains { defaults.object(forKey: $0) != nil }
            downloadOnly = defaults.bool(forKey: Self.legacyDownloadOnlyKey)
            if let data = defaults.data(forKey: Self.legacyFilterKey),
               let filter = try? JSONDecoder().decode(SourceFilter.self, from: data) {
                sourceFilter = filter
            }
            aioStreamsVariant = defaults.string(forKey: Self.legacyVariantKey) ?? ""
            if hasLegacy { savePreferences() }
        }
        // didSet does not run for assignments in init.
        library.showAdult = showAdult
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
        let hasServices = !backends.isEmpty
        Task { await FilesLocation.update(hasServices: hasServices) }
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
        BackendRouter(backends: backends, order: debridOrder, usenetOrder: usenetOrder)
    }

    /// Same priority list, but services that already have the release cached go first:
    /// adding there is instant and costs nothing.
    func router(preferring cached: [BackendID]) -> BackendRouter {
        let first = debridOrder.filter(cached.contains)
        return BackendRouter(backends: backends, order: first + debridOrder.filter { !first.contains($0) }, usenetOrder: usenetOrder)
    }

    /// Configured backends that can check cache status without adding anything (TorBox, Offcloud).
    var cacheCheckers: [any CacheChecking] {
        backends.compactMap { $0 as? any CacheChecking }
    }

    func backend(_ id: BackendID) -> (any LibraryBackend)? {
        backends.first { $0.id == id }
    }

    /// Where NZBs go first: the top of `usenetOrder` that takes NZBs (the router's order for NZBs).
    var usenetBackend: BackendID? {
        nzbBackends.first?.id
    }

    /// Configured services that take NZBs, in `usenetOrder`.
    var nzbBackends: [any LibraryBackend] {
        let rank = { (id: BackendID) in self.usenetOrder.firstIndex(of: id) ?? Int.max }
        return backends.filter { $0.supportedSources.contains(.nzb) }.sorted { rank($0.id) < rank($1.id) }
    }

    func isConfigured(_ id: BackendID) -> Bool {
        backend(id) != nil
    }

    /// Plans and premium days (`ServiceStatusModel`); TorBox's plan also sets its Usenet and seeding.
    func refreshAccounts(force: Bool = false) async {
        await services.loadAccounts(backends, force: force)
        if let account = services.accounts[.torBox], let plan = TorBoxPlan(account: account) {
            torBoxPlan.detected = plan
        }
    }

    /// TorBox has a key and a plan that keeps seeding.
    var torBoxSeeds: Bool {
        isConfigured(.torBox) && torBoxPlan.plan?.seedingTime != nil
    }

    /// Both seeding services are set up, so the user picks where private trackers' torrents go.
    var canChoosePrivateTrackers: Bool {
        isConfigured(.debridLink) && torBoxSeeds
    }

    /// Services that take private trackers' torrents, in priority order.
    var privateTrackerServices: [BackendID] {
        let allowed = Set(backends.filter(\.takesPrivateTorrents).map(\.id))
        return debridOrder.filter(allowed.contains)
    }

    /// Whether the service takes NZBs now (its toggle, and TorBox's plan).
    func usenetEnabled(_ id: BackendID) -> Bool {
        backend(id)?.supportedSources.contains(.nzb) == true
    }

    /// TorBox stores "0" when turned off, so a Pro plan does not turn it back on; unset follows the plan.
    func setUsenet(_ id: BackendID, enabled: Bool) {
        switch id {
        case .torBox: try? keychain.set(enabled ? "1" : "0", for: .torBoxUsenet)
        case .offcloud: try? keychain.set(enabled ? "1" : nil, for: .offcloudUsenet)
        default: return
        }
        reloadBackends()
    }

    // MARK: - Re-adding and moving

    /// A torrent with its hash, or an NZB its service can hand back (nzbdav with the frontend key).
    func canReAdd(_ item: LibraryItem) -> Bool {
        LibraryActions.canReAdd(item, on: backend(item.backend))
    }

    /// Services "Move to" can send the item to: they take its kind of source and do not hold it already.
    /// Debrids in priority order; NZBs in the Usenet order (nzbdav, TorBox/Offcloud with Usenet on).
    func moveTargets(for item: LibraryItem) -> [BackendID] {
        guard canReAdd(item), let kind = LibraryActions.sourceKind(of: item) else { return [] }
        return (kind == .nzb ? nzbBackends : backends(usenet: true) + backends(usenet: false))
            .filter { $0.id != item.backend && $0.supportedSources.contains(kind) }
            .map(\.id)
    }

    /// Why none of these items can be added again or moved, for a disabled menu line.
    func reAddBlocker(_ items: [LibraryItem]) -> String {
        items.count == 1 ? "No magnet or stored NZB: cannot be added again" : "No magnets or stored NZBs: cannot be added again"
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

    // MARK: - TMDB

    var tmdbKey: String {
        (try? keychain.get(.tmdbAPIKey)) ?? ""
    }

    /// Checks the key (v3 API key or v4 read access token) before keeping it. Empty removes it.
    func saveTMDBKey(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { try await TMDBMetadata(key: key).validate() }
        try keychain.set(key, for: .tmdbAPIKey)
        rebuildAddonSet()
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
        let tmdbKey = tmdbKey
        addonSet = AddonSet(addons: addons, aioStreams: search, tmdb: tmdbKey.isEmpty ? nil : TMDBMetadata(key: tmdbKey))
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

enum AppTab: Hashable {
    case search, library, downloads, settings
}
