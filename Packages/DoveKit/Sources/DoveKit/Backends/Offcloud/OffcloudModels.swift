import Foundation

/// Response of `POST /cloud`.
struct OffcloudAddResult: Decodable {
    let requestId: String?
    let fileName: String?
    let status: String?
    /// Set instead of a request when the account lacks an add-on (`premium`, `links`, `proxy`, `cloud`, `video`).
    let notAvailable: String?
}

/// Entry of `GET /cloud/history`. Carries no sizes and no progress.
struct OffcloudHistoryItem: Decodable {
    let requestId: String
    let fileName: String?
    let status: String?
    let createdOn: String?
    let isDirectory: Bool?
    /// Download host prefix: files live at `https://{server}.offcloud.com/cloud/download/{requestId}/{fileName}`.
    let server: String?
}

struct OffcloudAccountInfo: Decodable {
    let isPremium: Bool?
}

/// Library item IDs: everything Offcloud stores is a "cloud" request.
enum OffcloudItemRef: Equatable {
    case cloud(String)

    init?(_ id: String) {
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "cloud", !parts[1].isEmpty else { return nil }
        self = .cloud(String(parts[1]))
    }

    var id: String {
        switch self {
        case .cloud(let value): "cloud:\(value)"
        }
    }

    var requestID: String {
        switch self {
        case .cloud(let value): value
        }
    }
}

extension OffcloudHistoryItem {
    func libraryItem(files: [LibraryFile] = []) -> LibraryItem {
        LibraryItem(
            id: OffcloudItemRef.cloud(requestId).id,
            backend: .offcloud,
            name: fileName ?? requestId,
            status: libraryStatus,
            files: files,
            addedAt: createdOn.flatMap(APIDate.parse)
        )
    }

    var libraryStatus: LibraryItem.Status {
        switch status {
        case "downloaded": .ready
        case "created", "queued", nil: .queued
        case "downloading": .downloading(progress: 0)
        case let other?: .failed(reason: other)
        }
    }

    /// Direct link for a single-file request (folders go through `cloud/explore`).
    var singleFileURL: URL? {
        guard let server, let fileName,
              let name = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"]))
        else { return nil }
        return URL(string: "https://\(server).offcloud.com/cloud/download/\(requestId)/\(name)")
    }
}

enum OffcloudMagnet {
    /// Offcloud accepts a garbage magnet and leaves it "Loading..." forever, so validate before adding.
    static func hasValidInfoHash(_ magnet: String) -> Bool {
        guard let topic = URLComponents(string: magnet)?.queryItems?
            .first(where: { $0.name.lowercased() == "xt" })?.value?
            .lowercased(),
            topic.hasPrefix("urn:btih:")
        else { return false }
        let hash = topic.dropFirst("urn:btih:".count)
        let base32 = Set("abcdefghijklmnopqrstuvwxyz234567")
        return (hash.count == 40 && hash.allSatisfy(\.isHexDigit)) || (hash.count == 32 && hash.allSatisfy(base32.contains))
    }
}
