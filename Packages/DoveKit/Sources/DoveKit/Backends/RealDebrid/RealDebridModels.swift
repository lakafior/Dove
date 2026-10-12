import Foundation

/// Entry of `GET /torrents` and the body of `GET /torrents/info/{id}` (which adds `files`).
struct RealDebridTorrent: Decodable {
    let id: String
    let filename: String?
    let hash: String?
    let bytes: Int64?
    let progress: Double?
    let status: String
    let added: String?
    /// Host links, one per selected file, in file ID order. Unrestrict them to get download URLs.
    let links: [String]?
    let files: [RealDebridFile]?
}

struct RealDebridFile: Decodable {
    let id: Int
    let path: String
    let bytes: Int64?
    let selected: Int
}

/// Entry of `GET /downloads` and the response of `POST /unrestrict/link`.
struct RealDebridDownload: Decodable {
    let id: String
    let filename: String?
    let filesize: Int64?
    let download: String
    let generated: String?
}

struct RealDebridCreated: Decodable {
    let id: String
}

struct RealDebridErrorBody: Decodable {
    let error: String?
    let errorCode: Int?
}

/// Library item IDs: torrents and unrestricted hoster links live in separate Real-Debrid lists.
enum RealDebridItemRef: Equatable {
    case torrent(String)
    case download(String)

    init?(_ id: String) {
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        let value = String(parts[1])
        switch parts[0] {
        case "torrent": self = .torrent(value)
        case "download": self = .download(value)
        default: return nil
        }
    }

    var id: String {
        switch self {
        case .torrent(let value): "torrent:\(value)"
        case .download(let value): "download:\(value)"
        }
    }
}

extension RealDebridTorrent {
    var libraryItem: LibraryItem {
        let selected = (files ?? []).filter { $0.selected == 1 }
        return LibraryItem(
            id: RealDebridItemRef.torrent(id).id,
            backend: .realDebrid,
            name: filename ?? hash ?? id,
            size: bytes,
            status: libraryStatus,
            files: selected.map {
                LibraryFile(id: String($0.id), name: ($0.path as NSString).lastPathComponent, size: $0.bytes)
            },
            addedAt: added.flatMap(APIDate.parse)
        )
    }

    var libraryStatus: LibraryItem.Status {
        switch status {
        case "downloaded": .ready
        case "waiting_files_selection": .awaitingFileSelection
        case "magnet_conversion", "queued": .queued
        case "downloading", "compressing", "uploading": .downloading(progress: (progress ?? 0) / 100)
        default: .failed(reason: status.replacingOccurrences(of: "_", with: " "))
        }
    }
}

extension RealDebridDownload {
    var libraryItem: LibraryItem {
        LibraryItem(
            id: RealDebridItemRef.download(id).id,
            backend: .realDebrid,
            name: filename ?? id,
            size: filesize,
            status: .ready,
            files: [LibraryFile(id: "0", name: filename ?? id, size: filesize)],
            addedAt: generated.flatMap(APIDate.parse)
        )
    }
}

enum RealDebridFiles {
    /// File IDs to select: video files without samples. Falls back to every video, then to "all".
    static func selection(for files: [RealDebridFile]) -> String {
        let chosen = suggested(files)
        guard !chosen.isEmpty else { return "all" }
        return chosen.map { String($0.id) }.joined(separator: ",")
    }

    /// Video files without samples, or every video when all of them look like samples. Empty without videos.
    static func suggested(_ files: [RealDebridFile]) -> [RealDebridFile] {
        let videos = files.filter { FileKind.isVideo($0.path) }
        let main = videos.filter { !FileKind.isSample($0.path) }
        return main.isEmpty ? videos : main
    }
}

/// Real-Debrid's name filter (since May 2026): `451 infringing_file` for releases whose name contains these tags.
/// The list follows Debrid Media Manager's measurements (`src/utils/deInfringe.ts`, re-measured 2026-10-10).
/// An add is judged on the torrent's root name; `/unrestrict/link` on each file name.
enum RealDebridNameFilter {
    nonisolated(unsafe) private static let blocked =
        #/web-dl|(?:web|bd|hd|dvd)rip|bluray\.x264|p\.bluray\.dts|hdtv\.(?:x264|xvid)|web\.(?:x264|h264)/#
        .ignoresCase()

    static func isBlocked(_ name: String) -> Bool {
        name.contains(blocked)
    }

    /// The `dn` (display name) of a magnet, if it has one.
    static func displayName(ofMagnet magnet: String) -> String? {
        URLComponents(string: magnet)?.queryItems?
            .first { $0.name.lowercased() == "dn" }?
            .value?
            .replacingOccurrences(of: "+", with: " ")
    }
}
