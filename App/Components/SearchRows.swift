import DoveAppCore
import DoveKit
import SwiftUI

// Rows of search results (titles, books, albums, games), shared by the iPhone's lists and both apps' match pickers.

struct MediaRow: View {
    let item: MediaSummary

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: item.poster)
                .frame(width: 46, height: 69)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.type == .movie ? "Movie" : "Series")
                    if let year = item.releaseInfo { Text(year) }
                    if let rating = item.imdbRating { Text("★ \(rating)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct BookRow: View {
    @Environment(AppModel.self) private var model
    let book: BookSummary
    let format: BookFormat
    /// The library's copy of this book (`HeldBooks`), marked so it is not fetched twice.
    var held: BookTitle?

    var body: some View {
        HStack(spacing: 12) {
            CachedImage(url: book.cover) {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 46, height: format == .audiobook ? 46 : 69)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    if let author = book.authors.first { Text(author) }
                    if let year = book.year { Text(String(year)) }
                    Text(book.sourceName(plugins: model.plugins.manifests()))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let held { HeldBookMark(title: held) }
            }
        }
    }
}

/// "In Calibre" (or "In library" for a copy on a service) under a search result the library already holds.
struct HeldBookMark: View {
    let title: BookTitle

    var body: some View {
        Label(title.heldLabel, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(title.backends.contains(.calibre) ? BackendID.calibre.tint : .green)
    }
}

struct AlbumRow: View {
    @Environment(AppModel.self) private var model
    let album: AlbumSummary

    var body: some View {
        HStack(spacing: 12) {
            CachedImage(url: album.cover) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text(album.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    if let artist = album.artist { Text(artist).lineLimit(1) }
                    if let year = album.year { Text(String(year)) }
                    if let type = album.type { Text(type) }
                    if !album.id.hasPrefix("mb:") { Text(album.sourceName(plugins: model.plugins.manifests())) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct GameRow: View {
    @Environment(AppModel.self) private var model
    let game: GameSummary

    var body: some View {
        HStack(spacing: 12) {
            GameCover(url: game.cover)
                .frame(width: 45, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    if let year = game.year { Text(String(year)) }
                    if !game.isMainGame, let type = game.type { Text(type) }
                    if !game.platforms.isEmpty {
                        Text(game.platforms.prefix(4).map(\.displayName).joined(separator: ", ")
                             + (game.platforms.count > 4 ? " +\(game.platforms.count - 4)" : ""))
                            .lineLimit(1)
                    }
                    if game.id.hasPrefix("plugin:") { Text(game.sourceName(plugins: model.plugins.manifests())) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

extension GameSummary {
    /// Who described it, for the link: "IGDB", "Wikidata", or the plugin's name.
    func sourceName(plugins: [PluginManifest] = []) -> String {
        if id.hasPrefix("wd:") { return "Wikidata" }
        if id.hasPrefix("plugin:") {
            let pluginID = id.split(separator: ":").dropFirst().first.map(String.init)
            return plugins.first { $0.id == pluginID }?.name ?? "Plugin"
        }
        return "IGDB"
    }
}

extension BookTitle {
    /// Where the library keeps it, Calibre first: it is the user's own copy.
    var heldLabel: String {
        backends.contains(.calibre) ? "In Calibre" : "In library"
    }

    /// The formats the library's copies come in ("EPUB, MOBI"), from file names.
    var heldFormats: String {
        let formats = items.flatMap(\.item.files).map { BookFiles.format(of: $0.name).uppercased() }
            .filter { BookFiles.ebookFormats.contains($0.lowercased()) || AudiobookTracks.playableExtensions.contains($0.lowercased()) }
        return formats.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
    }
}
