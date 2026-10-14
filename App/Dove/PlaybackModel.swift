import DoveKit
import Foundation
import Observation
import UIKit

/// Which player gets links, and handing them over: a URL scheme for apps on this device, JSON-RPC for Kodi.
/// The chosen player is per device (UserDefaults: an iPad may use another app); Kodi's address and login are in
/// the Keychain, synced like every secret.
@MainActor
@Observable
final class PlaybackModel {
    private let keychain: KeychainStore

    var player: ExternalPlayer {
        didSet { UserDefaults.standard.set(player.rawValue, forKey: Self.playerKey) }
    }

    /// `ExternalPlayer.custom`'s template, with `{url}`, `{encodedUrl}` and `{filename}`.
    var customTemplate: String {
        didSet { UserDefaults.standard.set(customTemplate, forKey: Self.templateKey) }
    }

    private(set) var kodi: KodiServer?

    private static let playerKey = "player"
    private static let templateKey = "playerTemplate"

    init(keychain: KeychainStore) {
        self.keychain = keychain
        player = UserDefaults.standard.string(forKey: Self.playerKey).flatMap(ExternalPlayer.init) ?? .infuse
        customTemplate = UserDefaults.standard.string(forKey: Self.templateKey) ?? ""
        kodi = (try? keychain.get(.kodi))
            .flatMap { try? JSONDecoder().decode(KodiServer.self, from: Data($0.utf8)) }
    }

    /// Checks Kodi answers before keeping it. Nil removes it (and falls back to Infuse if Kodi was the player).
    func saveKodi(_ server: KodiServer?) async throws {
        if let server {
            try await KodiClient(server: server).ping()
            let data = try JSONEncoder().encode(server)
            try keychain.set(String(decoding: data, as: UTF8.self), for: .kodi)
        } else {
            try keychain.set(nil, for: .kodi)
            if player == .kodi { player = .infuse }
        }
        kodi = server
    }

    /// Installed (by scheme), set up (Kodi) or filled in (Custom).
    func isUsable(_ candidate: ExternalPlayer) -> Bool {
        switch candidate {
        case .kodi: kodi != nil
        case .custom: !customTemplate.trimmingCharacters(in: .whitespaces).isEmpty
        default: candidate.scheme.flatMap { URL(string: "\($0)://") }.map(UIApplication.shared.canOpenURL) ?? false
        }
    }

    /// Players for a one-off "Play in…": usable ones other than the default.
    var otherPlayers: [ExternalPlayer] {
        ExternalPlayer.allCases.filter { $0 != player && isUsable($0) }
    }

    /// For buttons and menus: "Play in VLC".
    var playLabel: String { "Play in \(player.displayName)" }

    /// How many entries to fetch links for: all for players with playlists, one for the rest.
    func limit<T>(_ entries: [T], for chosen: ExternalPlayer? = nil) -> [T] {
        (chosen ?? player).takesPlaylist ? entries : Array(entries.prefix(1))
    }

    /// The note "Play all" shows when the player takes one file.
    func singleFileNote(requested count: Int, for chosen: ExternalPlayer? = nil) -> String? {
        let chosen = chosen ?? player
        guard count > 1, !chosen.takesPlaylist else { return nil }
        return "\(chosen.displayName) plays one file at a time: playing the first. Infuse and Kodi take the whole list."
    }

    /// Plays `entries` in `chosen` (default: the user's player). Players without playlists get the first.
    func play(_ entries: [PlayEntry], in chosen: ExternalPlayer? = nil) async throws {
        guard !entries.isEmpty else { return }
        let chosen = chosen ?? player
        if chosen == .kodi {
            guard let kodi else { throw BackendError.api(message: "Set up Kodi in Settings › Playback.") }
            try await KodiClient(server: kodi).play(entries)
            return
        }
        guard let url = chosen.link(for: entries, customTemplate: customTemplate) else {
            throw BackendError.api(message: chosen == .custom
                ? "The custom player template needs {url} or {encodedUrl} (Settings › Playback)."
                : "Could not build a link for \(chosen.displayName).")
        }
        guard await UIApplication.shared.open(url) else {
            throw BackendError.api(message: "\(chosen.displayName) did not open. Is it installed?")
        }
    }
}
