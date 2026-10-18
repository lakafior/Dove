import CryptoKit
import DoveKit
import Foundation
import WidgetKit

/// Builds `WidgetSnapshot` from what the app already knows (library list, service lights and premium days,
/// watchlist, audiobook) and writes it to the App Group, with the few images it shows. Called after a library or
/// account refresh, a watchlist change, a background refresh and when Dove goes to the background. Costs no calls
/// except fetching artwork the image cache does not hold yet.
@MainActor
enum WidgetSnapshotWriter {
    private static var running: Task<Void, Never>?

    static func update(using app: AppModel) {
        running?.cancel()
        running = Task { await write(using: app) }
    }

    /// The same, awaited (background refresh).
    static func write(using app: AppModel) async {
        guard let container = SharedConfiguration.appGroupContainer else { return }
        await write(using: app, to: container)
    }

    private static func write(using app: AppModel, to container: URL) async {
        let counts = WidgetSnapshot.libraryCounts(app.library.items.map(\.item))
        let services = app.backends.map(\.id).map { backend in
            let account = app.services.accounts[backend]
            let failed: Bool? = switch app.services.health(of: backend) {
            case .online: false
            case .offline: true
            case .unknown: nil
            }
            let count = counts[backend]
            return WidgetSnapshot.Service(
                backend: backend,
                light: WidgetSnapshot.light(failed: failed, account: account),
                daysLeft: account?.daysLeft(),
                status: failed == true ? "Offline" : app.services.accountSummary(backend),
                items: count?.items ?? 0,
                bytes: count?.bytes ?? 0,
                active: count?.active ?? 0
            )
        }

        var images: [URL: String] = [:]
        func image(_ url: URL?) -> String? {
            guard let url else { return nil }
            let name = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".img"
            images[url] = name
            return name
        }

        let titles = app.library.titles
        let watchlist = app.watchlist.list.entries.prefix(6).map { entry in
            let status = app.watchlist.status(of: entry, using: app)
            let held = Watchlist.title(for: entry, in: titles)
            return WidgetSnapshot.WatchlistLine(
                id: entry.id,
                title: entry.media.name,
                status: status?.label(),
                isNews: status?.announcement != nil,
                image: image(entry.media.poster),
                link: held.map { DeepLink.title($0.id) } ?? DeepLink.url("watchlist")
            )
        }
        // News first, so the small widget shows what matters.
        let ordered = watchlist.filter(\.isNews) + watchlist.filter { !$0.isNews }

        var listening: WidgetSnapshot.Listening?
        let player = app.audiobook
        if let session = player.session {
            var progress: Double?
            if let duration = player.duration, duration > 0, !session.tracks.isEmpty {
                progress = (Double(player.trackIndex) + min(player.elapsed / duration, 1)) / Double(session.tracks.count)
            }
            listening = .init(title: session.title, author: session.author, progress: progress, image: image(session.cover), isPlaying: player.isPlaying)
        } else {
            let books = app.library.books
            if let book = player.listening().lazy.compactMap({ entry in books.first { $0.guess.key == entry.key } }).first {
                listening = .init(title: book.name, author: book.author, image: image(book.book?.cover))
            }
        }

        let snapshot = WidgetSnapshot(services: services, watchlist: Array(ordered), listening: listening)
        let folder = WidgetSnapshot.imagesURL(in: container)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (url, name) in images where !FileManager.default.fileExists(atPath: folder.appending(path: name).path()) {
            guard !Task.isCancelled else { return }
            if let data = try? await ImageCache.shared.data(for: url) { try? data.write(to: folder.appending(path: name), options: .atomic) }
        }
        // Images nothing points to anymore.
        let kept = Set(images.values)
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path())) ?? [] where !kept.contains(file) {
            try? FileManager.default.removeItem(at: folder.appending(path: file))
        }
        guard !Task.isCancelled else { return }
        if (try? snapshot.save(to: container)) == true { WidgetCenter.shared.reloadAllTimelines() }
    }
}

/// `dove://` links from widgets: `dove://watchlist`, `dove://library`, `dove://downloads`, `dove://settings`,
/// `dove://listening`, `dove://title/<id>`.
enum DeepLink {
    static func url(_ host: String, _ path: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "dove"
        components.host = host
        if let path { components.path = "/" + path }
        return components.url!
    }

    static func title(_ id: String) -> URL { url("title", id) }

    /// True when it was a `dove://` link (handled or not), so it is not taken for a magnet or a file.
    @MainActor
    static func open(_ url: URL, using app: AppModel) -> Bool {
        guard url.scheme == "dove" else { return false }
        switch url.host() {
        case "watchlist": app.show(.watchlist)
        case "library": app.selectedTab = .library
        case "downloads": app.show(.downloads)
        case "settings": app.selectedTab = .settings
        case "listening":
            if app.audiobook.session != nil { app.audiobook.isPresented = true } else { Task { _ = await app.continueAudiobook() } }
        case "media":
            if let link = TitleLink(deepLink: url) { Task { await app.openTitle(link) } }
        case "title":
            let id = String(url.path().dropFirst()).removingPercentEncoding ?? ""
            if !id.isEmpty { app.show(.title(id: id)) }
        case "direct":
            // From the share extension: a direct-download site's file page, fetched with the user's key.
            let md5 = String(url.path().dropFirst())
            app.show(.downloads)
            Task { app.directDownloadMessage = await app.startDirectDownload(md5: md5) }
        default: break
        }
        return true
    }
}
