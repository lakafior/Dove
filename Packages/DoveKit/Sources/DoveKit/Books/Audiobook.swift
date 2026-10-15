import Foundation

/// One file of an audiobook: a single `.m4b`, or one of the many `.mp3` parts many releases come as.
public struct AudiobookTrack: Sendable, Hashable, Codable, Identifiable {
    public let fileID: LibraryFile.ID
    /// The file's path in the release (`CD1/01 - Chapter.mp3`): the key a saved position refers to.
    public let path: String
    public let size: Int64?

    public var id: String { fileID }

    /// The file name without folders and extension: "01 - Chapter".
    public var title: String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    public init(fileID: LibraryFile.ID, path: String, size: Int64? = nil) {
        self.fileID = fileID
        self.path = path
        self.size = size
    }
}

public enum AudiobookTracks {
    /// What AVPlayer plays. Ogg and Opus files are audio too, but iOS does not stream them.
    public static let playableExtensions: Set<String> = ["m4b", "m4a", "mp3", "aac", "flac", "wav", "aiff", "alac"]
    public static let unplayableExtensions: Set<String> = ["ogg", "opus", "wma", "ape"]

    public enum Refusal: Error, Sendable, Equatable {
        case noAudio
        /// Only formats iOS cannot play, uppercased.
        case unplayable(formats: [String])

        public var message: String {
            switch self {
            case .noAudio:
                "No audio files in this release."
            case .unplayable(let formats):
                "iPhone cannot play \(ListFormatter.localizedString(byJoining: formats)). Download it and use another app."
            }
        }
    }

    /// The release's audio files in reading order: natural order of the whole path, so `CD2/01` follows `CD1/12`
    /// and `Part 10` follows `Part 9`. Samples are left out.
    public static func tracks(in files: [LibraryFile]) -> Result<[AudiobookTrack], Refusal> {
        var unplayable: Set<String> = []
        let audio = files.filter { file in
            let ext = (file.name as NSString).pathExtension.lowercased()
            if unplayableExtensions.contains(ext) { unplayable.insert(ext.uppercased()) }
            return playableExtensions.contains(ext) && !FileKind.isSample(file.name)
        }
        guard !audio.isEmpty else {
            return .failure(unplayable.isEmpty ? .noAudio : .unplayable(formats: unplayable.sorted()))
        }
        let sorted = audio.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return .success(sorted.map { AudiobookTrack(fileID: $0.id, path: $0.name, size: $0.size) })
    }
}

/// Where an audiobook was left: a track (by path, with its index as a fallback) and the second in it.
public struct AudiobookPosition: Sendable, Hashable, Codable {
    public var trackPath: String
    public var trackIndex: Int
    public var seconds: Double
    public var updatedAt: Date
    /// The user started over or finished the book. Kept (rather than removed) so the merge with another device's
    /// older position does not bring it back.
    public var isCleared: Bool

    public init(trackPath: String, trackIndex: Int, seconds: Double, updatedAt: Date = .now, isCleared: Bool = false) {
        self.trackPath = trackPath
        self.trackIndex = trackIndex
        self.seconds = seconds
        self.updatedAt = updatedAt
        self.isCleared = isCleared
    }

    enum CodingKeys: String, CodingKey { case trackPath, trackIndex, seconds, updatedAt, isCleared }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackPath = try c.decode(String.self, forKey: .trackPath)
        trackIndex = try c.decode(Int.self, forKey: .trackIndex)
        seconds = try c.decode(Double.self, forKey: .seconds)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        isCleared = (try? c.decodeIfPresent(Bool.self, forKey: .isCleared)) ?? false
    }

    /// Where to continue in these tracks: the same file when it is there (another release of the book may number
    /// them differently), else the same index, else the start.
    public func resume(in tracks: [AudiobookTrack]) -> (index: Int, seconds: Double) {
        if let index = tracks.firstIndex(where: { $0.path == trackPath }) { return (index, seconds) }
        let name = (trackPath as NSString).lastPathComponent
        if let index = tracks.firstIndex(where: { ($0.path as NSString).lastPathComponent == name }) { return (index, seconds) }
        if tracks.indices.contains(trackIndex) { return (trackIndex, seconds) }
        return (0, 0)
    }
}

