import AVFoundation
import DoveKit
import Foundation
import Observation
import SwiftUI

/// App-wide state: which backends are configured and how sources are routed.
@MainActor
@Observable
final class AppModel {
    /// Shared with the share extension through the `keychain-access-groups` entitlement.
    let keychain = SharedConfiguration.keychain()
    let library = LibraryModel()
    /// New and missing episodes, and releases worth replacing.
    let review = LibraryReviewModel()
    /// Movies and series saved for later.
    let watchlist = WatchlistModel(keychain: SharedConfiguration.keychain())
    /// Online/offline from library refreshes, and premium days left.
    let services = ServiceStatusModel()
    /// The player links go to (Infuse, VLC, Kodi…).
    let playback = PlaybackModel(keychain: SharedConfiguration.keychain())
    /// Audiobooks play in Dove (`AudiobookPlayer`); everything else goes to the chosen player.
    let audiobook = AudiobookPlayer(keychain: SharedConfiguration.keychain())
    /// Measured download speed per service, on this device.
    let speed = SpeedTestModel()
    private(set) var backends: [any LibraryBackend] = []

    /// A magnet or file opened from another app; RootView shows the add sheet for it.
    var openedSource: SourceBatch?

    /// The tab on screen, so the home screen can send the user to Downloads or Settings.
    var selectedTab: AppTab = .search
    /// A shelf tapped on the home screen: the Library opens filtered to it, then clears this.
    var libraryCategoryRequest: LibraryFilter.Category?
    /// Words to search, from Siri, Shortcuts or a Quick Action; the Search tab runs it and clears this.
    var searchRequest: String?
    /// The Search tab's stack, so Spotlight and Quick Actions can open a title or the watchlist there.
    var searchPath = NavigationPath()

    /// The model of the running app, for App Intents and the scene delegate (Quick Actions), which SwiftUI's
    /// environment does not reach. Set once in `init`; `AppDelegate` keeps it alive.
    private(set) static weak var current: AppModel?

    /// Where Siri, Spotlight and Quick Actions send the user.
    enum Destination {
        case search(String?)
        case title(id: String)
        case book(id: String)
        case media(MediaSummary)
        case watchlist
        case downloads
    }

    /// A link to a title's page (IMDb, Apple TV, Letterboxd…): its screen with sources, or a search for its name
    /// when nothing resolves it.
    func openTitle(_ link: TitleLink) async {
        // Opened from the share sheet at launch: the addons (and TMDB) may not be loaded yet.
        if !addonSet.canSearch { await loadAddons() }
        if let media = await addonSet.resolve(link) {
            show(.media(media))
        } else {
            show(.search(link.searchText))
        }
    }

    func show(_ destination: Destination) {
        switch destination {
        case .downloads:
            selectedTab = .downloads
            return
        case .search(let text):
            searchPath = NavigationPath()
            searchRequest = text
        case .title(let id):
            searchPath = NavigationPath()
            searchPath.append(TitleRoute(id: id))
        case .book(let id):
            searchPath = NavigationPath()
            searchPath.append(BookRoute(id: id))
        case .media(let media):
            searchPath = NavigationPath()
            searchPath.append(media)
        case .watchlist:
            searchPath = NavigationPath()
            searchPath.append(WatchlistRoute())
        }
        selectedTab = .search
    }

