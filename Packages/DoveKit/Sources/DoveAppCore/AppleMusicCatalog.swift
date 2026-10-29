import DoveKit
import Foundation
import MusicKit

/// Apple Music's catalog as a second album source (`AlbumCatalog`), through MusicKit: the store of the device's
/// account, no subscription needed to search, its own quota (not iTunes Search's, which Books uses). Needs the
/// user's permission (`MusicAuthorization`) and the MusicKit service on Dove's App ID: a build re-signed with
/// another Apple ID gets no developer token and every request fails.
public struct AppleMusicCatalog: AlbumCatalog {
    public let name = "Apple Music"

    public init() {}

    public func owns(_ albumID: String) -> Bool { albumID.hasPrefix("am:") }
    /// Settings › Music (this device: the permission is per device too).
    public static let preferenceKey = "appleMusicMetadata"

    /// On, and allowed.
    public static var isEnabled: Bool {
        DoveStorage.defaults.bool(forKey: preferenceKey) && MusicAuthorization.currentStatus == .authorized
    }

    public func albums(matching query: String) async throws -> [AlbumSummary] {
        var request = MusicCatalogSearchRequest(term: query, types: [MusicKit.Album.self])
        request.limit = 25
        do {
            return try await request.response().albums.map(Self.summary)
        } catch {
            throw Self.readable(error)
        }
    }

    public func tracks(ofAlbum id: String) async throws -> [AlbumTrack] {
        guard id.hasPrefix("am:") else { return [] }
        var request = MusicCatalogResourceRequest<MusicKit.Album>(matching: \.id, equalTo: MusicItemID(String(id.dropFirst(3))))
        request.properties = [.tracks]
        do {
            guard let album = try await request.response().items.first else { return [] }
            return (album.tracks ?? []).enumerated().map { index, track in
                AlbumTrack(
                    id: track.id.rawValue,
                    disc: track.discNumber ?? 1,
                    position: track.trackNumber ?? index + 1,
                    title: track.title,
                    duration: track.duration
                )
            }
        } catch {
            throw Self.readable(error)
        }
    }

    /// Apple names singles and EPs "Title - Single" / "Title - EP": the suffix becomes the type, as in MusicBrainz.
    public static func summary(_ album: MusicKit.Album) -> AlbumSummary {
        var title = album.title
        var type = album.isCompilation == true ? "Compilation" : album.isSingle == true ? "Single" : "Album"
        for (suffix, kind) in [(" - Single", "Single"), (" - EP", "EP")] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
            type = kind
        }
        return AlbumSummary(
            id: "am:\(album.id.rawValue)",
            title: title,
            artists: [album.artistName],
            year: album.releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) },
            cover: album.artwork?.url(width: 500, height: 500),
            type: type,
            link: album.url
        )
    }

    /// MusicKit's errors say little ("The operation couldn't be completed"): say what to check.
    private static func readable(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if MusicAuthorization.currentStatus != .authorized {
            return BackendError.api(message: "Apple Music is not allowed for Dove: Settings › Music.")
        }
        // Apple's token service answers 404 "Client not found" until the App ID that signed this build has the
        // MusicKit App Service, and for a while after it is turned on.
        if error is MusicTokenRequestError {
            let bundleID = Bundle.main.bundleIdentifier ?? "Dove"
            return BackendError.api(message: "Apple Music does not know \(bundleID) yet. Turn on MusicKit under App Services for exactly this App ID (developer portal › Identifiers); after turning it on, it can take a while to work.")
        }
        return BackendError.api(message: "Apple Music: \(error.localizedDescription)")
    }
}

extension AlbumSummary {
    /// Where the row came from, for its caption and link: a plugin's entry (`plugin:<id>:…`) takes the plugin's name.
    public func sourceName(plugins: [PluginManifest] = []) -> String {
        if id.hasPrefix("am:") { return "Apple Music" }
        if id.hasPrefix("plugin:") {
            let pluginID = id.split(separator: ":").dropFirst().first.map(String.init)
            return plugins.first { $0.id == pluginID }?.name ?? "Plugin"
        }
        return "MusicBrainz"
    }
}
