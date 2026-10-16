import Foundation

/// What Dove's widgets show, written by the app to the App Group after each refresh. Widgets never call a service and
/// never read the Keychain: everything they draw is here, with no secrets in it. Images are local files next to it.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct Service: Codable, Sendable, Equatable, Identifiable {
        public enum Light: String, Codable, Sendable {
            /// Answered the last refresh, premium for a week or more.
            case good
            /// Free plan, expired, or under a week left.
            case warning
            /// The last refresh failed.
            case failed
            case unknown
        }

        public var backend: BackendID
        public var light: Light
        /// Nil when the service does not say.
        public var daysLeft: Int?
        /// "213 days left", "Free plan", "Offline"…
        public var status: String?
        public var items: Int
        public var bytes: Int64
        /// Still being fetched by the service (queued, downloading, waiting for file choice).
        public var active: Int

        public var id: String { backend.rawValue }
        public var name: String { backend.displayName }
        public var isUsenet: Bool { backend.isUsenet }

        public init(backend: BackendID, light: Light, daysLeft: Int? = nil, status: String? = nil, items: Int = 0, bytes: Int64 = 0, active: Int = 0) {
            self.backend = backend
            self.light = light
            self.daysLeft = daysLeft
            self.status = status
            self.items = items
            self.bytes = bytes
            self.active = active
        }
    }

    public struct WatchlistLine: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        /// "2 new · S02E03", "Digital 12 Nov"…
        public var status: String?
        /// News worth a highlight: new episodes, out now.
        public var isNews: Bool
        /// A file name in the snapshot's image folder.
        public var image: String?
        /// `dove://` link that opens it.
        public var link: URL?

        public init(id: String, title: String, status: String? = nil, isNews: Bool = false, image: String? = nil, link: URL? = nil) {
            self.id = id
            self.title = title
            self.status = status
            self.isNews = isNews
            self.image = image
            self.link = link
        }
    }

    public struct Listening: Codable, Sendable, Equatable {
        public var title: String
        public var author: String?
        /// 0…1 of the whole book, when the tracks' lengths are known.
        public var progress: Double?
        public var image: String?
        public var isPlaying: Bool

        public init(title: String, author: String? = nil, progress: Double? = nil, image: String? = nil, isPlaying: Bool = false) {
            self.title = title
            self.author = author
            self.progress = progress
            self.image = image
            self.isPlaying = isPlaying
        }
    }

    public var generatedAt: Date
    public var services: [Service]
    public var watchlist: [WatchlistLine]
    public var listening: Listening?

    public init(generatedAt: Date = .now, services: [Service] = [], watchlist: [WatchlistLine] = [], listening: Listening? = nil) {
        self.generatedAt = generatedAt
        self.services = services
        self.watchlist = watchlist
        self.listening = listening
    }

    public var totalItems: Int { services.reduce(0) { $0 + $1.items } }
    public var totalBytes: Int64 { services.reduce(0) { $0 + $1.bytes } }
    public var totalActive: Int { services.reduce(0) { $0 + $1.active } }

    /// The paid service that runs out first, for the Lock Screen ("RD 12 d").
    public var soonestExpiry: Service? {
        services.filter { $0.daysLeft != nil }.min { $0.daysLeft! < $1.daysLeft! }
    }

    /// Items, size and still-fetching count per backend, from the library list.
    public static func libraryCounts(_ items: [LibraryItem]) -> [BackendID: (items: Int, bytes: Int64, active: Int)] {
        var counts: [BackendID: (items: Int, bytes: Int64, active: Int)] = [:]
        for item in items {
            var entry = counts[item.backend] ?? (0, 0, 0)
            entry.items += 1
            entry.bytes += item.size ?? 0
            switch item.status {
            case .queued, .downloading, .awaitingFileSelection: entry.active += 1
            case .ready, .failed: break
            }
            counts[item.backend] = entry
        }
        return counts
    }

    /// Green, orange or red: like the Settings lights.
    public static func light(failed: Bool?, account: AccountStatus?, now: Date = .now) -> Service.Light {
        if failed == true { return .failed }
        if let account {
            if !account.isPremium { return .warning }
            if let days = account.daysLeft(now: now), days < 7 { return .warning }
        }
        return failed == false ? .good : .unknown
    }

    // MARK: - Files

    /// The snapshot's file in a container (the App Group's in the app and the widgets).
    public static func fileURL(in container: URL) -> URL {
        container.appending(path: "Widgets/snapshot.json")
    }

    /// Folder for the images it names.
    public static func imagesURL(in container: URL) -> URL {
        container.appending(path: "Widgets/Images")
    }

    public static func load(from container: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(in: container)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Writes only when something besides the date changed. Returns whether it wrote.
    @discardableResult
    public func save(to container: URL) throws -> Bool {
        if var previous = WidgetSnapshot.load(from: container) {
            previous.generatedAt = generatedAt
            if previous == self { return false }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = WidgetSnapshot.fileURL(in: container)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
        return true
    }
}
