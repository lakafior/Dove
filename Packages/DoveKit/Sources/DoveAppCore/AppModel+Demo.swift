#if DEBUG
import DoveKit
import Foundation

/// Demo mode (`DemoMode`, Debug builds launched with `-demo`): a made-up TorBox account full of public-domain films,
/// books and music, for screenshots. `DoveStorage` and `KeychainStore.demo` keep the user's real state out of reach;
/// `DemoURLProtocol` answers every request except Wikimedia's images from canned data.
extension AppModel {
    /// Runs first in `init`, before anything reads the Keychain or asks the network.
    static func prepareDemo() {
        URLProtocol.registerClass(DemoURLProtocol.self)
        let addons = (try? JSONEncoder().encode([DemoCatalog.addonURL.absoluteString])).map { String(decoding: $0, as: UTF8.self) }
        KeychainStore.seedDemo([
            // Shows TorBox as set up in Settings; `SharedConfiguration.backends` answers with `DemoBackend`.
            .torBoxAPIKey: "demo",
            .stremioAddons: addons ?? "",
        ])
    }

    /// Runs at the end of `init`: downloads to show, a watchlist, and the library's covers and posters matched
    /// before the library looks for them (`LibraryModel.start` waits for `demoSeeding`).
    func startDemo() {
        downloads.showDemo(DemoBackend.downloads)
        for media in [DemoCatalog.films[1].summary, DemoCatalog.films[4].summary] where !watchlist.contains(media) {
            watchlist.toggle(media)
        }
        demoSeeding = Task { await seedDemoMatches() }
    }

    private func seedDemoMatches() async {
        guard let items = try? await DemoBackend().items() else { return }
        let normalized = { (text: String) in MediaGuess.normalize(text) }
        for item in items {
            let shelf = library.shelf(item)
            switch shelf.kind {
            case .video:
                let candidates = DemoCatalog.films.map(\.summary) + [DemoCatalog.series.summary]
                if let media = candidates.first(where: { normalized(item.name).hasPrefix(normalized($0.name)) }) {
                    await library.setMatch(media, for: [shelf.guess.key])
                }
            case .books:
                if let key = shelf.bookGuess?.key,
                   let book = DemoCatalog.books.first(where: { item.name.hasPrefix($0.title) }) {
                    await library.setBookMatch(book, for: [key])
                }
            case .audiobooks:
                if let key = shelf.bookGuess?.key,
                   let book = DemoCatalog.audiobooks.first(where: { item.name.hasPrefix($0.title) }) {
                    let summary = BookSummary(
                        id: "demo:audiobook:\(book.title)", title: book.title, authors: [book.author], cover: book.cover
                    )
                    await library.setBookMatch(summary, for: [key])
                }
            case .music:
                if let key = shelf.albumGuess?.key,
                   let album = DemoCatalog.albums.first(where: { item.name.contains($0.title) }) {
                    await library.setAlbumMatch(album, for: [key])
                }
            default:
                break
            }
        }
    }
}
#endif
