import DoveAppCore
import DoveKit
import SwiftUI

// Library cards and rows shared by the iPhone and Mac apps: posters, book, game and album covers, status marks.

/// Poster tile: artwork (or the title on a plain card), name, year, services, and a status mark.
struct TitleCard: View {
    let title: LibraryTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                CachedImage(url: title.media?.poster) {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Text(title.name)
                            .scaledFont(.caption, weight: .semibold)
                            .multilineTextAlignment(.center)
                            .padding(6)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                LibraryStatusMark(status: title.status, count: title.items.count).padding(5)
            }
            .overlay(alignment: .topLeading) {
                if let coverage = title.coverage {
                    Text(coverage)
                        .scaledFont(.caption2, weight: .bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(5)
                }
            }
            Text(title.name).scaledFont(.caption, weight: .medium).lineLimit(1)
            HStack(spacing: 3) {
                if let year = title.year { Text(year).scaledFont(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 2)
                ForEach(title.backends, id: \.self) { BackendBadge(backend: $0) }
            }
        }
    }
}

/// Upload ratio of a seeding torrent: red below 0.5, orange below 1, green from 1 (most private trackers ask for 1).
struct SeedingRatio: View {
    let ratio: Double
    var isActive = true

    var body: some View {
        Label(ratio.formatted(.number.precision(.fractionLength(2))), systemImage: isActive ? "arrow.up.circle.fill" : "arrow.up.circle")
            .labelStyle(.titleAndIcon)
            .monospacedDigit()
            .foregroundStyle(color)
            .accessibilityLabel("Seeding ratio \(ratio.formatted(.number.precision(.fractionLength(2))))")
    }

    private var color: Color {
        if ratio >= 1 { return .green }
        if ratio >= 0.5 { return .orange }
        return .red
    }
}

/// Top corner of a poster or cover: how many releases when ready, otherwise downloading or failed.
struct LibraryStatusMark: View {
    let status: LibraryFilter.Status
    let count: Int

    var body: some View {
        switch status {
        case .ready:
            if count > 1 {
                Text("\(count)")
                    .scaledFont(.caption2, weight: .bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        case .active:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white, .blue)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red)
        }
    }
}

/// One torrent or download: name, service, what it holds (episode, season, music…), status, size.
struct ShelfItemRow: View {
    let item: ShelfItem
    var showsBackend = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name).scaledFont(.subheadline).lineLimit(2)
            if item.isRenamed {
                // The service's own (random) name, so the item can still be found there.
                Text(item.item.name).scaledFont(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            HStack(spacing: 8) {
                if showsBackend { BackendBadge(backend: item.item.backend) }
                if item.kind != .video {
                    Label(item.kind.displayName, systemImage: item.kind.symbol)
                } else if let scope = item.guess.scope {
                    Text(scope.label).fontWeight(.medium)
                }
                Text(item.item.status.label)
                if let size = item.item.size {
                    Text(size.formatted(.byteCount(style: .file)))
                }
                if let seeding = item.item.seeding {
                    SeedingRatio(ratio: seeding.ratio, isActive: seeding.isActive)
                }
            }
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

extension LibraryItem.Status {
    var label: String {
        switch self {
        case .queued: "Queued"
        case .awaitingFileSelection: "Choose files"
        case .downloading(let progress): "Downloading \(Int(progress * 100))%"
        case .ready: "Ready"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}

/// Cover tile for a book (2:3) or an audiobook (square): artwork, or a generated cover with the title and
/// author; name, author, services, and a status mark.
struct BookCard: View {
    let book: BookTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                BookCover(book: book)
                LibraryStatusMark(status: book.status, count: book.items.count).padding(5)
            }
            Text(book.name).scaledFont(.caption, weight: .medium).lineLimit(1)
            HStack(spacing: 3) {
                if let author = book.author { Text(author).scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 2)
                ForEach(book.backends, id: \.self) { BackendBadge(backend: $0) }
            }
        }
    }
}

/// The artwork in the book's shape; until it loads, or when there is none, a cover made from the title.
struct BookCover: View {
    let book: BookTitle

    var body: some View {
        CachedImage(url: book.book?.cover) {
            GeneratedCover(title: book.name, author: book.author, format: book.format)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(book.format.coverRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: book.format == .audiobook ? 10 : 4))
        .overlay(alignment: .bottomLeading) {
            if book.format == .audiobook {
                Image(systemName: "headphones")
                    .scaledFont(.caption2, weight: .bold)
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(5)
            }
        }
    }
}

/// A plain cover in a colour picked from the title, so a shelf without artwork still looks like a shelf.
private struct GeneratedCover: View {
    let title: String
    let author: String?
    let format: BookFormat

    private var hue: Double {
        Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55), Color(hue: hue, saturation: 0.55, brightness: 0.3)],
                startPoint: .top,
                endPoint: .bottom
            )
            if format == .ebook {
                // A spine.
                Rectangle().fill(.black.opacity(0.18)).frame(width: 5)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.footnote, design: .serif).weight(.semibold))
                    .lineLimit(4)
                if let author {
                    Text(author).font(.system(.caption2, design: .serif)).opacity(0.8).lineLimit(2)
                }
            }
            .foregroundStyle(.white)
            .padding(.leading, format == .ebook ? 12 : 8)
            .padding([.top, .trailing], 8)
        }
    }
}