/// Positions of every audiobook, keyed by `BookGuess.key` so any release of the book continues where the last one
/// stopped. Stored as one Keychain item (`CredentialKey.audiobookPositions`) so iCloud Keychain carries it.
public struct AudiobookPositions: Sendable, Codable, Equatable {
    public private(set) var entries: [String: AudiobookPosition] = [:]
    /// Enough for anyone's listening history; the oldest go first.
    static let limit = 300

    public init() {}

    /// Nil for books never played, finished or started over.
    public subscript(key: String) -> AudiobookPosition? {
        entries[key].flatMap { $0.isCleared ? nil : $0 }
    }

    /// Books being listened to, last played first.
    public var listening: [(key: String, position: AudiobookPosition)] {
        entries.filter { !$0.value.isCleared }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .map { (key: $0.key, position: $0.value) }
    }

    /// Nil clears the book (a tombstone dated now, so the clear wins the merge with older positions elsewhere).
    public mutating func set(_ position: AudiobookPosition?, for key: String) {
        entries[key] = position ?? AudiobookPosition(trackPath: "", trackIndex: 0, seconds: 0, isCleared: true)
        if entries.count > Self.limit {
            let oldest = entries.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(entries.count - Self.limit)
            for (key, _) in oldest { entries[key] = nil }
        }
    }

    /// Keeps the newer position of each book: another device may have saved since this one loaded.
    public mutating func merge(_ other: AudiobookPositions) {
        for (key, position) in other.entries where (entries[key]?.updatedAt ?? .distantPast) < position.updatedAt {
            entries[key] = position
        }
    }
}

extension SharedConfiguration {
    public static func audiobookPositions(from keychain: KeychainStore) -> AudiobookPositions {
        guard let json = try? keychain.get(.audiobookPositions),
              let positions = try? JSONDecoder().decode(AudiobookPositions.self, from: Data(json.utf8))
        else { return AudiobookPositions() }
        return positions
    }

    /// Merges with what is stored first, so a newer position from another device is not overwritten.
    public static func saveAudiobookPositions(_ positions: AudiobookPositions, to keychain: KeychainStore) {
        var merged = audiobookPositions(from: keychain)
        merged.merge(positions)
        guard let data = try? JSONEncoder().encode(merged) else { return }
        try? keychain.set(String(decoding: data, as: UTF8.self), for: .audiobookPositions)
    }
}

/// Sleep timer choices.
public enum SleepTimer: Sendable, Hashable {
    case minutes(Int)
    /// Stops when the current track (or the m4b chapter) ends.
    case endOfChapter

    public static let choices: [SleepTimer] = [.minutes(5), .minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfChapter]

    public var label: String {
        switch self {
        case .minutes(let minutes): "\(minutes) min"
        case .endOfChapter: "End of chapter"
        }
    }
}

/// A chapter inside one track (an m4b's chapter marks), or the whole track when it has none.
public struct AudiobookChapter: Sendable, Hashable, Identifiable {
    public let trackIndex: Int
    public let title: String
    /// Seconds from the start of the track.
    public let start: Double
    public let duration: Double?

    public var id: String { "\(trackIndex)|\(start)" }

    public init(trackIndex: Int, title: String, start: Double, duration: Double?) {
        self.trackIndex = trackIndex
        self.title = title
        self.start = start
        self.duration = duration
    }

    /// The chapter playing at `seconds` of `trackIndex`: the last one that started by then.
    public static func current(in chapters: [AudiobookChapter], trackIndex: Int, seconds: Double) -> AudiobookChapter? {
        chapters.last { $0.trackIndex == trackIndex && $0.start <= seconds + 0.5 }
            ?? chapters.first { $0.trackIndex == trackIndex }
    }
}
