import CryptoKit
import Foundation

/// Artwork (posters, covers, backdrops, episode stills) kept on disk, so the Library does not download every
/// poster again on each launch. Files live in Caches, which iOS may clear when space runs low; a missing file is
/// simply fetched again. Requests for the same image while one is on its way share it.
public actor ImageCache {
    /// Its own session without `URLCache`: these files are the cache, a second copy would only take space.
    public static let shared = ImageCache(
        directory: URL.cachesDirectory.appending(path: "Dove/Images"),
        transport: URLSession(configuration: {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = nil
            return configuration
        }())
    )

    private let directory: URL
    private let transport: any HTTPTransport
    private var inFlight: [URL: Task<Data, any Error>] = [:]

    public init(directory: URL, transport: any HTTPTransport = URLSession.shared) {
        self.directory = directory
        self.transport = transport
    }

    /// The image's bytes: from disk when Dove has them, otherwise downloaded and stored.
    public func data(for url: URL) async throws -> Data {
        let file = file(for: url)
        if let stored = try? Data(contentsOf: file) { return stored }
        if let running = inFlight[url] { return try await running.value }
        let transport = transport
        let task = Task<Data, any Error> {
            let (data, response) = try await transport.send(URLRequest(url: url))
            if let error = response.backendError { throw error }
            guard !data.isEmpty else { throw BackendError.invalidResponse }
            return data
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let data = try await task.value
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    /// Whether the image is on disk (no download).
    public func contains(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: file(for: url).path())
    }

    /// Bytes on disk, for Settings.
    public func size() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// One file per URL, named by its hash (URLs are long and full of slashes).
    func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined())
    }
}
