<div align="center">

<img src="website/assets/icon.png" width="128" alt="Dove icon">

# Dove

**Your debrid and Usenet services, in one app.**<br>
Find a film, a season, a book or an album, send it to your services, then play, listen or download.

[![Release](https://img.shields.io/github/v/release/lakafior/Dove?label=release&color=1a6fd6)](https://github.com/lakafior/Dove/releases/latest)
[![Release build](https://github.com/lakafior/Dove/actions/workflows/release.yml/badge.svg)](https://github.com/lakafior/Dove/actions/workflows/release.yml)
[![Website](https://github.com/lakafior/Dove/actions/workflows/website.yml/badge.svg)](https://github.com/lakafior/Dove/actions/workflows/website.yml)
[![Downloads](https://img.shields.io/github/downloads/lakafior/Dove/total?color=1a6fd6)](https://github.com/lakafior/Dove/releases)
[![License: MPL 2.0](https://img.shields.io/github/license/lakafior/Dove?color=1a6fd6)](LICENSE)<br>
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-black?logo=apple)](#download)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)](#download)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](Packages/DoveKit)
[![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)](#building)

[![Download for Mac](https://img.shields.io/badge/Download_for_Mac-DMG-1a6fd6?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/lakafior/Dove/releases/latest)
[![iPhone: coming to AltStore PAL](https://img.shields.io/badge/iPhone-coming_to_AltStore_PAL-555?style=for-the-badge&logo=apple&logoColor=white)](#download)
[![dove.smigi.net](https://img.shields.io/badge/dove.smigi.net-website-555?style=for-the-badge)](https://dove.smigi.net)

[Download](#download) · [Features](#features) · [Plugins](#plugins) · [Privacy and support](#privacy-and-support) · [Building](#building) · [License](#license)

</div>

> **Bring your own.** Dove ships with no content sources. You add your own service keys, Stremio addons,
> indexers and plugin repositories, and Dove talks to them straight from your device. There is no Dove server.

<p align="center">
  <img src="docs/screenshots/iphone-search.png" width="190" alt="Search home: services, downloads in progress, watchlist, recently added">
  <img src="docs/screenshots/iphone-sources.png" width="190" alt="A film's sources: resolutions, sizes, seeders, cached on TorBox">
  <img src="docs/screenshots/iphone-library.png" width="190" alt="Library shelves: movies, series, books">
  <img src="docs/screenshots/iphone-audiobook.png" width="190" alt="The audiobook player">
</p>
<p align="center">
  <img src="docs/screenshots/mac-home.png" width="800" alt="The Mac app: sidebar and start page">
</p>
<p align="center"><sub>Public-domain films, books and recordings from Dove's demo mode: no accounts or keys involved.
<code>scripts/screenshots.sh</code> regenerates them.</sub></p>

## Download

| Platform | How |
|---|---|
| **Mac** (macOS 26+) | [Latest release](https://github.com/lakafior/Dove/releases/latest): a notarized DMG. Open it and drag Dove to Applications. Dove checks for a new release once a day and never downloads one by itself. |
| **iPhone** (iOS 17+) | Coming to AltStore PAL. Until then, [build it yourself](#building). |

Settings, keys and addons sync between your devices through iCloud Keychain (end-to-end encrypted).

## Features

| Source | Services | Then |
|---|---|---|
| 🧲 Magnet, info hash, `.torrent` | Real-Debrid, TorBox, Offcloud, Debrid-Link, Premiumize, AllDebrid | play the service's stream or WebDAV link |
| 🔗 Hoster link | the same debrid services (those that unlock the site) | or download to the device |
| 📰 NZB link or file | nzbdav / InfiniDysk; TorBox, Offcloud, Premiumize with Usenet | or listen in Dove |

| Area | What it does |
|---|---|
| **Services** | Your priority order with fallback: "Automatic" tries the next service on any error. Private torrents go only to services that seed them. Status lights, premium days left and a speed test. |
| **Search** | Movies & TV, Books, Audiobooks, Music, Games, Software. Sources from your Stremio addons (AIOStreams, Torrentio…) and Newznab/Torznab indexers, merged into one row per release with its traits, ⚡ where it is cached and warnings for Apple TV. Ranking, filters, and a search by description. |
| **In** | Smart field, clipboard, share sheet, `.torrent`/`.nzb` files, several links at once, title links from IMDb, TMDB, Apple TV, Letterboxd, Trakt, Rotten Tomatoes, JustWatch. |
| **Library** | Every service in one list, as posters or files. Series mapped to episodes even inside packs, with missing ones named. A review after each refresh: new episodes, gaps, releases that could be better. Reinsert, move, copy, delete. |
| **Play** | Infuse (playlists, episode names), VLC, Outplayer, SenPlayer, nPlayer, VidHub, IINA, Kodi or a custom URL template. |
| **Download** | Background downloads with resume, "Download only" (add, fetch, delete from the service), Live Activity. Files go to the device, iCloud Drive, Calibre or a service. |
| **Listen and read** | Audiobook player with chapters, speed, sleep timer and positions synced across devices; music queue; books to Apple Books, Kindle or PocketBook. |
| **Watchlist** | New episodes and release dates, with a local notification when something lands. |
| **System** | Widgets, Control Center, Siri and Shortcuts, Spotlight, Quick Actions, a Files and Finder location. On the Mac: a native app (not Catalyst) with source tables, menu bar extra, Dock progress and drops. |

The full list, and what is still left, is in [docs/roadmap.md](docs/roadmap.md).

## Plugins

Plugins add metadata sources and libraries to Dove's search. They run on your device in a JavaScript sandbox,
reach only the sites they declare, and install only when their checksum matches the repository's index.

In Dove, open Settings › Search and metadata › Plugins › Add repository and paste:

```
https://lakafior.github.io/dove-plugins/index.json
```

[**dove-plugins**](https://github.com/lakafior/dove-plugins) has book and audiobook metadata (lubimyczytac.pl,
Audioteka, Storytel, Audible), game metadata (Steam, GOG, LaunchBox, RAWG, SteamGridDB, TheGamesDB,
ScreenScraper), and the Internet Archive and Wolne Lektury libraries.

To write your own, see the [plugin API](docs/plugins.md). Repositories by other authors are listed at
[dove.smigi.net/plugins](https://dove.smigi.net/plugins).

## Privacy and support

Dove collects no personal data and has no server: it talks only to the services you set up.

- [Privacy policy](https://dove.smigi.net/privacy)
- [Support and FAQ](https://dove.smigi.net/support)
- [Report a problem](https://github.com/lakafior/Dove/issues) or write to [dove@smigi.net](mailto:dove@smigi.net)

## Building

Requirements: Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen). No third-party runtime dependencies:
Foundation, SwiftUI, `URLSession`, `XMLParser` and Apple's frameworks only.

```sh
brew install xcodegen
xcodegen generate        # Dove.xcodeproj is generated, not committed
open Dove.xcodeproj
```

| Task | Command |
|---|---|
| iOS app | `xcodebuild -project Dove.xcodeproj -scheme Dove -destination 'generic/platform=iOS' -allowProvisioningUpdates build` |
| Mac app | `xcodebuild -project Dove.xcodeproj -scheme DoveMac -destination 'platform=macOS' -allowProvisioningUpdates build` |
| Core tests (no simulator) | `cd Packages/DoveKit && swift test` |
| Screenshots (demo mode) | `./scripts/screenshots.sh` (or `ios`, `mac`) |
| Notarized DMG | `.github/workflows/release.yml` on a `v*` tag, or `scripts/build-mac.sh`, `notarize.sh`, `make-dmg.sh` |

<details>
<summary>How it fits together</summary>

```
Source (what)            Backend (where)                                   Playback (how)
──────────────           ───────────────────────────────────────────       ──────────────────────────
🧲 magnet / .torrent  →  Real-Debrid · TorBox · Offcloud · Debrid-Link  →  Infuse / VLC / Kodi / …
🔗 hoster link        →  Premiumize · AllDebrid (priority + fallback)   →  download to the device
📰 NZB                →  nzbdav · TorBox · Offcloud · Premiumize        →  audiobooks: Dove's player
```

The source type picks the backend family; your priority order picks the service within it.

</details>

<details>
<summary>Project layout</summary>

```
App/Dove/               SwiftUI app: views, the iOS platform layer, intents, background refresh
App/DoveShare/          Share extension (links, magnets, .torrent, .nzb)
App/DoveFiles/          File Provider extension (the Files app location)
App/DoveWidgets/        Widgets, Control Center controls, the downloads Live Activity
App/Mac/                Mac app: sidebar window, tables, commands, menu bar extra, Settings window
App/MacFiles/           Finder location, File Provider extension
App/MacWidgets/         Desktop widgets
App/Components/         Views shared by both apps: covers, rows, badges, settings forms
App/Shared/             SwiftUI shared by the app and its extensions
App/Activity/           Types shared by the app and the widgets (Live Activity, widget intents)
Packages/DoveKit/       All logic: models, backends, routing, search, library, Keychain (tested on macOS);
                        also builds DoveAppCore, the app and feature models shared by iOS and Mac
scripts/                Release and screenshot scripts
website/                dove.smigi.net (a Cloudflare Worker with static assets)
docs/                   Roadmap, implementation record, Mac plan, plugin API
project.yml             XcodeGen spec
```

</details>

## License

[Mozilla Public License 2.0](LICENSE).

Dove is a client for services you already pay for. Use it only with content you have the right to access.
