import DoveAppCore
import DoveKit
import SwiftUI

/// Every Settings page. The iPhone's Settings list and the Mac's Settings sidebar show the same pages, in the same
/// sections and order, each opening the same form.
enum SettingsPage: Hashable {
    /// A service or a place: its own page (nzbdav, Calibre and iCloud Drive have theirs, debrids share one).
    case service(BackendID)
    case addService, routing, saveTo
    case addons, indexers, plugins
    case movies, books, music, games
    case player, reading
    case notifications, adult, storage, transfer, setup

    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .service(.nzbdav): NzbdavSettingsView()
        case .service(.calibre): CalibreSettingsView()
        case .service(.iCloudDrive): ICloudDriveSettingsView()
        case .service(let backend): DebridServiceView(backend: backend)
        case .addService: AddServiceView()
        case .routing: RoutingSettingsView()
        case .saveTo: DownloadSettingsView()
        case .addons: AddonsView()
        case .indexers: NewznabIndexersView()
        case .plugins: PluginsSettingsView()
        case .movies: TMDBSettingsView()
        case .books: BookMetadataSettingsView()
        case .music: MusicMetadataSettingsView()
        case .games: GameMetadataSettingsView()
        case .player: PlaybackSettingsView()
        case .reading: ReadingSettingsView()
        case .notifications: NotificationSettingsView()
        case .adult: AdultContentSettingsView()
        case .storage: StorageSettingsView()
        case .transfer: SettingsTransferView()
        case .setup: SetupLauncher()
        }
    }
}

/// One row: a page with its icon and its state on the right.
struct SettingsEntry: Identifiable {
    let page: SettingsPage
    let title: String
    let symbol: String
    let color: Color
    var value: String?
    /// A status light before the value (services).
    var light: Color?

    var id: SettingsPage { page }
}

struct SettingsGroup: Identifiable {
    let title: String
    var footer: String?
    let entries: [SettingsEntry]

    var id: String { title }
}

/// The pages in their sections, with each one's state. Sections follow what Dove does: where files come from, where
/// they are kept, how they are found, how they are described, how they are used, then the app itself.
@MainActor
struct SettingsCatalog {
    let model: AppModel

    var groups: [SettingsGroup] {
        [services, libraries, search, metadata, playingAndReading, app]
    }

    /// "1.0.0 (1)".
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - Sections

    /// Services with a key; the rest wait under Add service. With none set up, every service is listed.
    private var services: SettingsGroup {
        var entries = shownServices.map { backend in
            SettingsEntry(page: .service(backend), title: backend.displayName, symbol: backend.settingsSymbol,
                          color: backend.settingsColor, value: serviceValue(backend), light: serviceLight(backend))
        }
        if hasConfiguredService && shownServices.count < BackendID.services.count {
            entries.append(SettingsEntry(page: .addService, title: "Add service", symbol: "plus", color: .gray))
        }
        entries.append(SettingsEntry(page: .routing, title: "Order and fallback", symbol: "arrow.triangle.branch",
                                     color: .gray, value: orderSummary))
        return SettingsGroup(
            title: "Services",
            footer: hasConfiguredService
                ? "Adds go to the first service in the order. If it fails, Dove tries the next one."
                : "Add a key for at least one service: that is where Dove sends torrents, links and NZBs.",
            entries: entries
        )
    }

    private var libraries: SettingsGroup {
        SettingsGroup(title: "Your libraries", footer: "Places that keep your files. Save to picks one for each kind of download.", entries: [
            SettingsEntry(page: .service(.iCloudDrive), title: "iCloud Drive", symbol: BackendID.iCloudDrive.settingsSymbol,
                          color: BackendID.iCloudDrive.settingsColor, value: model.iCloudState),
            SettingsEntry(page: .service(.calibre), title: "Calibre", symbol: BackendID.calibre.settingsSymbol,
                          color: BackendID.calibre.settingsColor, value: serviceValue(.calibre), light: serviceLight(.calibre)),
            SettingsEntry(page: .saveTo, title: "Save to", symbol: "tray.and.arrow.down.fill", color: .blue),
        ])
    }

