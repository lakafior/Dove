import Foundation

/// What a game runs on: PC, a console or a handheld. Games are one kind (`ContentKind.games`); the platform is an
/// attribute, read from ROM extensions, release names, Newznab categories and metadata services' platform names.
public enum GamePlatform: String, Codable, Sendable, CaseIterable, Hashable {
    case pc
    case nintendoSwitch = "switch"
    case wiiU, wii, gameCube, n64, snes, nes
    case gameBoy, gameBoyColor, gameBoyAdvance, nintendoDS, nintendo3DS
    case ps1, ps2, ps3, ps4, ps5, psp, psVita
    case xbox, xbox360, xboxOne, xboxSeries
    case megaDrive, masterSystem, saturn, dreamcast
    case arcade

    public var displayName: String {
        switch self {
        case .pc: "PC"
        case .nintendoSwitch: "Switch"
        case .wiiU: "Wii U"
        case .wii: "Wii"
        case .gameCube: "GameCube"
        case .n64: "N64"
        case .snes: "SNES"
        case .nes: "NES"
        case .gameBoy: "Game Boy"
        case .gameBoyColor: "Game Boy Color"
        case .gameBoyAdvance: "GBA"
        case .nintendoDS: "DS"
        case .nintendo3DS: "3DS"
        case .ps1: "PS1"
        case .ps2: "PS2"
        case .ps3: "PS3"
        case .ps4: "PS4"
        case .ps5: "PS5"
        case .psp: "PSP"
        case .psVita: "PS Vita"
        case .xbox: "Xbox"
        case .xbox360: "Xbox 360"
        case .xboxOne: "Xbox One"
        case .xboxSeries: "Xbox Series"
        case .megaDrive: "Mega Drive"
        case .masterSystem: "Master System"
        case .saturn: "Saturn"
        case .dreamcast: "Dreamcast"
        case .arcade: "Arcade"
        }
    }

    /// ROM and image extensions that name one platform. `iso`, `chd`, `rvz` and `cue`/`bin` are left out: several
    /// platforms (or audio CDs, for `cue`) use them, so the name decides.
    static let extensions: [String: GamePlatform] = [
        "nsp": .nintendoSwitch, "xci": .nintendoSwitch, "nsz": .nintendoSwitch, "xcz": .nintendoSwitch,
        "wua": .wiiU, "wux": .wiiU, "wbfs": .wii, "gcz": .gameCube,
        "z64": .n64, "n64": .n64, "v64": .n64,
        "sfc": .snes, "smc": .snes, "nes": .nes,
        "gb": .gameBoy, "gbc": .gameBoyColor, "gba": .gameBoyAdvance,
        "nds": .nintendoDS, "3ds": .nintendo3DS, "cia": .nintendo3DS,
        "cso": .psp, "pbp": .psp, "vpk": .psVita,
        "md": .megaDrive, "gen": .megaDrive, "smd": .megaDrive, "sms": .masterSystem,
    ]

    /// Extensions only games use, though they do not tell the platform.
    static let gameOnlyExtensions: Set<String> = ["chd", "rvz"]

    /// Every extension that makes a file a game.
    public static var fileExtensions: Set<String> { Set(extensions.keys).union(gameOnlyExtensions) }

    /// The platform a file's extension stands for.
    public init?(fileName: String) {
        guard let platform = Self.extensions[(fileName as NSString).pathExtension.lowercased()] else { return nil }
        self = platform
    }

