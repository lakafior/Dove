import AVFoundation
import DoveKit
import Foundation
import Observation

/// App-wide state: which backends are configured and how sources are routed.
@MainActor
@Observable
public final class AppModel {
    /// The platform the app runs on: system services and the integrations it keeps current.
    public let platform: any AppPlatform
    /// Shared with the share extension through the `keychain-access-groups` entitlement.
    public let keychain = SharedConfiguration.keychain()
    public let library = LibraryModel()
    /// Plugin repositories and installed plugins (`docs/plugins.md`).
    public let plugins = PluginsModel(store: PluginStore(
        keychain: SharedConfiguration.keychain(),
        scriptsDirectory: URL.applicationSupportDirectory.appending(path: "Dove/Plugins")
    ))
    /// New and missing episodes, and releases worth replacing.
    public let review = LibraryReviewModel()
    /// Movies and series saved for later.
    public let watchlist = WatchlistModel(keychain: SharedConfiguration.keychain())
    /// Online/offline from library refreshes, and premium days left.
    public let services = ServiceStatusModel()
    /// The player links go to (Infuse, VLC, Kodi…).
    public let playback: PlaybackModel
    /// Audiobooks play in Dove (`AudiobookPlayer`); everything else goes to the chosen player.
    public let audiobook: AudiobookPlayer
    /// Measured download speed per service, on this device.
    public let speed = SpeedTestModel()
    public private(set) var backends: [any LibraryBackend] = []

    /// A magnet or file opened from another app; RootView shows the add sheet for it.
    public var openedSource: SourceBatch?

    /// The model of the running app, for App Intents and the scene delegate (Quick Actions), which SwiftUI's
    /// environment does not reach. Set once in `init`; `AppDelegate` keeps it alive.
    public private(set) static weak var current: AppModel?

    /// Where Siri, Spotlight, Quick Actions, widgets and the home screen send the user.
    public enum Destination {
        case search(String?)
        case title(id: String)
        case book(id: String)
        case media(MediaSummary)
        case watchlist
        case downloads
        /// The Library, filtered to a category when one is given (a shelf tapped on the home screen).
        case library(LibraryFilter.Category?)
        case settings
    }

    /// A link to a title's page (IMDb, Apple TV, Letterboxd…): its screen with sources, or a search for its name
    /// when nothing resolves it.
    public func openTitle(_ link: TitleLink) async {
        // Opened from the share sheet at launch: the addons (and TMDB) may not be loaded yet.
        if !addonSet.canSearch { await loadAddons() }
        if let media = await addonSet.resolve(link) {
            show(.media(media))
        } else {
            show(.search(link.searchText))
        }
    }

    public func show(_ destination: Destination) {
        platform.show(destination)
    }