    private var search: SettingsGroup {
        SettingsGroup(title: "Search", footer: "Where results come from. Indexers are searched from your phone.", entries: [
            SettingsEntry(page: .addons, title: "Stremio addons", symbol: "puzzlepiece.extension.fill", color: .indigo,
                          value: "\(model.addonEntries.count)"),
            SettingsEntry(page: .indexers, title: "Indexers", symbol: "list.bullet.rectangle.fill", color: .teal,
                          value: "\(model.newznabIndexers.filter(\.enabled).count)"),
            SettingsEntry(page: .plugins, title: "Plugins", symbol: "powerplug.fill", color: .mint, value: pluginsValue),
        ])
    }

    private var metadata: SettingsGroup {
        SettingsGroup(title: "Titles and covers", footer: "What describes a result or a library item: titles, covers, episodes, tracks.", entries: [
            SettingsEntry(page: .movies, title: "Movies and TV", symbol: "film.stack.fill", color: .purple,
                          value: model.addonSet.tmdb != nil ? "TMDB" : "Addons"),
            SettingsEntry(page: .books, title: "Books and audiobooks", symbol: "text.book.closed.fill", color: .orange),
            SettingsEntry(page: .music, title: "Music", symbol: "music.note.list", color: .pink,
                          value: AppleMusicCatalog.isEnabled ? "+ Apple Music" : "MusicBrainz"),
            SettingsEntry(page: .games, title: "Games", symbol: "gamecontroller.fill", color: .green,
                          value: model.igdbCredentials != nil ? "IGDB" : "Wikidata"),
        ])
    }

    private var playingAndReading: SettingsGroup {
        SettingsGroup(title: "Playing and reading", entries: [
            SettingsEntry(page: .player, title: "Player", symbol: "play.fill", color: .red, value: model.playback.player.displayName),
            SettingsEntry(page: .reading, title: "Reading", symbol: "book.fill", color: .yellow, value: model.readIn?.displayName ?? "Ask"),
        ])
    }

    private var app: SettingsGroup {
        SettingsGroup(title: "App", footer: "Dove \(Self.version)", entries: [
            SettingsEntry(page: .notifications, title: "Notifications", symbol: "bell.badge.fill", color: .red),
            SettingsEntry(page: .adult, title: "Adult content", symbol: "eye.slash.fill", color: .purple,
                          value: model.showAdult ? "Shown" : "Hidden"),
            SettingsEntry(page: .storage, title: "Storage and Files", symbol: "internaldrive.fill", color: .gray),
            SettingsEntry(page: .transfer, title: "Export and import", symbol: "square.and.arrow.up.on.square.fill", color: .teal),
            SettingsEntry(page: .setup, title: "Set up Dove again", symbol: "wand.and.stars", color: .blue),
        ])
    }

    // MARK: - Values

    private var hasConfiguredService: Bool {
        BackendID.services.contains(where: model.isConfigured)
    }

    private var shownServices: [BackendID] {
        hasConfiguredService ? BackendID.services.filter(model.isConfigured) : BackendID.services
    }

    /// "213 days left" (debrids), "Online"/"Offline" from the last library refresh, or "Not set up".
    private func serviceValue(_ backend: BackendID) -> String {
        guard model.isConfigured(backend) else { return "Not set up" }
        if case .offline = model.services.health(of: backend) { return "Offline" }
        return model.services.accountSummary(backend) ?? "Connected"
    }

    private func serviceLight(_ backend: BackendID) -> Color? {
        model.isConfigured(backend) ? model.services.light(backend) : nil
    }

    /// The service torrents go to first; the full order is one tap away.
    private var orderSummary: String? {
        model.debridOrder.first(where: model.isConfigured).map { "\($0.displayName) first" }
    }

    private var pluginsValue: String {
        if model.plugins.updatesAvailable > 0 { return "\(model.plugins.updatesAvailable) to update" }
        return model.plugins.installed.isEmpty ? "None" : "\(model.plugins.installed.count)"
    }
}