    /// Markers in release names, most specific first ("PS4" before "PS", "Xbox 360" before "Xbox").
    static let nameMarkers: [(GamePlatform, String)] = [
        (.nintendoSwitch, #"\b(nsw|nintendo switch|switch nsp|switch xci)\b"#),
        (.wiiU, #"\b(wii ?u)\b"#),
        (.wii, #"\b(wii)\b"#),
        (.gameCube, #"\b(gamecube|ngc)\b"#),
        (.n64, #"\b(n64|nintendo 64)\b"#),
        (.snes, #"\b(snes|super nintendo|super famicom|sfc)\b"#),
        (.nes, #"\b(nes|famicom)\b"#),
        (.gameBoyAdvance, #"\b(gba|game ?boy advance)\b"#),
        (.gameBoyColor, #"\b(gbc|game ?boy colou?r)\b"#),
        (.gameBoy, #"\b(game ?boy)\b"#),
        (.nintendo3DS, #"\b(3ds)\b"#),
        (.nintendoDS, #"\b(nds|nintendo ds)\b"#),
        (.psVita, #"\b(ps ?vita|psv)\b"#),
        (.psp, #"\b(psp)\b"#),
        (.ps5, #"\b(ps5|playstation 5)\b"#),
        (.ps4, #"\b(ps4|playstation 4)\b"#),
        (.ps3, #"\b(ps3|playstation 3)\b"#),
        (.ps2, #"\b(ps2|playstation 2)\b"#),
        (.ps1, #"\b(ps1|psx|playstation 1)\b"#),
        (.xboxSeries, #"\b(xbox series( x| s| x s)?|xsx)\b"#),
        (.xboxOne, #"\b(xbox ?one|xbone)\b"#),
        (.xbox360, #"\b(xbox ?360|x360)\b"#),
        (.xbox, #"\b(xbox)\b"#),
        (.megaDrive, #"\b(mega ?drive|genesis)\b"#),
        (.masterSystem, #"\b(master system)\b"#),
        (.saturn, #"\b(sega saturn)\b"#),
        (.dreamcast, #"\b(dreamcast)\b"#),
        (.arcade, #"\b(mame|arcade)\b"#),
    ]

    /// The platform a release name gives: an extension first, then Dove's own folder name in brackets ("Title
    /// [SNES]", "[PC]"), then a marker; nil for most PC releases, which rarely say so.
    public init?(releaseName name: String) {
        if let platform = GamePlatform(fileName: name) { self = platform; return }
        if let bracketed = name.range(of: #"\[([^\]]+)\]\s*$"#, options: .regularExpression),
           let platform = GamePlatform.allCases.first(where: {
               $0.displayName.caseInsensitiveCompare(name[bracketed].dropFirst().dropLast().trimmingCharacters(in: .whitespaces)) == .orderedSame
           }) {
            self = platform
            return
        }
        let text = name.lowercased().replacingOccurrences(of: #"[._\-\[\]\(\)]"#, with: " ", options: .regularExpression)
        guard let found = Self.nameMarkers.first(where: { text.range(of: $0.1, options: .regularExpression) != nil }) else {
            return nil
        }
        self = found.0
    }

    /// Scene groups and repackers that only release PC games.
    static func isPCRelease(_ name: String) -> Bool {
        let text = name.lowercased().replacingOccurrences(of: #"[._\-\[\]\(\)]"#, with: " ", options: .regularExpression)
        return text.range(of: #"\b(fitgirl|dodi|elamigos|gog|codex|skidrow|plaza|empress|tenoke|rune|flt|razor1911|cpy|hoodlum|darksiders|kaos|chronos|setup exe)\b"#,
                          options: .regularExpression) != nil
    }

    /// A metadata service's platform name: IGDB "PlayStation 2", "Nintendo Switch", "PC (Microsoft Windows)",
    /// "Sega Mega Drive/Genesis"; Wikidata "Nintendo Entertainment System". Platforms Dove has no case for
    /// (Linux, Mac, Atari…) are nil, except desktops, which are PC.
    public init?(serviceName name: String) {
        let text = name.lowercased()
        let exact: [String: GamePlatform] = [
            "pc (microsoft windows)": .pc, "microsoft windows": .pc, "windows": .pc, "pc": .pc,
            "linux": .pc, "mac": .pc, "macos": .pc,
            "nintendo switch": .nintendoSwitch, "nintendo switch 2": .nintendoSwitch, "wii u": .wiiU, "wii": .wii,
            "nintendo gamecube": .gameCube, "gamecube": .gameCube, "nintendo 64": .n64,
            "super nintendo entertainment system": .snes, "super famicom": .snes,
            "nintendo entertainment system": .nes, "family computer": .nes,
            "game boy": .gameBoy, "game boy color": .gameBoyColor, "game boy advance": .gameBoyAdvance,
            "nintendo ds": .nintendoDS, "nintendo 3ds": .nintendo3DS, "new nintendo 3ds": .nintendo3DS,
            "playstation": .ps1, "playstation 2": .ps2, "playstation 3": .ps3, "playstation 4": .ps4,
            "playstation 5": .ps5, "playstation portable": .psp, "playstation vita": .psVita,
            "xbox": .xbox, "xbox 360": .xbox360, "xbox one": .xboxOne, "xbox series x|s": .xboxSeries,
            "xbox series x and series s": .xboxSeries, "xbox series x/s": .xboxSeries,
            "sega mega drive/genesis": .megaDrive, "sega genesis": .megaDrive, "mega drive": .megaDrive,
            "sega master system/mark iii": .masterSystem, "master system": .masterSystem,
            "sega saturn": .saturn, "dreamcast": .dreamcast, "arcade": .arcade, "arcade video game": .arcade,
        ]
        guard let platform = exact[text] else { return nil }
        self = platform
    }

    /// A release's platform: its indexer's console subcategory, else what the name says.
    public static func of(release title: String, category: Int?) -> GamePlatform? {
        category.flatMap(GamePlatform.init(newznabCategory:)) ?? GamePlatform(releaseName: title)
    }

    /// A Newznab/Torznab category's platform: 4050 PC games, 1000–1999 consoles (the subcategories most
    /// indexers use); nil for 1000 itself and "Other".
    public init?(newznabCategory category: Int) {
        let consoles: [Int: GamePlatform] = [
            1010: .nintendoDS, 1020: .psp, 1030: .wii, 1040: .xbox, 1050: .xbox360, 1060: .wii, 1070: .xbox360,
            1080: .ps3, 1110: .nintendo3DS, 1120: .psVita, 1130: .wiiU, 1140: .xboxOne, 1180: .ps4,
        ]
        if category == 4050 { self = .pc; return }
        guard let platform = consoles[category] else { return nil }
        self = platform
    }
}
