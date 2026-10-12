# Dove

An iOS client for debrid services and nzbdav. Add a magnet, a `.torrent`, a hoster link or an NZB from your phone, find a movie or a whole TV season, and send it to your library — then watch it in Infuse over WebDAV or download it to the device.

> Bring your own services: Dove ships with no content sources. You add your own API keys and your own Stremio addons.

## Status

Early scaffold. Stage 1 is in progress.

| Stage | Scope | State |
|---|---|---|
| 1. Core | TorBox, Real-Debrid, Offcloud; add magnet / .torrent / hoster link; library; download to device; share extension | TorBox and Real-Debrid adapters done, rest in progress |
| 2. Search | TMDB metadata (Polish titles), Stremio addon manifests or AIOStreams Search API as stream sources, "add whole season" | Planned |
| 3. Usenet | nzbdav via its SABnzbd-compatible API and WebDAV | Planned |

## How it fits together

```
Source (what)            Backend (where)                  Playback (how)
──────────────           ──────────────────────           ─────────────────────────
🧲 magnet / .torrent  →  Real-Debrid · TorBox · Offcloud → WebDAV in Infuse
🔗 hoster link        →  (user's default debrid)         → or download to the phone
📰 NZB                →  nzbdav                          →
```

The source type picks the backend family automatically; the user only chooses a default debrid.

App tabs: **Search** (smart field + title search) · **Library** (Debrid | Usenet) · **Downloads** · **Settings**.

## Project layout

```
App/Dove/               SwiftUI app (thin: views + AppModel), Resources/Assets.xcassets
Packages/DoveKit/       All logic: models, backends, routing, Keychain — fully unit-tested
project.yml             XcodeGen spec (the .xcodeproj is generated, not committed)
```

## Building

Requirements: Xcode 16+ (⌘U runs the DoveKit tests), iOS 17+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Dove.xcodeproj
```

Run the core tests without Xcode:

```sh
cd Packages/DoveKit && swift test
```

No third-party runtime dependencies.

## License

[Mozilla Public License 2.0](LICENSE).

Dove is a client for services you already pay for. Use it only with content you have the right to access.
