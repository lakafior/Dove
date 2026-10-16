import Foundation

/// "Download only": a source added to a debrid just to fetch files to the device. Once its downloads
/// finish, the item is deleted from the service. Persisted, so a job survives the app being closed.
public struct DownloadJob: Codable, Sendable, Identifiable, Hashable {
    /// Which files of the item to download.
    public enum Pick: Codable, Sendable, Hashable {
        /// A movie: the largest video file.
        case largestVideo
        /// One episode out of a pack (or a single-episode release); the largest video if no name matches.
        case episode(season: Int, episode: Int)
        /// A season or series pack, or a source of unknown content: every video file without samples,
        /// or every file when there are no videos.
        case allVideos
    }

    public enum State: Codable, Sendable, Hashable {
        /// The service is still fetching it; Dove checks again while the app is open.
        case waiting
        case downloading([DownloadRecord.ID])
        case failed(reason: String)
    }

    /// How a job ended, for the notification.
    public enum Outcome: Sendable, Hashable {
        case finished(files: Int)
        case failed(reason: String)
    }

    public let id: String
    public let backend: BackendID
    public let itemID: LibraryItem.ID
    public var name: String
    public let pick: Pick
    public var state: State
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        backend: BackendID,
        itemID: LibraryItem.ID,
        name: String,
        pick: Pick,
        state: State = .waiting,
        createdAt: Date = .now
    ) {
        self.id = id
        self.backend = backend
        self.itemID = itemID
        self.name = name
        self.pick = pick
        self.state = state
        self.createdAt = createdAt
    }

    /// The files to download from a ready item.
    public func files(in item: LibraryItem) -> [LibraryFile] {
        let videos = item.files.filter { FileKind.isVideo($0.name) && !FileKind.isSample($0.name) }
        let largest = videos.max { ($0.size ?? 0) < ($1.size ?? 0) }
        switch pick {
        case .largestVideo:
            return largest.map { [$0] } ?? item.files
        case .episode(let season, let episode):
            let matching = videos.filter {
                let guess = ReleaseParser.guess($0.name)
                return guess.season == season && guess.episode == episode
            }
            if !matching.isEmpty { return matching }
            return largest.map { [$0] } ?? item.files
        case .allVideos:
            return videos.isEmpty ? item.files : videos
        }
    }
}

/// File types by extension.
public enum FileKind {
    public static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "wmv", "webm"]

    public static func isVideo(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Release samples: a `sample` folder or file name.
    public static func isSample(_ name: String) -> Bool {
        name.lowercased().contains("sample")
    }
}

/// Download-only jobs (`jobs.json`), next to the download records.
public struct DownloadJobStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> [DownloadJob] {
        guard let data = try? Data(contentsOf: fileURL),
              let jobs = try? JSONDecoder().decode([DownloadJob].self, from: data)
        else { return [] }
        return jobs
    }

    public func save(_ jobs: [DownloadJob]) {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
