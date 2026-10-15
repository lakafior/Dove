import Foundation

/// Settings that are not secrets but should survive a fresh install: stored as one Keychain item, so
/// iCloud Keychain carries them with the keys. Every field decodes leniently, so older and newer builds
/// read each other's saves.
public struct SyncedPreferences: Codable, Sendable, Equatable {
    public var downloadOnly = false
    public var sourceFilter = SourceFilter()
    /// AIOStreams variant for Dove's searches; empty for none.
    public var aioStreamsVariant = ""
    /// Adult items and the Adult search category; hidden by default. The Files extension reads it too.
    public var showAdult = false
    /// Which sources each search category asks.
    public var sourceSelection = SourceSelection()
    /// Where "Read" sends ebooks; nil asks every time.
    public var readIn: ReadingTarget?
    /// The user's Send to Kindle address (`name@kindle.com`); empty hides Kindle.
    public var kindleAddress = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case downloadOnly, sourceFilter, aioStreamsVariant, showAdult, sourceSelection, readIn, kindleAddress
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadOnly = (try? c.decodeIfPresent(Bool.self, forKey: .downloadOnly)) ?? false
        sourceFilter = (try? c.decodeIfPresent(SourceFilter.self, forKey: .sourceFilter)) ?? SourceFilter()
        aioStreamsVariant = (try? c.decodeIfPresent(String.self, forKey: .aioStreamsVariant)) ?? ""
        showAdult = (try? c.decodeIfPresent(Bool.self, forKey: .showAdult)) ?? false
        sourceSelection = (try? c.decodeIfPresent(SourceSelection.self, forKey: .sourceSelection)) ?? SourceSelection()
        readIn = try? c.decodeIfPresent(ReadingTarget.self, forKey: .readIn)
        kindleAddress = (try? c.decodeIfPresent(String.self, forKey: .kindleAddress)) ?? ""
    }
}

extension SharedConfiguration {
    /// Nil when nothing was saved yet (first launch, or a build from before preferences moved here).
    public static func preferences(from keychain: KeychainStore) -> SyncedPreferences? {
        guard let json = try? keychain.get(.preferences) else { return nil }
        return try? JSONDecoder().decode(SyncedPreferences.self, from: Data(json.utf8))
    }

    public static func savePreferences(_ preferences: SyncedPreferences, to keychain: KeychainStore) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        try? keychain.set(String(decoding: data, as: UTF8.self), for: .preferences)
    }
}
