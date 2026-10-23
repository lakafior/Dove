import Foundation

/// One game in the library: every release of it (PC repack, a ROM, another platform), with the metadata match.
/// ROM sets and other collections are titles of their own, one per item, never matched.
public struct GameTitle: Identifiable, Sendable, Hashable {
    public let id: String
    public let guess: GameGuess
    public var game: GameSummary?
    public var items: [ShelfItem]
    /// A ROM set or another many-game pack: listed by its name.
    public var isCollection: Bool

    public var name: String { game?.title ?? guess.title }
    public var year: String? { (game?.year ?? guess.year).map(String.init) }
    public var cover: URL? { game?.cover }

    /// The platforms the user holds it for (from the releases), else the ones the game is on.
    public var platforms: [GamePlatform] {
        let held = items.compactMap { GameGuess(releaseName: $0.name).platform }
        let unique = GamePlatform.allCases.filter(Set(held).contains)
        return unique.isEmpty ? (game?.platforms ?? []) : unique
    }

    public var backends: [BackendID] {
        Array(Set(items.map(\.item.backend))).sorted { $0.rawValue < $1.rawValue }
    }
    public var latestAdded: Date? { items.compactMap(\.item.addedAt).max() }
    public var size: Int64 { items.compactMap(\.item.size).reduce(0, +) }
    public var status: LibraryFilter.Status { LibraryFilter.Status(least: items) }
}

extension LibraryShelf {
    /// Games grouped by matched game (releases for several platforms are one), else by the guessed title; each
    /// collection on its own. Newest first.
    public static func games(_ items: [ShelfItem], matches: [String: GameSummary]) -> [GameTitle] {
        var games: [String: GameTitle] = [:]
        var order: [String] = []
        for item in items where item.kind == .games {
            let title: GameTitle
            if let guess = item.gameGuess {
                let game = matches[guess.key]
                let id = game.map { "game:\($0.id)" } ?? "guess:\(guess.key)"
                title = games[id] ?? GameTitle(id: id, guess: guess, game: game, items: [], isCollection: false)
            } else {
                let id = "collection:\(item.id)"
                title = GameTitle(id: id, guess: GameGuess(title: item.name), items: [], isCollection: true)
            }
            if games[title.id] == nil { order.append(title.id) }
            games[title.id] = title
            games[title.id]!.items.append(item)
        }
        return order.compactMap { games[$0] }
            .sorted { ($0.latestAdded ?? .distantPast) > ($1.latestAdded ?? .distantPast) }
    }
}

extension LibraryFilter {
    /// Games: only Games (or no category) keeps them; the query also finds the matched title.
    public func apply(to games: [GameTitle]) -> [GameTitle] {
        games.compactMap { game in
            if let category, category != .games { return nil }
            var game = game
            game.items = game.items.filter { keeps($0, names: [game.name]) }
            return game.items.isEmpty ? nil : game
        }
    }
}

extension LibraryRequest {
    /// Games for a described filter: their kind, years and words.
    public func apply(to games: [GameTitle]) -> [GameTitle] {
        guard category == nil || category == .games, resolutions.isEmpty else { return [] }
        return games.compactMap { game in
            guard keepsYear(game.year), keepsWords([game.name]) else { return nil }
            var game = game
            game.items = game.items.filter(keepsItem)
            return game.items.isEmpty ? nil : game
        }
    }
}

extension LibraryMatcher {
    /// Games added from a game's screen carry the game: recorded without a search (the user's own choice stays).
    public static func applyGameHints(_ items: [ShelfItem], store: MetadataStore<GameSummary>) async -> [String: GameSummary] {
        var applied: [String: GameSummary] = [:]
        for item in items {
            guard let game = item.hint?.game, let guess = item.gameGuess, applied[guess.key] == nil else { continue }
            let key = guess.key
            // A hint for a game on other platforms than the release is a wrong pick (a 2021 Game Boy Color homebrew
            // recorded for a FitGirl repack of the 2025 PC game): the search decides instead.
            if let platform = guess.platform, !game.platforms.isEmpty, !game.platforms.contains(platform) { continue }
            switch await store.entry(for: key) {
            case .manual: continue
            case .matched(let current) where current.id == game.id: continue
            default:
                await store.set(.matched(game), for: key)
                applied[key] = game
            }
        }
        return applied
    }
}