    /// Handles `onOpenURL`. Copies iOS made into Documents/Inbox are removed once read,
    /// so they do not pile up next to downloads in Files.
    func open(_ url: URL) {
        if DeepLink.open(url, using: self) { return }
        openedSource = SourceDetector.source(opening: url).map { SourceBatch([$0]) }
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
    /// Notifications and the Live Activity for phone downloads. Set up in `init`.
    @ObservationIgnored private var downloadAlerts: DownloadAlerts?

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

    /// Which sources each search category asks (Search › Sources, and the same button on a source list).
    var sourceSelection = SourceSelection() {
        didSet { savePreferences() }
    }

    /// Where "Read" sends ebooks (Settings › Books); nil asks every time.
    var readIn: ReadingTarget? = nil {
        didSet { savePreferences() }
    }

    /// Send to Kindle address; empty hides Kindle.
    var kindleAddress = "" {
        didSet { savePreferences() }
    }

    /// Where downloads of each kind go by default (synced).
    var downloadDestinations = DownloadDestinations() {
        didSet { savePreferences() }
    }

    /// Kindle is offered only with an address to send to.
    var readingTargets: [ReadingTarget] {
        kindleAddress.isEmpty ? [.appleBooks] : ReadingTarget.allCases
    }

    /// Filters, variant and "download only" travel with the keys through iCloud Keychain.
    private func savePreferences() {
        var preferences = SyncedPreferences()
        preferences.downloadOnly = downloadOnly
        preferences.sourceFilter = sourceFilter
        preferences.aioStreamsVariant = aioStreamsVariant
        preferences.showAdult = showAdult
        preferences.sourceSelection = sourceSelection
        preferences.readIn = readIn
        preferences.kindleAddress = kindleAddress
        preferences.downloadDestinations = downloadDestinations
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
        defer { Self.current = self }
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
            sourceSelection = preferences.sourceSelection
            readIn = preferences.readIn
            kindleAddress = preferences.kindleAddress
            downloadDestinations = preferences.downloadDestinations
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
        reloadBookMetadata()
        Task { await resolveICloud() }
        // Signing in or out of iCloud, or turning iCloud Drive off for Dove.
        NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.resolveICloud() }
        }
        addonEntries = storedAddonURLs().map { AddonEntry(url: $0) }
        downloads.requestProvider = { [weak self] record in
            guard let self else { throw CancellationError() }
            if let direct = record.direct {
                return URLRequest(url: try await directLink(for: direct).url)
            }
            guard let id = record.backend, let backend = backend(id) else {
                throw BackendError.api(message: "\(record.backend?.displayName ?? "The service") is no longer configured.")
            }
            return try await backend.downloadRequest(itemID: record.itemID, fileID: record.fileID)
        }
        audiobook.assetProvider = { [weak self] item, track in
            guard let self else { throw CancellationError() }
            if let record = downloads.records.first(where: {
                $0.state == .finished && $0.isSameFile(backend: item.backend, itemID: item.id, fileID: track.fileID)
            }), let url = downloads.fileURL(for: record) {
                return AVURLAsset(url: url)
            }
            guard let backend = backend(item.backend) else {
                throw BackendError.api(message: "\(item.backend.displayName) is no longer configured.")
            }
            let request = try await backend.downloadRequest(itemID: item.id, fileID: track.fileID)
            guard let url = request.url else { throw BackendError.invalidResponse }
            // Not public API, but the long-standing way to send headers (nzbdav's WebDAV login) with AVPlayer.
            return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:]])
        }
        downloadJobs = DownloadJobs(
            store: DownloadJobStore(fileURL: .applicationSupportDirectory.appending(path: "Dove/Downloads/jobs.json")),
            downloads: downloads
        ) { [weak self] id in self?.backend(id) }
        downloadAlerts = DownloadAlerts(downloads: downloads, jobs: downloadJobs)
        downloads.onSettled { [weak self] record in
            if record.state == .finished, record.destination == .iCloud { self?.iCloudFileArrived() }
        }
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

    /// Asks the service for a link and starts downloading the file to this device or iCloud Drive. In iCloud
    /// the file is filed by kind (and author and title for books, from the item's match), and the Library's
    /// iCloud place gets the same match.
    func download(_ file: LibraryFile, of item: LibraryItem, to destination: DownloadDestination = .device) async throws {
        guard let backend = backend(item.backend) else { return }
        let request = try await backend.downloadRequest(itemID: item.id, fileID: file.id)
        var placement: LibraryFolderLayout.Placement?
        if destination == .iCloud {
            let shelf = library.shelf(item)
            let book = library.bookMatch(for: shelf)
            let place = LibraryFolderLayout.placement(
                kind: shelf.kind, book: book, itemName: shelf.name, fileName: file.name, singleFile: item.files.count <= 1
            )
            placement = place
            rememberICloud(place, book: book, kind: shelf.kind)
        }
        try downloads.start(request, backend: item.backend, itemID: item.id, file: file, destination: destination, placement: placement)
    }

    /// Tells the Library what a file arriving in iCloud Drive will be: the book it was found for.
    private func rememberICloud(_ place: LibraryFolderLayout.Placement, book: BookSummary?, kind: ContentKind) {
        guard let book else { return }
        let itemPath = LibraryFolderLayout.byAuthor(kind) ? place.folder : "\(place.folder)/\(place.fileName)"
        library.recordAdded(AddedHint(releaseName: nil, book: book), backend: .iCloudDrive, itemIDs: ["folder:\(itemPath)"], infoHash: nil)
    }

    /// Lists the Library again a moment after files land in iCloud Drive (once for a batch).
    private func iCloudFileArrived() {
        iCloudRefresh?.cancel()
        iCloudRefresh = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await library.refresh(using: self, afterChange: true)
        }
    }

    @ObservationIgnored private var iCloudRefresh: Task<Void, Never>?

    // MARK: - Settings file

    /// Every Keychain value as a settings file (`SettingsBackup`), with or without keys and passwords.
    func exportSettings(includeSecrets: Bool) -> SettingsBackup {
        SettingsBackup.export(includeSecrets: includeSecrets) { try? keychain.get($0) }
    }

    /// Writes a settings file into the Keychain (merging: what the file lacks stays) and loads it everywhere.
    func importSettings(_ backup: SettingsBackup) async throws -> SettingsBackup.ImportSummary {
        let keychain = keychain
        let summary = try backup.apply(read: { try? keychain.get($0) }) { try keychain.set($0, for: $1) }
        await reloadFromKeychain()
        return summary
    }

    /// Reads every setting kept in the Keychain again, as a launch would.
    private func reloadFromKeychain() async {
        debridOrder = SharedConfiguration.debridOrder(from: keychain)
        usenetOrder = SharedConfiguration.usenetOrder(from: keychain)
        torBoxPlan = SharedConfiguration.torBoxPlan(from: keychain)
        privateTrackers = SharedConfiguration.privateTrackers(from: keychain)
        if let preferences = SharedConfiguration.preferences(from: keychain) {
            downloadOnly = preferences.downloadOnly
            sourceFilter = preferences.sourceFilter
            aioStreamsVariant = preferences.aioStreamsVariant
            showAdult = preferences.showAdult
            sourceSelection = preferences.sourceSelection
            readIn = preferences.readIn
            kindleAddress = preferences.kindleAddress
            downloadDestinations = preferences.downloadDestinations
        }
        library.showAdult = showAdult
        playback.reloadKodi()
        audiobook.reloadPositions()
        watchlist.reload()
        reloadBackends()
        reloadNewznab()
        reloadBookMetadata()
        addonEntries = storedAddonURLs().map { AddonEntry(url: $0) }
        await loadAddons()
        await refreshAccounts(force: true)
        await library.refresh(using: self, afterChange: true)
    }

    /// Rebuilds backends from the Keychain. Call after credentials change.
    func reloadBackends() {
        backends = SharedConfiguration.backends(from: keychain) + (iCloudFolder.map { [FolderBackend(directory: $0)] } ?? [])
        let hasServices = backends.contains { !$0.id.isStorage }
        Task { await FilesLocation.update(hasServices: hasServices) }
    }

    // MARK: - iCloud Drive

    /// iCloud Drive › Dove on this device: nil until resolved, and when iCloud Drive is off, signed out, or the
    /// build lacks the iCloud entitlement (a sideloaded build signed by another team).
    private(set) var iCloudFolder: URL?
    private(set) var iCloudChecked = false

    /// Looks the container up off the main thread (the lookup may block), then lists it as a library place and
    /// lets downloads go there.
    func resolveICloud() async {
        let folder = await Task.detached(priority: .utility) {
            FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appending(path: "Documents")
        }.value
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        iCloudChecked = true
        guard folder != iCloudFolder else { return }
        iCloudFolder = folder
        downloads.iCloudDirectory = folder
        reloadBackends()
    }

    /// Where a file of this kind goes: the user's default, unless that place is gone (iCloud Drive unavailable,
    /// the service's key removed), then the kind's standard place, then this device.
    func place(for kind: ContentKind) -> FilePlace {
        let chosen = downloadDestinations.place(for: kind)
        if isAvailable(chosen) { return chosen }
        let standard = DownloadDestinations.standard(for: kind)
        return isAvailable(standard) ? standard : .device
    }

    /// Every place a file can go from this device: downloads, then the services that fetch plain links.
    var places: [FilePlace] {
        [.device] + (iCloudFolder == nil ? [] : [.iCloud]) + directLinkServices.map(FilePlace.service)
    }

    /// Configured services that fetch any HTTP link into their cloud, in the debrid priority order.
    var directLinkServices: [BackendID] {
        let rank = { (id: BackendID) in self.debridOrder.firstIndex(of: id) ?? Int.max }
        return backends.filter(\.acceptsDirectLinks).map(\.id).sorted { rank($0) < rank($1) }
    }

    func isAvailable(_ place: FilePlace) -> Bool {
        switch place {
        case .download(.device): true
        case .download(.iCloud): iCloudFolder != nil
        case .service(let id): backend(id)?.acceptsDirectLinks == true
        }
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

    /// The indexers a search in this category asks (enabled in Settings and picked in Sources).
    func indexerIDs(for category: SearchCategory) -> Set<String> {
        sourceSelection.indexerIDs(in: category, from: newznabIndexers)
    }

    func saveNewznabIndexers(_ indexers: [NewznabIndexer]) throws {
        try SharedConfiguration.saveNewznabIndexers(indexers, to: keychain)
        reloadNewznab()
    }

    var router: BackendRouter {
        BackendRouter(backends: backends, order: debridOrder, usenetOrder: usenetOrder, hostLists: hostLists)
    }

    // MARK: - Hosters

    /// Which file hosters each service unlocks; hoster links skip services that do not (`BackendRouter.hostLists`).
    private(set) var hostLists: [BackendID: HostList] = [:]
    @ObservationIgnored private let hostCatalog = HostCatalog(fileURL: HostCatalog.defaultURL)

    /// Loads the saved lists, then fetches those older than a day. At launch and before a hoster link is added.
    func refreshHostLists(force: Bool = false) async {
        if hostLists.isEmpty { hostLists = await hostCatalog.snapshot }
        hostLists = await hostCatalog.refresh(backends, force: force)
    }

    /// Same priority list, but services that already have the release cached go first:
    /// adding there is instant and costs nothing.
    func router(preferring cached: [BackendID]) -> BackendRouter {
        let first = debridOrder.filter(cached.contains)
        return BackendRouter(
            backends: backends,
            order: first + debridOrder.filter { !first.contains($0) },
            usenetOrder: usenetOrder,
            hostLists: hostLists
        )
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
        WidgetSnapshotWriter.update(using: self)
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
        case .premiumize: try? keychain.set(enabled ? nil : "0", for: .premiumizeUsenet)
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

    /// Where an NZB goes when `failing` cannot open its compressed archive: the next Usenet service in
    /// `usenetOrder` that is not a streaming server (nzbdav streams archives instead of unpacking them).
    func compressedArchiveTarget(after failing: BackendID) -> BackendID? {
        nzbBackends.map(\.id).first { $0 != failing && $0 != .nzbdav }
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

    // MARK: - Direct downloads

    /// Sites the user added for direct downloads (address and member key), in their order.
    var directSources: [DirectSource] {
        guard let json = try? keychain.get(.directSources) else { return [] }
        return (try? JSONDecoder().decode([DirectSource].self, from: Data(json.utf8))) ?? []
    }

    /// The account's fast downloads per source, from the last answer (this device only).
    var directQuotas: [String: DirectDownloadQuota] = {
        guard let data = UserDefaults.standard.data(forKey: "directQuotas") else { return [:] }
        return (try? JSONDecoder().decode([String: DirectDownloadQuota].self, from: data)) ?? [:]
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(directQuotas), forKey: "directQuotas") }
    }

    /// Checks the key (when the source is on) before keeping the list.
    func saveDirectSource(_ source: DirectSource) async throws {
        if source.enabled { try await DirectDownloadClient(source: source).validate() }
        var sources = directSources
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        try storeDirectSources(sources)
    }

    func removeDirectSources(_ ids: Set<String>) throws {
        try storeDirectSources(directSources.filter { !ids.contains($0.id) })
        directQuotas = directQuotas.filter { !ids.contains($0.key) }
    }

    private func storeDirectSources(_ sources: [DirectSource]) throws {
        let data = try JSONEncoder().encode(sources)
        try keychain.set(sources.isEmpty ? nil : String(decoding: data, as: UTF8.self), for: .directSources)
    }

    /// The last direct download started from outside (share sheet), shown at the top of Downloads.
    var directDownloadMessage: String?

    /// Enabled sites that serve a search category, in the user's order.
    func directSources(for category: SearchCategory) -> [DirectSource] {
        directSources.filter { $0.serves(category) }
    }

    /// The first enabled source; file pages from any host go through it.
    var directSource: DirectSource? { directSources.first(where: \.enabled) }

    private func directLink(for ref: DirectDownloadRef) async throws -> DirectDownloadLink {
        guard let source = directSources.first(where: { $0.id == ref.sourceID && $0.enabled }) ?? directSource else {
            throw BackendError.api(message: "No direct download site is set up. Add one in Settings › Direct downloads.")
        }
        let link = try await DirectDownloadClient(source: source).link(md5: ref.md5)
        if let quota = link.quota { directQuotas[source.id] = quota }
        return link
    }

    /// Downloads a file by its md5 through the first enabled source, straight to Downloads (no service, no
    /// cache). Returns the message to show.
    func startDirectDownload(
        md5: String,
        to place: FilePlace? = nil,
        kind: ContentKind = .books,
        book: BookSummary? = nil
    ) async -> String {
        let place = place ?? self.place(for: kind)
        guard let source = directSource else {
            return "Add a direct download site in Settings › Direct downloads first."
        }
        let ref = DirectDownloadRef(sourceID: source.id, md5: md5)
        do {
            let link = try await directLink(for: ref)
            let quota = link.quota?.left.map { " \($0) fast downloads left today." } ?? ""
            guard case .download(let destination) = place else {
                guard case .service(let id) = place else { return "" }
                return try await sendToService(link, md5: md5, service: id, kind: kind, book: book) + quota
            }
            var name = link.fileName(md5: md5)
            var subfolder: String?
            if destination == .iCloud {
                let place = LibraryFolderLayout.placement(kind: kind, book: book, itemName: name, fileName: name, singleFile: true)
                name = place.fileName
                subfolder = place.folder
                rememberICloud(place, book: book, kind: kind)
            }
            try downloads.start(URLRequest(url: link.url), direct: ref, name: name, destination: destination, subfolder: subfolder)
            return "Downloading to \(destination.displayName)." + quota
        } catch {
            return error.localizedDescription
        }
    }

    /// Hands a direct link to a service that fetches it into its cloud (`acceptsDirectLinks`); the Library then
    /// lists it like anything added there, matched to the book it was found for.
    private func sendToService(
        _ link: DirectDownloadLink, md5: String, service id: BackendID, kind: ContentKind, book: BookSummary?
    ) async throws -> String {
        guard let backend = backend(id), backend.acceptsDirectLinks else {
            throw BackendError.api(message: "\(id.displayName) is not set up, or does not fetch direct links.")
        }
        let itemIDs = try await backend.addAll(.hosterURL(link.url), category: nil, privateTracker: false)
        let name = link.fileName(md5: md5)
        library.recordAdded(AddedHint(releaseName: name, book: book), backend: id, itemIDs: itemIDs, infoHash: nil)
        if kind == .books || kind == .audiobooks {
            for itemID in itemIDs { library.setKind(kind, backend: id, itemID: itemID) }
        }
        Task { await library.refresh(using: self, afterChange: true) }
        return "Sent to \(id.displayName). It fetches the file into its cloud."
    }

    // MARK: - Book metadata

    var googleBooksKey: String { (try? keychain.get(.googleBooksAPIKey)) ?? "" }
    var hardcoverToken: String { (try? keychain.get(.hardcoverToken)) ?? "" }

    /// The user's Audiobookshelf metadata providers, in their order.
    var bookProviders: [BookProvider] {
        guard let json = try? keychain.get(.bookProviders) else { return [] }
        return (try? JSONDecoder().decode([BookProvider].self, from: Data(json.utf8))) ?? []
    }

    /// The book metadata sources for this device's region, with the user's keys and providers.
    var bookMetadataConfiguration: BookMetadata.Configuration {
        .device(googleBooksKey: googleBooksKey, hardcoverToken: hardcoverToken, providers: bookProviders)
    }

    /// Checks a new or changed provider (when it is on) with one search before keeping the list.
    func saveBookProvider(_ provider: BookProvider) async throws {
        if provider.enabled { try await BookMetadata().validate(provider) }
        var providers = bookProviders
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        try storeBookProviders(providers)
    }

    func removeBookProviders(_ ids: Set<String>) throws {
        try storeBookProviders(bookProviders.filter { !ids.contains($0.id) })
    }

    private func storeBookProviders(_ providers: [BookProvider]) throws {
        let data = try JSONEncoder().encode(providers)
        try keychain.set(providers.isEmpty ? nil : String(decoding: data, as: UTF8.self), for: .bookProviders)
        reloadBookMetadata()
    }

    func reloadBookMetadata() {
        library.bookMetadata = BookMetadata(configuration: bookMetadataConfiguration)
    }

    /// Checks the key with one search before keeping it. Empty removes it.
    func saveGoogleBooksKey(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { try await BookMetadata().validateGoogleBooks(key: key) }
        try keychain.set(key, for: .googleBooksAPIKey)
        reloadBookMetadata()
    }

    /// Checks the token (`me`) before keeping it. Empty removes it.
    func saveHardcoverToken(_ token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { try await BookMetadata().validateHardcover(token: token) }
        try keychain.set(token, for: .hardcoverToken)
        reloadBookMetadata()
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
