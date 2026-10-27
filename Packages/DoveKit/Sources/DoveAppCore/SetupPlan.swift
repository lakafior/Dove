import DoveKit

private let debridServices = BackendID.allCases.filter { !$0.isUsenet && !$0.isStorage }

/// A service or feature the user wants to set up.
public enum SetupChoice: Sendable, Hashable, CaseIterable, Identifiable {
    case service(BackendID)
    case indexers, addons, movies, games, books, calibre, iCloudDrive, player, reading

    public static var allCases: [SetupChoice] {
        debridServices.map(SetupChoice.service) + [.service(.nzbdav), .indexers, .addons, .movies, .games, .books, .calibre, .iCloudDrive, .player, .reading]
    }

    public var id: Self { self }

    public var title: String {
        switch self {
        case .service(let backend): backend == .nzbdav ? "nzbdav / InfiniDysk" : backend.displayName
        case .indexers: "Newznab / Torznab indexers"
        case .addons: "Stremio addons / AIOStreams"
        case .movies: "Movies and TV (TMDB)"
        case .games: "Games (IGDB)"
        case .books: "Books"
        case .calibre: "Calibre"
        case .iCloudDrive: "iCloud Drive"
        case .player: "A player other than Infuse, or Kodi"
        case .reading: "Kindle, PocketBook or e-mail"
        }
    }

    public var group: String {
        switch self {
        case .service(let backend) where debridServices.contains(backend): "Services you pay for"
        case .indexers, .addons: "Search"
        case .movies, .games, .books: "Titles and covers"
        case .calibre, .iCloudDrive: "Places"
        case .player, .reading: "Playing and reading"
        default: "Your own servers"
        }
    }
}

/// One existing settings page in the order the first-run flow visits it.
public struct SetupStep: Sendable, Hashable, Identifiable {
    public enum Page: Sendable, Hashable {
        case service(BackendID)
        case routing, indexers, addons, movies, games, books
        case iCloudDrive, calibre, saveTo, player, reading, adult, done
    }

    public let page: Page
    public let alreadySet: Bool
    public var id: Page { page }
    public var choice: SetupChoice? {
        switch page {
        case .service(let backend): .service(backend)
        case .indexers: .indexers
        case .addons: .addons
        case .movies: .movies
        case .games: .games
        case .books: .books
        case .iCloudDrive: .iCloudDrive
        case .calibre: .calibre
        case .player: .player
        case .reading: .reading
        case .routing, .saveTo, .adult, .done: nil
        }
    }

    public init(page: Page, alreadySet: Bool = false) {
        self.page = page
        self.alreadySet = alreadySet
    }
}

/// The pages selected for this first run, including their current setup state.
public struct SetupPlan: Sendable, Hashable {
    public let steps: [SetupStep]

    public init(steps: [SetupStep]) { self.steps = steps }

    public static func steps(for choices: Set<SetupChoice>, configured: Set<SetupChoice> = []) -> [SetupStep] {
        var pages = debridServices.filter { choices.contains(.service($0)) }.map(SetupStep.Page.service)
        if choices.contains(.service(.nzbdav)) { pages.append(.service(.nzbdav)) }
        // The order matters once two services could take the same add (a debrid with Usenet on and nzbdav count too).
        if pages.count > 1 { pages.append(.routing) }
        if choices.contains(.indexers) { pages.append(.indexers) }
        if choices.contains(.addons) { pages.append(.addons) }
        if choices.contains(.movies) { pages.append(.movies) }
        if choices.contains(.games) { pages.append(.games) }
        if choices.contains(.books) { pages.append(.books) }
        if choices.contains(.iCloudDrive) { pages.append(.iCloudDrive) }
        if choices.contains(.calibre) { pages.append(.calibre) }
        if choices.contains(.iCloudDrive) || choices.contains(.calibre) { pages.append(.saveTo) }
        if choices.contains(.player) { pages.append(.player) }
        if choices.contains(.reading) { pages.append(.reading) }
        pages.append(.adult)
        pages.append(.done)
        return pages.map { page in
            let step = SetupStep(page: page)
            return SetupStep(page: page, alreadySet: step.choice.map(configured.contains) ?? false)
        }
    }

    public static func plan(for choices: Set<SetupChoice>, configured: Set<SetupChoice> = []) -> SetupPlan {
        SetupPlan(steps: Self.steps(for: choices, configured: configured))
    }
}

/// Whether the setup wizard should open for an app launch.
public enum SetupState {
    public static func shouldPresentAutomatically(finished: Bool, hasAnythingConfigured: Bool) -> Bool {
        !finished && !hasAnythingConfigured
    }
}
