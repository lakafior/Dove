import DoveAppCore
import DoveKit
import SwiftUI

/// Only rows that open a page, each saying its state on the right; no switch or picker lives on this screen.
/// Sections follow what Dove does: where files come from, where they are kept, how they are found, how they are
/// described, how they are used, then the app itself. Everything about one service is on that service's page.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                services
                libraries
                search
                metadata
                playingAndReading
                app
            }
            .navigationTitle("Settings")
            .navigationDestination(for: BackendID.self) { backend in
                switch backend {
                case .nzbdav: NzbdavSettingsView()
                case .calibre: CalibreSettingsView()
                case .iCloudDrive: ICloudDriveSettingsView()
                default: DebridServiceView(backend: backend)
                }
            }
        }
    }

    // MARK: - Sections

    /// Services with a key; the rest wait under Add service. With none set up, every service is listed.
    private var services: some View {
        Section {
            ForEach(shownServices, id: \.self) { backend in
                NavigationLink(value: backend) {
                    SettingsRow(backend.displayName, symbol: backend.settingsSymbol, color: backend.settingsColor,
                                value: serviceValue(backend), light: serviceLight(backend))
                }
            }
            if hasConfiguredService && shownServices.count < BackendID.services.count {
                NavigationLink {
                    AddServiceView()
                } label: {
                    SettingsRow("Add service", symbol: "plus", color: .gray)
                }
            }
            NavigationLink {
                RoutingSettingsView()
            } label: {
                SettingsRow("Order and fallback", symbol: "arrow.triangle.branch", color: .gray, value: orderSummary)
            }
        } header: {
            Text("Services")
        } footer: {
            Text(hasConfiguredService
                 ? "Adds go to the first service in the order. If it fails, Dove tries the next one."
                 : "Add a key for at least one service: that is where Dove sends torrents, links and NZBs.")
        }
    }

    private var libraries: some View {
        Section {
            NavigationLink(value: BackendID.iCloudDrive) {
                SettingsRow("iCloud Drive", symbol: BackendID.iCloudDrive.settingsSymbol, color: BackendID.iCloudDrive.settingsColor,
                            value: model.iCloudState)
            }
            NavigationLink(value: BackendID.calibre) {
                SettingsRow("Calibre", symbol: BackendID.calibre.settingsSymbol, color: BackendID.calibre.settingsColor,
                            value: serviceValue(.calibre), light: serviceLight(.calibre))
            }
            NavigationLink {
                DownloadSettingsView()
            } label: {
                SettingsRow("Save to", symbol: "tray.and.arrow.down.fill", color: .blue)
            }
        } header: {
            Text("Your libraries")
        } footer: {
            Text("Places that keep your files. Save to picks one for each kind of download.")
        }
    }

    private var search: some View {
        Section {
            NavigationLink {
                AddonsView()
            } label: {
                SettingsRow("Stremio addons", symbol: "puzzlepiece.extension.fill", color: .indigo,
                            value: "\(model.addonEntries.count)")
            }
            NavigationLink {
                NewznabIndexersView()
            } label: {
                SettingsRow("Indexers", symbol: "list.bullet.rectangle.fill", color: .teal,
                            value: "\(model.newznabIndexers.filter(\.enabled).count)")
            }
            NavigationLink {
                PluginsSettingsView()
            } label: {
                SettingsRow("Plugins", symbol: "powerplug.fill", color: .mint, value: pluginsValue)
            }
        } header: {
            Text("Search")
        } footer: {
            Text("Where results come from. Indexers are searched from your phone.")
        }
    }

    private var metadata: some View {
        Section {
            NavigationLink {
                TMDBSettingsView()
            } label: {
                SettingsRow("Movies and TV", symbol: "film.stack.fill", color: .purple,
                            value: model.addonSet.tmdb != nil ? "TMDB" : "Addons")
            }
            NavigationLink {
                BookMetadataSettingsView()
            } label: {
                SettingsRow("Books and audiobooks", symbol: "text.book.closed.fill", color: .orange)
            }
            NavigationLink {
                MusicMetadataSettingsView()
            } label: {
                SettingsRow("Music", symbol: "music.note.list", color: .pink,
                            value: AppleMusicCatalog.isEnabled ? "+ Apple Music" : "MusicBrainz")
            }
            NavigationLink {
                GameMetadataSettingsView()
            } label: {
                SettingsRow("Games", symbol: "gamecontroller.fill", color: .green,
                            value: model.igdbCredentials != nil ? "IGDB" : "Wikidata")
            }
        } header: {
            Text("Titles and covers")
        } footer: {
            Text("What describes a result or a library item: titles, covers, episodes, tracks.")
        }
    }

    private var playingAndReading: some View {
        Section("Playing and reading") {
            NavigationLink {
                PlaybackSettingsView()
            } label: {
                SettingsRow("Player", symbol: "play.fill", color: .red, value: model.playback.player.displayName)
            }
            NavigationLink {
                ReadingSettingsView()
            } label: {
                SettingsRow("Reading", symbol: "book.fill", color: .yellow, value: model.readIn?.displayName ?? "Ask")
            }
        }
    }

    private var app: some View {
        Section {
            NavigationLink {
                NotificationSettingsView()
            } label: {
                SettingsRow("Notifications", symbol: "bell.badge.fill", color: .red)
            }
            NavigationLink {
                AdultContentSettingsView()
            } label: {
                SettingsRow("Adult content", symbol: "eye.slash.fill", color: .purple,
                            value: model.showAdult ? "Shown" : "Hidden")
            }
            NavigationLink {
                StorageSettingsView()
            } label: {
                SettingsRow("Storage and Files", symbol: "internaldrive.fill", color: .gray)
            }
            NavigationLink {
                SettingsTransferView()
            } label: {
                SettingsRow("Export and import", symbol: "square.and.arrow.up.on.square.fill", color: .teal)
            }
        } header: {
            Text("App")
        } footer: {
            Text("Dove \(Self.version)")
        }
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

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