    /// Handles `onOpenURL`. Copies iOS made into Documents/Inbox are removed once read,
    /// so they do not pile up next to downloads in Files.
    public func open(_ url: URL) {
        if DeepLink.open(url, using: self) { return }
        openedSource = SourceDetector.source(opening: url).map { SourceBatch([$0]) }
        if url.isFileURL, url.deletingLastPathComponent().lastPathComponent == "Inbox",
           url.resolvingSymlinksInPath().path.hasPrefix(URL.documentsDirectory.resolvingSymlinksInPath().path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static let downloadSessionID = "net.smigi.dove.downloads"
    /// Finished files go to the platform's downloads folder (iOS: Documents, shown in Files).
    public let downloads: DownloadManager
    /// "Download only" adds: wait for the service, download, delete from the service. Set up in `init`.
    public private(set) var downloadJobs: DownloadJobs!
    /// Notifications and the Live Activity for phone downloads. Set up in `init`.
    @ObservationIgnored private var downloadAlerts: DownloadAlerts?

    /// Adds from search and the add sheet go through `downloadJobs` instead of staying in the library.
    public var downloadOnly = false {
        didSet { savePreferences() }
    }

    /// Debrid priority, highest first. "Automatic" adds try them in this order and fall through on any error.
    /// NZBs follow `usenetOrder`. Not a secret; in the Keychain so the share extension and iCloud Keychain see it.
    public var debridOrder: [BackendID] {
        didSet { SharedConfiguration.saveDebridOrder(debridOrder, to: keychain) }
    }

    /// NZB priority, highest first: nzbdav, TorBox and Offcloud (the last two only with Usenet on). Stored like
    /// `debridOrder`.
    public var usenetOrder: [BackendID] {
        didSet { SharedConfiguration.saveUsenetOrder(usenetOrder, to: keychain) }
    }

    /// TorBox plan as `user/me` reported it (`refreshAccounts`) or as picked in Settings. Decides TorBox Usenet
    /// and whether TorBox may take private trackers' torrents. Kept in the Keychain for the share extension.
    public var torBoxPlan = TorBoxPlanSetting() {
        didSet {
            guard torBoxPlan != oldValue else { return }
            SharedConfiguration.saveTorBoxPlan(torBoxPlan, to: keychain)
            reloadBackends()
        }
    }

    /// Where private trackers' torrents go (Settings › Order and fallback › Private trackers).
    public var privateTrackers: PrivateTrackerTarget = .automatic {
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
    public var sourceFilter = SourceFilter() {
        didSet { savePreferences() }
    }

    /// AIOStreams config variant for Dove's searches (e.g. one without filters). Not a secret.
    public var aioStreamsVariant: String = "" {
        didSet {
            savePreferences()
            rebuildAddonSet()
        }
    }

    /// Adult items (Library, Files) and the Adult search category. Hidden by default.
    public var showAdult = false {
        didSet {
            guard showAdult != oldValue else { return }
            library.showAdult = showAdult
            plugins.showAdult = showAdult
            reloadBookMetadata()
            savePreferences()
            // The Files extension re-reads the preference when the working set is signalled.
            platform.libraryChanged()
        }
    }

    /// Which sources each search category asks (Search › Sources, and the same button on a source list).
    public var sourceSelection = SourceSelection() {
        didSet { savePreferences() }
    }

    /// Where "Read" sends ebooks (Settings › Reading); nil asks every time.
    public var readIn: ReadingTarget? = nil {
        didSet { savePreferences() }
    }

    /// Send to Kindle address; empty hides Kindle.
    public var kindleAddress = "" {
        didSet { savePreferences() }
    }

    /// Send-to-PocketBook address; empty hides PocketBook.
    public var pocketBookAddress = "" {
        didSet { savePreferences() }
    }

    /// Any other address books are mailed to; empty hides "E-mail".
    public var emailAddress = "" {
        didSet { savePreferences() }
    }

    public func mailAddress(for target: ReadingTarget) -> String {
        switch target {
        case .appleBooks: ""
        case .kindle: kindleAddress
        case .pocketBook: pocketBookAddress
        case .email: emailAddress
        }
    }

    /// Clearing the preferred target's address makes Read ask again.
    public func setMailAddress(_ address: String, for target: ReadingTarget) {
        switch target {
        case .appleBooks: return
        case .kindle: kindleAddress = address
        case .pocketBook: pocketBookAddress = address
        case .email: emailAddress = address
        }
        if address.isEmpty, readIn == target { readIn = nil }
    }

    /// Where downloads of each kind go by default (synced).
    /// Folders the user picked as places for downloads (this Mac only: a bookmark means nothing elsewhere).
    @ObservationIgnored public let pickedFolders = PickedFolders(fileURL: .applicationSupportDirectory.appending(path: "Dove/picked-folders.json"))
    /// `pickedFolders` as the views read it.
    public private(set) var folderPlaces: [PickedFolder] = []

    public var downloadDestinations = DownloadDestinations() {
        didSet { savePreferences() }
    }

    /// Mail targets are offered only with an address to send to.
    public var readingTargets: [ReadingTarget] {
        ReadingTarget.allCases.filter { !$0.isMail || !mailAddress(for: $0).isEmpty }
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
        preferences.pocketBookAddress = pocketBookAddress
        preferences.emailAddress = emailAddress
        preferences.downloadDestinations = downloadDestinations
        SharedConfiguration.savePreferences(preferences, to: keychain)
    }
    public static let debrids = SharedConfiguration.debrids

    /// Stremio addons in the user's order. Manifests load in the background (`loadAddons`).
    public private(set) var addonEntries: [AddonEntry] = []
    public private(set) var addonSet = AddonSet(addons: [])

    public struct AddonEntry: Identifiable {
        public let url: URL
        public var addon: StremioAddon?
        public var error: String?
        public var id: String { url.absoluteString }
        /// AIOStreams-shaped URL, and (once the manifest is in) an addon that actually serves streams.
        public var isAIOStreams: Bool {
            AIOStreamsSearch.instance(from: url) != nil && (addon?.manifest.provides("stream") ?? true)
        }
    }

    public init(platform: any AppPlatform) {
        defer { Self.current = self }
        self.platform = platform
        playback = PlaybackModel(keychain: SharedConfiguration.keychain(), platform: platform)
        audiobook = AudiobookPlayer(keychain: SharedConfiguration.keychain(), platform: platform)
        downloads = DownloadManager(
            configuration: DownloadManager.backgroundConfiguration(identifier: AppModel.downloadSessionID),
            directory: platform.downloadsDirectory,
            store: DownloadStore(directory: .applicationSupportDirectory.appending(path: "Dove/Downloads"))
        )
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
            pocketBookAddress = preferences.pocketBookAddress
            emailAddress = preferences.emailAddress
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
        library.onChange = { [weak platform] in platform?.libraryChanged() }
        reloadBackends()
        reloadNewznab()
        reloadBookMetadata()
        Task { await resolveICloud() }
        // Direct-download sites and Audiobookshelf providers became plugins (2026-10-19): their settings go.
        keychain.removeRetired(["directSources", "bookProviders"])
        plugins.showAdult = showAdult
        plugins.onChange = { [weak self] in self?.reloadBookMetadata() }
        reloadBookMetadata()
        Task { await plugins.refreshIndexes() }
        // Signing in or out of iCloud, or turning iCloud Drive off for Dove.
        NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.resolveICloud() }
        }
        addonEntries = storedAddonURLs().map { AddonEntry(url: $0) }
        downloads.requestProvider = { [weak self] record in
            guard let self else { throw CancellationError() }
            if let ref = record.plugin { return try await pluginRequest(for: ref) }
            if let ref = record.stream { return try await streamRequest(for: ref) }
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
        downloadAlerts = DownloadAlerts(downloads: downloads, jobs: downloadJobs, platform: platform)
        downloads.folderResolver = { [pickedFolders] id in pickedFolders.resolve(id) }
        folderPlaces = pickedFolders.all
        downloads.onSettled { [weak self] record in
            if record.state == .finished, record.destination == .iCloud { self?.iCloudFileArrived() }
        }
    }

    /// After an add in "download only" mode: hand the item to `downloadJobs`. Returns the message to show.
    public func startDownloadOnly(
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
    /// the file is filed by kind (author and title for books, platform and game for games, from the item's match),
    /// and the Library's iCloud place gets the same match.
    public func download(_ file: LibraryFile, of item: LibraryItem, to destination: DownloadDestination = .device) async throws {
        guard let backend = backend(item.backend) else { return }
        let request = try await backend.downloadRequest(itemID: item.id, fileID: file.id)
        var placement: LibraryFolderLayout.Placement?
        if destination == .iCloud {
            let shelf = library.shelf(item)
            let book = library.bookMatch(for: shelf)
            let game = library.gameMatch(for: shelf)
            let place = LibraryFolderLayout.placement(
                kind: shelf.kind, book: book, game: game, itemName: shelf.name, fileName: file.name, singleFile: item.files.count <= 1
            )
            placement = place
            rememberICloud(place, book: book, game: game, kind: shelf.kind)
        }
        try downloads.start(request, backend: item.backend, itemID: item.id, file: file, destination: destination, placement: placement)
    }

    /// Tells the Library what a file arriving in iCloud Drive will be: the book or game it was found for.
    private func rememberICloud(
        _ place: LibraryFolderLayout.Placement, book: BookSummary?, media: MediaSummary? = nil, game: GameSummary? = nil, kind: ContentKind
    ) {
        guard book != nil || media != nil || game != nil else { return }
        let itemPath = LibraryFolderLayout.isTwoLevel(kind) ? place.folder : "\(place.folder)/\(place.fileName)"
        library.recordAdded(AddedHint(releaseName: nil, media: media, book: book, game: game), backend: .iCloudDrive, itemIDs: ["folder:\(itemPath)"], infoHash: nil)
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
    public func exportSettings(includeSecrets: Bool) -> SettingsBackup {
        SettingsBackup.export(includeSecrets: includeSecrets) { try? keychain.get($0) }
    }

    /// Writes a settings file into the Keychain (merging: what the file lacks stays) and loads it everywhere.
    public func importSettings(_ backup: SettingsBackup) async throws -> SettingsBackup.ImportSummary {
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
            pocketBookAddress = preferences.pocketBookAddress
            emailAddress = preferences.emailAddress
            downloadDestinations = preferences.downloadDestinations
        }
        library.showAdult = showAdult
        playback.reloadKodi()
        audiobook.reloadPositions()
        watchlist.reload()
        plugins.load()
        reloadBackends()
        reloadNewznab()
        reloadBookMetadata()
        addonEntries = storedAddonURLs().map { AddonEntry(url: $0) }
        await loadAddons()
        await refreshAccounts(force: true)
        await library.refresh(using: self, afterChange: true)
    }

    /// Rebuilds backends from the Keychain. Call after credentials change.
    public func reloadBackends() {
        let calibre = SharedConfiguration.calibre(from: keychain)
        backends = SharedConfiguration.backends(from: keychain)
            + (iCloudFolder.map { [FolderBackend(directory: $0)] } ?? [])
            + (calibre.map { [$0] } ?? [])
        // Calibre's covers are `calibre://cover/…` URLs: fetched at the address that answers, with the login.
        var coverResolver: (@Sendable (URL) async throws -> URLRequest)?
        if let calibre {
            coverResolver = { url in try await calibre.coverRequest(for: url) }
        }
        let resolver = coverResolver
        Task { await ImageCache.shared.setResolver(for: CalibreBackend.coverScheme, resolver) }
        let hasServices = backends.contains { !$0.id.isStorage }
        Task { await platform.servicesChanged(hasServices: hasServices) }
    }

    // MARK: - iCloud Drive

    /// iCloud Drive › Dove on this device: nil until resolved, and when iCloud Drive is off, signed out, or the
    /// build lacks the iCloud entitlement (a sideloaded build signed by another team).
    public private(set) var iCloudFolder: URL?
    public private(set) var iCloudChecked = false

    /// Looks the container up off the main thread (the lookup may block), then lists it as a library place and
    /// lets downloads go there.
    public func resolveICloud() async {
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
    public func place(for kind: ContentKind) -> FilePlace {
        let chosen = downloadDestinations.place(for: kind)
        if isAvailable(chosen) { return chosen }
        let standard = DownloadDestinations.standard(for: kind)
        return isAvailable(standard) ? standard : .device
    }

    /// Every place a file can go from this device: downloads, then the services that fetch plain links.
    public var places: [FilePlace] {
        [.device] + (iCloudFolder == nil ? [] : [.iCloud]) + folderPlaces.map { FilePlace.download(.folder($0.id)) }
            + directLinkServices.map(FilePlace.service)
    }

    /// Remembers a folder the user chose (NSOpenPanel) as a place and returns it.
    @discardableResult
    public func addFolderPlace(_ url: URL) throws -> FilePlace {
        let folder = try pickedFolders.add(url)
        folderPlaces = pickedFolders.all
        return .download(.folder(folder.id))
    }

    /// Forgets a folder; the kinds that saved there fall back to their standard place.
    public func removeFolderPlace(_ id: String) {
        pickedFolders.remove(id)
        folderPlaces = pickedFolders.all
        for (kind, place) in downloadDestinations.chosen where place == .download(.folder(id)) {
            downloadDestinations.chosen[kind] = nil
        }
    }

    /// The place's name for a message or a picker: a folder's own name, else the generic one.
    public func placeName(of place: FilePlace) -> String {
        if case .download(let destination) = place { return placeName(of: destination) }
        return place.displayName
    }

    public func placeName(of destination: DownloadDestination) -> String {
        if case .folder(let id) = destination { return folderPlaces.first { $0.id == id }?.name ?? destination.displayName }
        return destination.displayName
    }

    /// The places for one kind: Calibre takes ebooks too (Dove downloads the file and adds it there).
    /// `place(for:)` to read, the user's choice to write: what Settings › Save to binds to.
    public subscript(destinationFor kind: ContentKind) -> FilePlace {
        get { place(for: kind) }
        set { downloadDestinations.set(newValue, for: kind) }
    }

    public func places(for kind: ContentKind) -> [FilePlace] {
        places + (kind == .books && backend(.calibre) != nil ? [.service(.calibre)] : [])
    }

    /// Configured services that fetch any HTTP link into their cloud, in the debrid priority order.
    public var directLinkServices: [BackendID] {
        let rank = { (id: BackendID) in self.debridOrder.firstIndex(of: id) ?? Int.max }
        return backends.filter(\.acceptsDirectLinks).map(\.id).sorted { rank($0) < rank($1) }
    }

    public func isAvailable(_ place: FilePlace) -> Bool {
        switch place {
        case .download(.device): true
        case .download(.iCloud): iCloudFolder != nil
        case .download(.folder(let id)): pickedFolders.isReachable(id)
        case .service(.calibre): backend(.calibre) != nil
        case .service(let id): backend(id)?.acceptsDirectLinks == true
        }
    }

    // MARK: - Calibre

    public enum CalibreAddOutcome {
        case added(format: String)
        /// Added, but Dove's description could not be set (the account may only read, the server failed).
        case addedWithoutDetails(format: String, reason: String)
        /// Calibre holds books it thinks are this one; nothing was added.
        case duplicates([String])

        public var message: String {
            switch self {
            case .added(let format): "Added to Calibre as \(format)."
            case .addedWithoutDetails(let format, let reason): "Added to Calibre as \(format), but its details could not be set: \(reason)"
            case .duplicates(let books): "Calibre may already have it (\(books.joined(separator: "; "))). Not added."
            }
        }
    }

    /// Adds a book file to Calibre, which files it under Author/Title; then the book Dove knows (a book screen's,
    /// a search's) replaces the title, authors and description Calibre read from the file, and its cover too when
    /// the file had none (the file's cover is the edition held). The Library is listed again afterwards.
    public func addToCalibre(file: URL, fileName: String, book: BookSummary?, allowDuplicate: Bool = false) async throws -> CalibreAddOutcome {
        guard let calibre = backend(.calibre) as? CalibreBackend else {
            throw BackendError.api(message: "Set up Calibre in Settings › Your libraries first.")
        }
        let format = BookFiles.format(of: fileName).uppercased()
        let result = try await calibre.addBook(file: file, fileName: fileName, allowDuplicate: allowDuplicate)
        guard let bookID = result.bookID else { return .duplicates(result.duplicates) }
        defer { Task { await library.refresh(using: self, afterChange: true) } }
        guard let book else { return .added(format: format) }
        let fileHasCover = (try? await calibre.item("calibre:\(bookID)"))?.book?.cover != nil
        let cover: Data? = if !fileHasCover, let url = book.cover { try? await ImageCache.shared.data(for: url) } else { nil }
        do {
            try await calibre.setMetadata(bookID: bookID, book: book, cover: cover)
            return .added(format: format)
        } catch {
            return .addedWithoutDetails(format: format, reason: error.localizedDescription)
        }
    }

    /// "Author - Title.ext" from the book Dove knows, else the file's own name.
    public static func calibreFileName(book: BookSummary?, fileName: String) -> String {
        let ext = BookFiles.format(of: fileName)
        guard let book, !ext.isEmpty else { return (fileName as NSString).lastPathComponent }
        let name = book.authors.first.map { LibraryFolderLayout.itemName(author: $0, title: book.title) } ?? book.title
        return "\(name).\(ext)"
    }

    // MARK: - Newznab indexers

    /// Usenet indexers searched from the phone. Their API keys make the list a Keychain item.
    public private(set) var newznabIndexers: [NewznabIndexer] = []
    /// Rebuilt whenever the list changes; usage and caps persist in its state file.
    public private(set) var newznab = NewznabSearch(indexers: [], stateURL: nil)
    private static let newznabStateURL = URL.applicationSupportDirectory.appending(path: "Dove/newznab.json")

    public func reloadNewznab() {
        newznabIndexers = SharedConfiguration.newznabIndexers(from: keychain)
        newznab = NewznabSearch(indexers: newznabIndexers, stateURL: Self.newznabStateURL)
    }

    /// The indexers a search in this category asks (enabled in Settings and picked in Sources).
    public func indexerIDs(for category: SearchCategory) -> Set<String> {
        sourceSelection.indexerIDs(in: category, from: newznabIndexers)
    }

    public func saveNewznabIndexers(_ indexers: [NewznabIndexer]) throws {
        try SharedConfiguration.saveNewznabIndexers(indexers, to: keychain)
        reloadNewznab()
    }

    public var router: BackendRouter {
        BackendRouter(backends: backends, order: debridOrder, usenetOrder: usenetOrder, hostLists: hostLists)
    }

    // MARK: - Hosters

    /// Which file hosters each service unlocks; hoster links skip services that do not (`BackendRouter.hostLists`).
    public private(set) var hostLists: [BackendID: HostList] = [:]
    @ObservationIgnored private let hostCatalog = HostCatalog(fileURL: HostCatalog.defaultURL)

    /// Loads the saved lists, then fetches those older than a day. At launch and before a hoster link is added.
    public func refreshHostLists(force: Bool = false) async {
        if hostLists.isEmpty { hostLists = await hostCatalog.snapshot }
        hostLists = await hostCatalog.refresh(backends, force: force)
    }

    /// Same priority list, but services that already have the release cached go first:
    /// adding there is instant and costs nothing.
    public func router(preferring cached: [BackendID]) -> BackendRouter {
        let first = debridOrder.filter(cached.contains)
        return BackendRouter(
            backends: backends,
            order: first + debridOrder.filter { !first.contains($0) },
            usenetOrder: usenetOrder,
            hostLists: hostLists
        )
    }

    /// Configured backends that can check cache status without adding anything (TorBox, Offcloud).
    public var cacheCheckers: [any CacheChecking] {
        backends.compactMap { $0 as? any CacheChecking }
    }

    public func backend(_ id: BackendID) -> (any LibraryBackend)? {
        backends.first { $0.id == id }
    }

    /// Where NZBs go first: the top of `usenetOrder` that takes NZBs (the router's order for NZBs).
    public var usenetBackend: BackendID? {
        nzbBackends.first?.id
    }

    /// Configured services that take NZBs, in `usenetOrder`.
    public var nzbBackends: [any LibraryBackend] {
        let rank = { (id: BackendID) in self.usenetOrder.firstIndex(of: id) ?? Int.max }
        return backends.filter { $0.supportedSources.contains(.nzb) }.sorted { rank($0.id) < rank($1.id) }
    }

    public func isConfigured(_ id: BackendID) -> Bool {
        backend(id) != nil
    }

    /// Plans and premium days (`ServiceStatusModel`); TorBox's plan also sets its Usenet and seeding.
    public func refreshAccounts(force: Bool = false) async {
        await services.loadAccounts(backends, force: force)
        if let account = services.accounts[.torBox], let plan = TorBoxPlan(account: account) {
            torBoxPlan.detected = plan
        }
        platform.accountsUpdated(self)
    }

    /// TorBox has a key and a plan that keeps seeding.
    public var torBoxSeeds: Bool {
        isConfigured(.torBox) && torBoxPlan.plan?.seedingTime != nil
    }

    /// Both seeding services are set up, so the user picks where private trackers' torrents go.
    public var canChoosePrivateTrackers: Bool {
        isConfigured(.debridLink) && torBoxSeeds
    }

    /// The Private trackers picker: Automatic sends them to Debrid-Link, so it shows as that.
    public var privateTrackersChoice: PrivateTrackerTarget {
        get { privateTrackers == .automatic ? .debridLink : privateTrackers }
        set { privateTrackers = newValue }
    }

    /// Services that take private trackers' torrents, in priority order.
    public var privateTrackerServices: [BackendID] {
        let allowed = Set(backends.filter(\.takesPrivateTorrents).map(\.id))
        return debridOrder.filter(allowed.contains)
    }

    /// Whether the service takes NZBs now (its toggle, and TorBox's plan).
    public func usenetEnabled(_ id: BackendID) -> Bool {
        backend(id)?.supportedSources.contains(.nzb) == true
    }

    /// TorBox stores "0" when turned off, so a Pro plan does not turn it back on; unset follows the plan.
    public func setUsenet(_ id: BackendID, enabled: Bool) {
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
    public func canReAdd(_ item: LibraryItem) -> Bool {
        LibraryActions.canReAdd(item, on: backend(item.backend))
    }

    /// Services "Move to" can send the item to: they take its kind of source and do not hold it already.
    /// Debrids in priority order; NZBs in the Usenet order (nzbdav, TorBox/Offcloud with Usenet on).
    public func moveTargets(for item: LibraryItem) -> [BackendID] {
        guard canReAdd(item), let kind = LibraryActions.sourceKind(of: item) else { return [] }
        return (kind == .nzb ? nzbBackends : backends(usenet: true) + backends(usenet: false))
            .filter { $0.id != item.backend && $0.supportedSources.contains(kind) }
            .map(\.id)
    }

    /// Where an NZB goes when `failing` cannot open its compressed archive: the next Usenet service in
    /// `usenetOrder` that is not a streaming server (nzbdav streams archives instead of unpacking them).
    public func compressedArchiveTarget(after failing: BackendID) -> BackendID? {
        nzbBackends.map(\.id).first { $0 != failing && $0 != .nzbdav }
    }

    /// Why none of these items can be added again or moved, for a disabled menu line.
    public func reAddBlocker(_ items: [LibraryItem]) -> String {
        items.count == 1 ? "No magnet or stored NZB: cannot be added again" : "No magnets or stored NZBs: cannot be added again"
    }

    /// Configured backends of one family, in priority order.
    public func backends(usenet: Bool) -> [any LibraryBackend] {
        let rank = { (id: BackendID) in self.debridOrder.firstIndex(of: id) ?? Int.max }
        return backends.filter { $0.id.isUsenet == usenet }.sorted { rank($0.id) < rank($1.id) }
    }

    // MARK: - Stremio addons

    /// Fetches every manifest in parallel. Call on launch and after the list changes.
    public func loadAddons() async {
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
    public func addAddon(_ text: String) async throws {
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

    public func removeAddons(at offsets: IndexSet) {
        addonEntries.remove(atOffsets: offsets)
        saveAddonURLs()
        rebuildAddonSet()
    }

    public func moveAddons(from source: IndexSet, to destination: Int) {
        addonEntries.move(fromOffsets: source, toOffset: destination)
        saveAddonURLs()
        rebuildAddonSet()
    }

    public var aioStreamsPassword: String {
        (try? keychain.get(.aioStreamsPassword)) ?? ""
    }

    /// Checks the password against the user's AIOStreams instance before keeping it. Empty removes it.
    public func saveAIOStreamsPassword(_ password: String) async throws {
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
    public private(set) var aioStreamsPasswordRevision = 0

    /// Variants defined in the user's AIOStreams configuration (needs the password).
    public func aioStreamsVariants() async throws -> [AIOStreamsSearch.Variant] {
        let password = aioStreamsPassword
        guard !password.isEmpty,
              let instance = aioStreamsInstance
        else { return [] }
        return try await AIOStreamsSearch(origin: instance.origin, uuid: instance.uuid, password: password).variants()
    }

    /// Adds Dove's unfiltered variant to the user's AIOStreams configuration and selects it.
    public func createUnfilteredAIOStreamsVariant() async throws {
        let password = aioStreamsPassword
        guard !password.isEmpty,
              let instance = aioStreamsInstance
        else { throw BackendError.api(message: "Save your AIOStreams password first.") }
        try await AIOStreamsSearch(origin: instance.origin, uuid: instance.uuid, password: password).saveDoveVariant()
        aioStreamsVariant = AIOStreamsSearch.unfilteredVariantID
    }

    // MARK: - Files from plugins

    /// The last file started from outside (a shared file page), shown at the top of Downloads.
    public var incomingDownloadMessage: String?

    /// Asks a plugin for a search row's or file page's file(s) and sends them to a place: downloaded (to iCloud
    /// Drive filed by `LibraryFolderLayout`), or handed to a service when the links need no headers. Torrents
    /// (magnets, `.torrent` files) go to a torrent service instead (`addTorrents`).
    public func getFile(
        from call: PluginCall, id: String, title: String? = nil, kind: ContentKind, book: BookSummary? = nil, media: MediaSummary? = nil,
        to place: FilePlace? = nil
    ) async -> String {
        let place = place ?? self.place(for: kind)
        do {
            // The browser's cookies ride along: a login or a captcha solved in the site's pages reaches the plugin.
            let links = try await PluginRunner(transport: BrowserCookieTransport()).resolve(call.manifest, script: call.script, settings: call.settings, id: id)
            if links.contains(where: \.isTorrent) {
                return try await addTorrents(links.filter(\.isTorrent), title: title, kind: kind, book: book, media: media, place: place)
            }
            switch place {
            case .service(.calibre):
                // Dove fetches the file (headers and all) and adds it: Calibre cannot fetch links itself.
                guard kind == .books else { throw PluginError("Calibre takes ebooks; pick This iPhone or iCloud Drive.") }
                guard links.count == 1, let link = links.first else {
                    throw PluginError("This result has \(links.count) files; Calibre takes one book file. Download it and add the format you want.")
                }
                let (temporary, response) = try await URLSession.shared.download(for: Self.request(for: link))
                defer { try? FileManager.default.removeItem(at: temporary) }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw PluginError("The site answered \(http.statusCode) for the file.")
                }
                let fileName = Self.calibreFileName(book: book, fileName: link.name)
                return try await addToCalibre(file: temporary, fileName: fileName, book: book).message
            case .service(let serviceID):
                guard links.allSatisfy(\.isPlain) else {
                    throw PluginError("Only Dove can download this file (\(call.manifest.name) needs extra headers): pick This iPhone or iCloud Drive.")
                }
                guard let backend = backend(serviceID), backend.acceptsDirectLinks else {
                    throw BackendError.api(message: "\(serviceID.displayName) is not set up, or does not fetch direct links.")
                }
                var itemIDs: [LibraryItem.ID] = []
                for link in links {
                    itemIDs += try await backend.addAll(.hosterURL(link.url), category: nil, privateTracker: false)
                }
                library.recordAdded(AddedHint(releaseName: title ?? links.first?.name, media: media, book: book), backend: serviceID, itemIDs: itemIDs, infoHash: nil)
                if kind == .books || kind == .audiobooks {
                    for itemID in itemIDs { library.setKind(kind, backend: serviceID, itemID: itemID) }
                }
                Task { await library.refresh(using: self, afterChange: true) }
                return "Sent to \(serviceID.displayName). It fetches the file into its cloud."
            case .download(let destination):
                let single = links.count == 1
                var rememberedPlace: LibraryFolderLayout.Placement?
                for (index, link) in links.enumerated() {
                    var name = link.name
                    var subfolder: String?
                    // iCloud files by the layout; on the device a release of several files (an album, an
                    // audiobook's parts) gets the same folder, rather than every file loose in Dove's root.
                    if destination == .iCloud || !single {
                        let place = LibraryFolderLayout.placement(
                            kind: kind, book: book, itemName: title ?? link.name, fileName: link.name, singleFile: single
                        )
                        name = place.fileName
                        subfolder = place.folder
                        if destination == .iCloud { rememberedPlace = rememberedPlace ?? place }
                    }
                    let ref = PluginFileRef(pluginID: call.id, fileID: single ? id : "\(id)#\(index)")
                    try downloads.start(Self.request(for: link), plugin: ref, name: name, size: link.size, destination: destination, subfolder: subfolder)
                }
                if let rememberedPlace { rememberICloud(rememberedPlace, book: book, media: media, kind: kind) }
                return single ? "Downloading to \(placeName(of: destination))." : "Downloading \(links.count) files to \(placeName(of: destination))."
            }
        } catch {
            return error.localizedDescription
        }
    }

    /// Torrents from a plugin (repack and ROM sites' magnets, `.torrent` files fetched here with the plugin's
    /// headers) go to a torrent service like an indexer's release: the picked place's service when it takes them,
    /// else the debrid priority ("Automatic"). With Download only on and This iPhone picked, Dove then fetches the
    /// files and removes the item from the service, as it does for search rows.
    private func addTorrents(
        _ links: [PluginLink], title: String?, kind: ContentKind, book: BookSummary?, media: MediaSummary?, place: FilePlace
    ) async throws -> String {
        var messages: [String] = []
        for link in links {
            let source: Source
            if let magnet = link.magnet {
                source = magnet
            } else {
                let (data, response) = try await URLSession.shared.data(for: Self.request(for: link))
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                    throw PluginError("The site did not give the .torrent file.")
                }
                source = .torrentFile(data: data, filename: link.name)
            }
            let backendID: BackendID
            let itemIDs: [LibraryItem.ID]
            if case .service(let serviceID) = place, let backend = backend(serviceID), backend.supports(source) {
                backendID = serviceID
                itemIDs = [try await backend.add(source, category: nil)]
            } else {
                let result = try await router(preferring: []).add(source)
                backendID = result.backend
                itemIDs = result.itemIDs
            }
            let hash = link.isTorrent ? InfoHash.fromMagnet(link.url.absoluteString) : nil
            library.recordAdded(AddedHint(releaseName: title ?? link.name, media: media, book: book), backend: backendID, itemIDs: itemIDs, infoHash: hash)
            // The plugin's category knows better than a repack's name (games classify as software otherwise).
            if kind != .other {
                for itemID in itemIDs { library.setKind(kind, backend: backendID, itemID: itemID) }
            }
            if downloadOnly, place == .download(.device) {
                messages.append(await startDownloadOnly(itemIDs[0], on: backendID, name: title ?? link.name, pick: .allVideos))
            } else {
                messages.append("Added to \(backendID.displayName).")
            }
        }
        Task { await library.refresh(using: self, afterChange: true) }
        return messages.joined(separator: "\n")
    }

    /// A fresh link for a retried plugin download (the file id with `#<index>` for one of several files).
    private func pluginRequest(for ref: PluginFileRef) async throws -> URLRequest {
        guard let call = plugins.calls(.resolve).first(where: { $0.id == ref.pluginID }) else {
            throw BackendError.api(message: "The plugin that found this file is off or removed.")
        }
        let parts = ref.fileID.split(separator: "#", maxSplits: 1).map(String.init)
        let links = try await PluginRunner(transport: BrowserCookieTransport()).resolve(call.manifest, script: call.script, settings: call.settings, id: parts[0])
        let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        guard links.indices.contains(index) else { throw PluginError("The plugin no longer lists this file.") }
        return Self.request(for: links[index])
    }

    private static func request(for link: PluginLink) -> URLRequest {
        var request = URLRequest(url: link.url)
        for (field, value) in link.headers { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    // MARK: - Direct files from stream addons

    /// Sends a source row's direct link (PenguPlay, AIOStreams HTTP) to a place: downloaded to this iPhone or
    /// iCloud Drive (a retry asks the addon again: links expire within hours), or handed to a service that
    /// fetches plain links. Links that need headers only Dove can download.
    public func getFile(
        _ candidate: StreamCandidate, type: MediaType, streamID: String, media: MediaSummary?, to place: FilePlace? = nil
    ) async -> String {
        guard let file = candidate.directFile else { return "This source can only be played." }
        let place = place ?? self.place(for: .video)
        do {
            switch place {
            case .service(let serviceID):
                guard file.isPlain else {
                    throw BackendError.api(message: "Only Dove can download this file (the addon needs extra headers): pick This iPhone or iCloud Drive.")
                }
                guard let backend = backend(serviceID), backend.acceptsDirectLinks else {
                    throw BackendError.api(message: "\(serviceID.displayName) is not set up, or does not fetch direct links.")
                }
                let itemIDs = try await backend.addAll(.hosterURL(file.url), category: nil, privateTracker: false)
                library.recordAdded(AddedHint(releaseName: file.fileName, media: media), backend: serviceID, itemIDs: itemIDs, infoHash: nil)
                Task { await library.refresh(using: self, afterChange: true) }
                return "Sent to \(serviceID.displayName). It fetches the file into its cloud."
            case .download(let destination):
                guard let ref = StreamFileRef(candidate: candidate, type: type, streamID: streamID) else {
                    return "This source can only be played."
                }
                var name = file.fileName
                var subfolder: String?
                if destination == .iCloud {
                    let placement = LibraryFolderLayout.placement(kind: .video, itemName: name, fileName: name, singleFile: true)
                    name = placement.fileName
                    subfolder = placement.folder
                    library.recordAdded(
                        AddedHint(releaseName: file.fileName, media: media), backend: .iCloudDrive,
                        itemIDs: ["folder:\(placement.folder)/\(placement.fileName)"], infoHash: nil
                    )
                }
                try downloads.start(file.request, stream: ref, name: name, destination: destination, subfolder: subfolder)
                return "Downloading to \(placeName(of: destination))."
            }
        } catch {
            return error.localizedDescription
        }
    }

    /// A fresh link for a retried addon download: the same addon asked again, the same file picked by name.
    private func streamRequest(for ref: StreamFileRef) async throws -> URLRequest {
        if !addonSet.hasStreams { await loadAddons() }
        let candidates = try await addonSet.streams(from: ref.source, type: ref.type, id: ref.streamID)
        guard let file = ref.pick(from: candidates) else {
            throw BackendError.api(message: "The addon no longer lists this file.")
        }
        return file.request
    }

    // MARK: - Book metadata

    public var googleBooksKey: String { (try? keychain.get(.googleBooksAPIKey)) ?? "" }
    public var hardcoverToken: String { (try? keychain.get(.hardcoverToken)) ?? "" }

    /// Album search for Music: MusicBrainz, plus the plugins with music metadata (they name `music` among their
    /// categories), plus Apple Music when it is on and allowed (Settings › Music).
    public var musicMetadata: MusicMetadata {
        let plugins: [any AlbumCatalog] = plugins.calls(.metadata, category: .music)
            .filter { $0.manifest.categories.contains(.music) }
            .map { PluginAlbumCatalog(call: $0) }
        return MusicMetadata(catalogs: plugins + (AppleMusicCatalog.isEnabled ? [AppleMusicCatalog()] : []))
    }

    /// The book metadata sources for this device's region, with the user's keys and plugins.
    public var bookMetadataConfiguration: BookMetadata.Configuration {
        .device(googleBooksKey: googleBooksKey, hardcoverToken: hardcoverToken, plugins: plugins.calls(.metadata))
    }

    public func reloadBookMetadata() {
        library.bookMetadata = BookMetadata(configuration: bookMetadataConfiguration)
    }

    /// Checks the key with one search before keeping it. Empty removes it.
    public func saveGoogleBooksKey(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { try await BookMetadata().validateGoogleBooks(key: key) }
        try keychain.set(key, for: .googleBooksAPIKey)
        reloadBookMetadata()
    }

    /// Checks the token (`me`) before keeping it. Empty removes it.
    public func saveHardcoverToken(_ token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { try await BookMetadata().validateHardcover(token: token) }
        try keychain.set(token, for: .hardcoverToken)
        reloadBookMetadata()
    }

    // MARK: - Game metadata

    public var igdbClientID: String { (try? keychain.get(.igdbClientID)) ?? "" }
    public var igdbClientSecret: String { (try? keychain.get(.igdbClientSecret)) ?? "" }

    /// The user's Twitch app for IGDB, when both halves are set.
    public var igdbCredentials: GameMetadata.IGDBCredentials? {
        let id = igdbClientID, secret = igdbClientSecret
        return id.isEmpty || secret.isEmpty ? nil : GameMetadata.IGDBCredentials(clientID: id, clientSecret: secret)
    }

    /// Game search for Games: IGDB with the user's Twitch app, Wikidata, which needs no key, and the plugins with
    /// game metadata (they name `games` among their categories).
    public var gameMetadata: GameMetadata {
        let plugins: [any GameCatalog] = plugins.calls(.metadata, category: .games)
            .filter { $0.manifest.categories.contains(.games) }
            .map { PluginGameCatalog(call: $0) }
        return GameMetadata(igdb: igdbCredentials, catalogs: plugins)
    }

    /// Checks the Twitch app with a token and one IGDB search before keeping it. Both empty removes it.
    public func saveIGDB(clientID: String, clientSecret: String) async throws {
        let credentials = GameMetadata.IGDBCredentials(clientID: clientID, clientSecret: clientSecret)
        switch (credentials.clientID.isEmpty, credentials.clientSecret.isEmpty) {
        case (true, true): break
        case (false, false): try await GameMetadata(igdb: credentials, usesWikidata: false).validateIGDB()
        default: throw BackendError.api(message: "Both the Client ID and the Client Secret are needed.")
        }
        try keychain.set(credentials.clientID, for: .igdbClientID)
        try keychain.set(credentials.clientSecret, for: .igdbClientSecret)
    }

    // MARK: - TMDB

    public var tmdbKey: String {
        (try? keychain.get(.tmdbAPIKey)) ?? ""
    }

    /// Checks the key (v3 API key or v4 read access token) before keeping it. Empty removes it.
    public func saveTMDBKey(_ key: String) async throws {
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
