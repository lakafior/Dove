import DoveKit
import Foundation
import Observation

/// The watchlist (`Watchlist`, synced through the Keychain), what each entry is up to (`WatchlistStatus`), and a
/// local notification when one has news: new episodes, a movie out digitally. Checked after each library refresh,
/// so on launch and on pull: no background work. Series episode lists come from `LibraryReviewModel`; movie release
/// dates from TMDB, once every 12 h per movie. Never adds anything.
@MainActor
@Observable
final class WatchlistModel {
    private(set) var list: Watchlist
    /// By entry ID, kept on this device.
    private(set) var releases: [String: MovieRelease]

    private let keychain: KeychainStore
    private static let releasesURL = URL.applicationSupportDirectory.appending(path: "Dove/watchlist-releases.json")
    /// What each entry last announced (`WatchlistStatus.announcement`), so a notice goes out once.
    private static let announcedKey = "watchlistAnnounced"
    private var announced: [String: String]
    private static let releaseAge: TimeInterval = 12 * 3600

    init(keychain: KeychainStore) {
        self.keychain = keychain
        list = Watchlist.load(from: keychain)
        releases = (try? JSONDecoder().decode([String: MovieRelease].self, from: Data(contentsOf: Self.releasesURL))) ?? [:]
        announced = UserDefaults.standard.dictionary(forKey: Self.announcedKey) as? [String: String] ?? [:]
    }

    /// After a settings import or another device's change.
    func reload() {
        list = Watchlist.load(from: keychain)
    }

    func contains(_ media: MediaSummary) -> Bool { list.contains(media) }

    /// Adds or removes. `otherIDs`: the same title under other IDs (the detail's IMDb ID for a TMDB result).
    func toggle(_ media: MediaSummary, otherIDs: [String] = []) {
        if list.contains(media) {
            list.remove(media)
        } else {
            list.add(media, otherIDs: otherIDs)
            LocalNotifications.askIfNeeded(for: .watchlist)
        }
        save()
    }

    func remove(_ entry: Watchlist.Entry) {
        list.remove(ids: [entry.id])
        save()
    }

    /// Movies the library already holds: added to a service is not watched, so this is the user's call.
    func removeMoviesInLibrary(_ titles: [LibraryTitle]) {
        let held = list.entries.filter { $0.media.type == .movie && Watchlist.title(for: $0, in: titles) != nil }
        list.remove(ids: Set(held.map(\.id)))
        save()
    }

    func moviesInLibrary(_ titles: [LibraryTitle]) -> Int {
        list.entries.filter { $0.media.type == .movie && Watchlist.title(for: $0, in: titles) != nil }.count
    }

    func status(of entry: Watchlist.Entry, using app: AppModel) -> WatchlistStatus? {
        let title = Watchlist.title(for: entry, in: app.library.titles)
        return WatchlistStatus.of(
            entry,
            inLibrary: title != nil,
            review: title.flatMap { app.review.reviews[$0.id] },
            schedule: app.review.schedules[entry.media.id],
            release: releases[entry.id]
        )
    }

    /// Series on the list, for `LibraryReviewModel` to keep their episode lists.
    var series: [MediaSummary] {
        list.entries.filter { $0.media.type == .series }.map(\.media)
    }

    /// Release dates for movies (TMDB only), then a notice for whatever has news.
    func refresh(using app: AppModel) async {
        if let tmdb = app.addonSet.tmdb {
            let stale = list.entries.filter { entry in
                entry.media.type == .movie && (releases[entry.id].map { Date.now.timeIntervalSince($0.fetchedAt) > Self.releaseAge } ?? true)
            }
            for entry in stale {
                // A failed lookup keeps the old dates and is tried again on the next refresh.
                if let release = try? await tmdb.releaseDates(of: entry.media) { releases[entry.id] = release }
            }
            let ids = Set(list.entries.map(\.id))
            releases = releases.filter { ids.contains($0.key) }
            if !stale.isEmpty, let data = try? JSONEncoder().encode(releases) {
                try? FileManager.default.createDirectory(at: Self.releasesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: Self.releasesURL, options: .atomic)
            }
        }
        announce(using: app)
    }

    /// The first look at an entry only records what it says (a movie added after its release is not news).
    private func announce(using app: AppModel) {
        for entry in list.entries {
            let current = status(of: entry, using: app)?.announcement
            guard let previous = announced[entry.id] else {
                announced[entry.id] = current ?? ""
                continue
            }
            guard let current, current != previous else { continue }
            announced[entry.id] = current
            post(entry, status: status(of: entry, using: app))
        }
        let ids = Set(list.entries.map(\.id))
        announced = announced.filter { ids.contains($0.key) }
        UserDefaults.standard.set(announced, forKey: Self.announcedKey)
    }

    private func post(_ entry: Watchlist.Entry, status: WatchlistStatus?) {
        guard let status else { return }
        let body = switch status {
        case .newEpisodes(let episodes): episodes.count == 1 ? "\(episodes[0].code) is out." : "\(episodes.count) new episodes, up to \(episodes.last!.code)."
        case .out: "Out digitally: releases should be around."
        default: status.label()
        }
        LocalNotifications.post(.watchlist, id: "watchlist:\(entry.id)", title: entry.media.name, body: body, thread: "watchlist")
    }

    private func save() {
        try? list.save(to: keychain)
    }
}
