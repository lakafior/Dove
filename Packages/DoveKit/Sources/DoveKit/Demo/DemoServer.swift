#if DEBUG
import Foundation

public enum DemoServer {
    private static let json = "application/json; charset=utf-8"
    private static func response(_ object: Any, _ status: Int = 200) -> (Data, HTTPURLResponse) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return (
            data,
            HTTPURLResponse(
                url: URL(string: "https://demo.dove.invalid/")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": json]
            )!
        )
    }
    private static func media(_ detail: MediaDetail) -> [String: Any] {
        var value: [String: Any] = [
            "id": detail.summary.id, "type": detail.summary.type.rawValue, "name": detail.summary.name,
        ]
        value["releaseInfo"] = detail.summary.releaseInfo; value["poster"] = detail.summary.poster?.absoluteString
        value["description"] = detail.summary.description; value["genres"] = detail.genres;
        value["runtime"] = detail.runtime
        if !detail.episodes.isEmpty {
            value["videos"] = detail.episodes.map {
                [
                    "id": $0.id, "title": $0.title ?? "", "season": $0.season, "episode": $0.number,
                    "overview": $0.overview ?? "",
                ] as [String: Any]
            }
        }
        return value
    }
    private static var allMovies: [[String: Any]] { DemoCatalog.films.map { media($0) } }
    private static var allSeries: [[String: Any]] { [media(DemoCatalog.series)] }
    /// The releases every title has: a spread of resolutions, sizes and places, some cached on the demo TorBox.
    private static let variants: [(quality: String, gigabytes: Double, seeders: Int, origin: String, cached: Bool)] = [
        ("2160p Restored HEVC FLAC", 14.2, 41, "Internet Archive", true),
        ("1080p Restored x264 AAC", 6.8, 128, "Internet Archive", true),
        ("1080p x265 10bit Opus", 3.1, 64, "Public Domain Torrents", false),
        ("720p x264 AAC", 1.9, 97, "Public Domain Torrents", true),
        ("576p MPEG-2 AC3", 4.4, 12, "Internet Archive", false),
        ("480p x264 MP3", 0.9, 23, "Internet Archive", false),
    ]

    public static func respond(to request: URLRequest) -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.host == "demo.dove.invalid" else {
            return response(["error": "Demo mode: no network"], 503)
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if url.path == "/manifest.json" {
            return response([
                "id": "net.smigi.dove.demo", "version": "1.0.0", "name": "Public Domain",
                "description": "Public-domain films and series", "types": ["movie", "series"], "idPrefixes": ["tt"],
                "resources": ["catalog", "meta", "stream"],
                "catalogs": [
                    [
                        "type": "movie", "id": "demo-movies", "name": "Public Domain Films",
                        "extra": [["name": "search", "isRequired": false]],
                    ],
                    [
                        "type": "series", "id": "demo-series", "name": "Public Domain Series",
                        "extra": [["name": "search", "isRequired": false]],
                    ],
                ],
            ])
        }
        if parts.count >= 3, parts[0] == "catalog" {
            let type = parts[1]
            let queryPart = parts.dropFirst(3).joined(separator: "&").replacingOccurrences(of: ".json", with: "")
            let query =
                queryPart.components(separatedBy: "search=").dropFirst().joined(separator: "search=")
                .removingPercentEncoding ?? ""
            let metas = (type == "movie" ? allMovies : allSeries).filter {
                query.isEmpty || String(describing: $0["name"] ?? "").localizedCaseInsensitiveContains(query)
            }
            return response(["metas": metas])
        }
        if parts.count == 3, parts[0] == "meta" {
            let id = parts[2].replacingOccurrences(of: ".json", with: "")
            let found: [String: Any]? =
                parts[1] == "series"
                ? media(DemoCatalog.series) : DemoCatalog.films.first { $0.summary.id == id }.map(media)
            return found.map { response(["meta": $0]) } ?? response(["error": "Not found"], 404)
        }
        if parts.count == 3, parts[0] == "stream" {
            let identifier = parts[2].replacingOccurrences(of: ".json", with: "")
            let film = DemoCatalog.films.first { $0.summary.id == identifier }
            let episode = DemoCatalog.series.episodes.first { $0.id == identifier }
            guard let title = film?.summary.name ?? episode?.title else {
                return response(["error": "Not found"], 404)
            }
            let filmIndex = DemoCatalog.films.firstIndex { $0.summary.id == identifier } ?? 6
            let label: String
            if let film {
                label = "\(film.summary.name) \(film.summary.releaseInfo ?? "")"
            } else if let episode {
                label = "The Beverly Hillbillies S01E\(String(format: "%02d", episode.number)) \(title)"
            } else {
                label = title
            }
            let streams = variants.enumerated().map { index, variant -> [String: Any] in
                // Seeders and sizes differ a little per title, so lists do not look copied.
                let seeders = max(3, variant.seeders - filmIndex * 7)
                let size = variant.gigabytes * (1 + Double(filmIndex % 3) / 10)
                return [
                    "name": "\(variant.cached ? "[TB+]" : "[TB download]") Public Domain",
                    "title": "\(label) \(variant.quality)\n👤 \(seeders) 💾 \(String(format: "%.1f", size)) GB ⚙️ \(variant.origin)",
                    "infoHash": DemoBackend.infoHash(filmIndex * 10 + index + 1, cached: variant.cached),
                    "fileIdx": 0,
                    "behaviorHints": [
                        "filename": "\(label) \(variant.quality).mkv",
                        "videoSize": Int64(size * 1_000_000_000),
                        "cached": variant.cached,
                    ],
                ]
            }
            return response(["streams": streams])
        }
        return response(["error": "Not found"], 404)
    }
}
#endif
