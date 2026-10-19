import Foundation

/// Which addon and which of its streams a direct download came from: enough to ask the addon again for a fresh
/// link (they expire within hours). Holds no link and no token: the addon is named by its manifest id
/// (`aiostreams` for the AIOStreams Search API), the stream by the title's ID and the file name.
public struct StreamFileRef: Codable, Sendable, Hashable {
    public static let aioStreams = "aiostreams"

    /// The manifest id (`com.penguplay`), or `aiostreams`.
    public var source: String
    public var type: MediaType
    /// `tt0111161`, `tt11280740:1:1`.
    public var streamID: String
    public var fileName: String
    public var bingeGroup: String?
    public var size: Int64?

    public init(source: String, type: MediaType, streamID: String, fileName: String, bingeGroup: String? = nil, size: Int64? = nil) {
        self.source = source
        self.type = type
        self.streamID = streamID
        self.fileName = fileName
        self.bingeGroup = bingeGroup
        self.size = size
    }

    /// For a source row's candidate (its ID is `<manifest id>#<index>` or `aiostreams#<index>`).
    public init?(candidate: StreamCandidate, type: MediaType, streamID: String) {
        guard let file = candidate.directFile, let source = candidate.id.split(separator: "#").first.map(String.init),
              !source.isEmpty, !source.hasPrefix("newznab:")
        else { return nil }
        self.init(source: source, type: type, streamID: streamID, fileName: file.name, bingeGroup: candidate.bingeGroup, size: file.size)
    }

    /// The same file in a new answer: same name, else same binge group and size, else the only one in the binge group.
    public func pick(from candidates: [StreamCandidate]) -> DirectStreamFile? {
        let files = candidates.compactMap { candidate in candidate.directFile.map { (candidate, $0) } }
        if let match = files.first(where: { $0.1.name == fileName }) { return match.1 }
        guard let bingeGroup else { return nil }
        let group = files.filter { $0.0.bingeGroup == bingeGroup }
        if let size, let match = group.first(where: { $0.1.size == size }) { return match.1 }
        return group.count == 1 ? group[0].1 : nil
    }
}
