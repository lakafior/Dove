#if DEBUG
import Foundation

public struct DemoBackend: LibraryBackend, AccountReporting, CacheChecking {
    public let id: BackendID = .torBox
    public let supportedSources: Set<SourceKind> = [.torrent, .hoster, .nzb]
    public let takesPrivateTorrents = false
    public let acceptsDirectLinks = true
    private static let reference = Date(timeIntervalSince1970: 1_792_483_200)
    public init() {}
    public func validateCredentials() async throws {}
    public func add(_ source: Source) async throws -> LibraryItem.ID { "torrent:demo-added" }
    public func delete(_ itemID: LibraryItem.ID) async throws {}
    public func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://demo.dove.invalid/files/\(itemID)/\(fileID)")!)
    }
    public func account() async throws -> AccountStatus {
        .init(isPremium: true, premiumUntil: Self.reference.addingTimeInterval(200 * 86_400), plan: "Pro")
    }
    /// A made-up info hash; the ones ending in `ca` are cached here (`cachedHashes`).
    public static func infoHash(_ number: Int, cached: Bool = false) -> String {
        String(format: "%038d", number) + (cached ? "ca" : "00")
    }

    public func cachedHashes(_ hashes: [String]) async throws -> Set<String> {
        Set(hashes.map { $0.lowercased() }.filter { $0.hasSuffix("ca") })
    }
    public func items() async throws -> [LibraryItem] {
        func item(
            _ id: String,
            _ name: String,
            _ files: [LibraryFile],
            _ daysAgo: Int,
            hash: String? = nil,
            status: LibraryItem.Status = .ready
        ) -> LibraryItem {
            LibraryItem(
                id: "torrent:demo-\(id)",
                backend: .torBox,
                name: name,
                size: files.compactMap(\.size).reduce(0, +),
                status: status,
                files: files,
                addedAt: Self.reference.addingTimeInterval(TimeInterval(-daysAgo * 86_400)),
                infoHash: hash,
                downloadSpeed: { if case .downloading = status { 4_200_000 } else { nil } }()
            )
        }
        let names = [
            "Night of the Living Dead (1968) 1080p.mkv", "Nosferatu (1922) 1080p.mp4",
            "Metropolis (1927) 1080p.mkv", "His Girl Friday (1940) 1080p.mp4", "Charade (1963) 1080p.mkv",
            "Plan 9 from Outer Space (1957) 1080p.mp4",
        ]
        var result = names.enumerated().map { index, name in
            item(
                "film-\(index + 1)",
                String(name.dropLast(4)),
                [
                    .init(
                        id: "file-1",
                        name: name,
                        size: [
                            1_900_000_000, 1_600_000_000, 2_800_000_000, 1_700_000_000, 2_100_000_000,
                            1_500_000_000,
                        ][index]
                    )
                ],
                index + 1,
                hash: Self.infoHash(100 + index),
                status: index == 2 ? .downloading(progress: 0.38) : .ready
            )
        }
        let episodes = DemoCatalog.series.episodes.map { episode in
            LibraryFile(
                id: "ep-\(episode.number)",
                name:
                    "The Beverly Hillbillies S01E\(String(format: "%02d", episode.number)) \(episode.title ?? "Episode").mp4",
                size: 500_000_000
            )
        }
        result.append(
            item(
                "hillbillies-s01",
                "The Beverly Hillbillies S01 (1962)",
                episodes,
                7,
                hash: Self.infoHash(107)
            )
        )
        for (index, book) in DemoCatalog.books.enumerated() {
            result.append(
                item(
                    "book-\(index + 1)",
                    "\(book.title) - \(book.authors[0]) (\(book.year!)) EPUB",
                    [.init(id: "file-1", name: "\(book.title).epub", size: 8_000_000)],
                    9 + index
                )
            )
        }
        for (index, book) in DemoCatalog.audiobooks.enumerated() {
            let files = (1...5).map {
                LibraryFile(
                    id: "chapter-\($0)",
                    name: "\(book.title) - Chapter \(String(format: "%02d", $0)).mp3",
                    size: 35_000_000
                )
            }
            result.append(
                item(
                    "audio-\(index + 1)",
                    "\(book.title) - \(book.author) Audiobook",
                    files,
                    13 + index,
                    status: index == 0 ? .downloading(progress: 0.71) : .ready
                )
            )
        }
        for (index, album) in DemoCatalog.albums.enumerated() {
            let files = (1...6).map {
                LibraryFile(
                    id: "track-\($0)",
                    name: String(format: "%02d - %@ - Track %02d.flac", $0, album.title, $0),
                    size: 45_000_000
                )
            }
            result.append(
                item(
                    "album-\(index + 1)",
                    "\(album.artists[0]) - \(album.title) (\(album.year!))",
                    files,
                    16 + index
                )
            )
        }
        return result
    }
    public static let downloads: [DownloadRecord] = [
        .init(
            id: "demo-download-metropolis",
            backend: .torBox,
            itemID: "torrent:demo-film-3",
            fileID: "file-1",
            name: "Metropolis (1927) 1080p.mkv",
            bytesWritten: 1_064_000_000,
            totalBytes: 2_800_000_000,
            createdAt: reference.addingTimeInterval(-900)
        ),
        .init(
            id: "demo-download-audio",
            backend: .torBox,
            itemID: "torrent:demo-audio-1",
            fileID: "chapter-3",
            name: "The Adventures of Sherlock Holmes - Chapter 03.mp3",
            bytesWritten: 24_850_000,
            totalBytes: 35_000_000,
            createdAt: reference.addingTimeInterval(-1800)
        ),
        .init(
            id: "demo-download-paused",
            backend: .torBox,
            itemID: "torrent:demo-film-5",
            fileID: "file-1",
            name: "Charade (1963) 1080p.mkv",
            state: .paused,
            bytesWritten: 1_134_000_000,
            totalBytes: 2_100_000_000,
            createdAt: reference.addingTimeInterval(-3600)
        ),
    ]
}
#endif