extension BookFormat {
    /// Book covers are portrait, audiobook artwork is square.
    var coverRatio: CGFloat { self == .audiobook ? 1 : 2 / 3 }

    var displayName: String { self == .audiobook ? "Audiobook" : "Book" }
}

/// A library tile: box cover (or a made-up one), status, name, the platforms held and where it lives.
struct GameCard: View {
    let game: GameTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                GameCover(url: game.cover, title: game.name, isCollection: game.isCollection)
                LibraryStatusMark(status: game.status, count: game.items.count).padding(5)
            }
            Text(game.name).scaledFont(.caption, weight: .medium).lineLimit(1)
            HStack(spacing: 3) {
                if let platforms = platformText { Text(platforms).scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 2)
                ForEach(game.backends, id: \.self) { BackendBadge(backend: $0) }
            }
        }
    }

    private var platformText: String? {
        let platforms = game.platforms
        guard !platforms.isEmpty else { return game.year }
        return platforms.prefix(2).map(\.displayName).joined(separator: ", ") + (platforms.count > 2 ? " +\(platforms.count - 2)" : "")
    }
}

/// A 3:4 box cover; without one (Wikidata never has any), the controller symbol, with the title when there is
/// room for it (library tiles).
struct GameCover: View {
    let url: URL?
    var title: String?
    var isCollection = false

    var body: some View {
        CachedImage(url: url) {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: isCollection ? "square.stack.3d.up" : "gamecontroller")
                            .font(title == nil ? .body : .title2)
                        if let title {
                            Text(title)
                                .scaledFont(.caption, weight: .semibold)
                                .multilineTextAlignment(.center)
                                .lineLimit(4)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(6)
                }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// An artist on the Music shelf: the newest album's cover, the name, how many albums.
struct ArtistCard: View {
    let artist: ArtistShelf

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AlbumCover(title: artist.name, artist: nil, url: artist.cover, cornerRadius: 12)
            Text(artist.name).scaledFont(.caption, weight: .medium).lineLimit(1)
            Text(artist.albums.count == 1 ? "1 album" : "\(artist.albums.count) albums")
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Square artwork for an album; until it loads, or when there is none, a tile made from the title.
struct AlbumCover: View {
    let title: String
    let artist: String?
    let url: URL?
    var cornerRadius: CGFloat = 8

    private var hue: Double {
        Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
    }

    var body: some View {
        CachedImage(url: url) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Color(hue: hue, saturation: 0.5, brightness: 0.6), Color(hue: hue, saturation: 0.6, brightness: 0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .scaledFont(.title2)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).scaledFont(.caption, weight: .semibold).lineLimit(3)
                    if let artist { Text(artist).scaledFont(.caption2).opacity(0.8).lineLimit(1) }
                }
                .foregroundStyle(.white)
                .padding(8)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct PosterImage: View {
    let url: URL?

    var body: some View {
        CachedImage(url: url) {
            Rectangle().fill(.quaternary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
