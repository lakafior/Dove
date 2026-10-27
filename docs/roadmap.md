# Dove roadmap

**State (2026-10-27):** the app is feature-complete for its own purpose on iOS and has a native macOS
app through phase 5, with the Finder location and the desktop widgets checked on real hardware; the
release machinery produces a notarized DMG that Gatekeeper accepts. What stands between here and a
public release is onboarding, the plugin-repository split, store metadata and a pass of checking the
remaining features on real hardware.

This file is **status only**: what is done, what is left, what was decided against. It says what a thing
is, never how it was built — that record lives in [implemented.md](implemented.md), which keeps every
decision and API quirk verbatim. The Mac plan is [macos.md](macos.md), the plugin API
[plugins.md](plugins.md).

Whether a new idea belongs in Dove at all is decided by the table in `CLAUDE.md` › *What belongs in
Dove*, not here.

---

## 1. Delivered

### Services and routing

| Capability | Covers |
|---|---|
| Six debrid backends | Real-Debrid, TorBox, Offcloud, Debrid-Link, Premiumize, AllDebrid — add, list, delete, download, WebDAV |
| Four Usenet backends | nzbdav / InfiniDysk, plus TorBox, Offcloud and Premiumize with Usenet on |
| Priority with fallback | Separate order for torrents/links and for NZBs; "Automatic" falls through on any error |
| Private trackers | Routed only to services that seed; a release already cached elsewhere goes as a bare magnet instead, so the passkey never travels and the ratio does not move |
| Hoster links | Host lists per service, daily quota and down-state respected; folders expanded |
| Account state | Online/offline lights, premium days left, speed test that can reorder the priority list |
| Settings export / import | Every credential as JSON, with or without secrets; merge on import |

### Getting files in and out

| Capability | Covers |
|---|---|
| Sources in | Smart field, clipboard, share extension, `.torrent`/`.nzb` files, several links at once, title links from IMDb/TMDB/Apple TV/Letterboxd/Trakt/RT/JustWatch |
| Download manager | Background session, progress, pause/resume, retry with a fresh link, notifications, Live Activity |
| Download-only jobs | Add → wait → download the picked files → delete from the service |
| Places a file can go | This device, iCloud Drive, Calibre, or a debrid cloud that fetches plain links; default per content kind, filed by `LibraryFolderLayout` |
| Files app / Finder | File Provider location: browse services, download on open, delete, drop a `.torrent` in to add it |

### Search

| Capability | Covers |
|---|---|
| Sources | Stremio addons, AIOStreams Search API with Dove's own unfiltered config variant, and Dove's own Newznab and Torznab indexers queried from the device |
| Categories | Movies & TV, Books, Audiobooks, Music, Games, Software, Adult, All — each with the right metadata step first |
| Source rows | One release merged across services and trackers, with traits, per-service cache ⚡, origin, seeders, age and warnings |
| Ranking | Tiers: ready → direct file links → uncached public → uncached private → limited; quality sorts within a tier |
| Filters | Resolution, source, codec, HDR, audio, language, cached-on, access, tracker, found-by; plus a natural-language filter on top (Apple Foundation Models) |
| Find by description | Describe a title; candidates are verified against real metadata, with a TMDB keyword pass as a second route |
| Metadata | Video TMDB · books Open Library, Apple Books, Google Books, Hardcover · music MusicBrainz, Apple Music · games IGDB, Wikidata · plus any plugin |

### Library

| Capability | Covers |
|---|---|
| One list across services | Cached first, refreshed behind it; titles with posters, matched automatically and fixable by hand |
| Content kinds | Video, music, books, audiobooks, games, software, adult, other — learned from files and names, changeable by hand |
| Series | Seasons and episodes mapped to files even inside packs; missing episodes named; best version first; play as one playlist |
| Shelves and categories | Per kind, with artists for music and covers for books and games |
| Review | New episodes, missing episodes and releases that could be better — reported, never acted on |
| Watchlist | Movies and series, with release dates and a notice when something lands |
| Item actions | Copy magnet or hash, reinsert, move or copy to another service, refresh, change kind, delete — one item or a selection |
| Total size | Item count and summed size over whatever the filters leave |

### Playing, reading, listening

| Capability | Covers |
|---|---|
| External players | Infuse, VLC, Outplayer, SenPlayer, nPlayer, VidHub, Kodi and a custom URL template; playlists where the player supports them |
| Audiobooks | Dove's own player: chapters, speed, sleep timer, lock screen, AirPlay, positions synced across devices |
| Music | Queue across albums, shuffle, track names from files, lock-screen metadata |
| Books | Apple Books, Send to Kindle, Send-to-PocketBook, or any e-mail address |

### Plugins

On-device JavaScript in a sandbox, network only through `fetch` and only to declared hosts, pinned by
SHA-256, consent per plugin. API v1 covers search, metadata, resolve, links and browse. Twenty plugins
exist in two repositories: `lakafior/dove-plugins` (metadata sources and public-domain libraries, the one
the app may link to) and `lakafior/dove-plugins-extra` (everything else, never linked from the app).

### Platform integration

| iOS | macOS |
|---|---|
| Widgets, Control Center controls, Live Activity, notifications, background refresh, Spotlight, App Intents, Shortcuts, Siri suggestions, Quick Actions | Native app (not Catalyst), phases 0–5 of [macos.md](macos.md): sidebar, source tables, Settings window, menu bar extra, Dock progress, drops, Services menu, Spotlight, App Intents, Finder location, desktop widgets |

The Finder location and the desktop widgets were checked on the owner's Mac on 2026-10-27, installed
from the notarized DMG — so with the App Group and the keychain group working as they will in release.

### Release machinery

`scripts/build-mac.sh` archives and exports a Developer ID build, `scripts/notarize.sh` and
`scripts/make-dmg.sh` notarize and package it, `.github/workflows/release.yml` does all of it on a tag
(or by hand, returning the DMG as an artefact without publishing). Proven end to end on 2026-10-27:
a notarized, stapled DMG that Gatekeeper accepts.

---

## 2. Left before the first public release

In order. "Owner" is work only Marcin can do (certificates, hardware, policy calls).

| # | Item | Who | Waits for |
|---|---|---|---|
| 1 | **Onboarding wizard**: the user ticks what they use and own, it fills the settings that already exist and adds none. Built 2026-10-27 (shows on an empty install, Settings › Set up Dove again); not yet walked through in the Simulator or on the Mac | Claude, then owner checks | nothing |
| 2 | **Split `dove-plugins`**: split locally 2026-10-27 (11 neutral plugins in a new history-free `dove-plugins`, 9 in `dove-plugins-extra`). Left: the first push of the new repository and Pages for both | owner pushes | nothing |
| 3 | **Store metadata and texts**: drafted 2026-10-27 — [privacy.md](privacy.md), [support.md](support.md), [review-notes.md](review-notes.md) (placeholders: test account, contact e-mail), `PrivacyInfo.xcprivacy` per target (checked in both builds), README section for the Mac. Left: the owner's read-through and a public URL for the two pages | owner reviews | nothing |
| 4 | **Version scheme**: decide whether the first release is `0.1.0` or `1.0.0`; build number already comes from the commit count | owner | 1–3 |
| 5 | **Release from CI**: the workflow has never run; a manual run proves it without publishing | Claude | the workflow pushed to the default branch, which `workflow_dispatch` needs |
| 6 | **Update check** against the GitHub Releases API, user confirms | Claude | a first release to check against |
| 7 | **iOS leg of CI**: read up 2026-10-27 — not `notarytool`: the build is uploaded to App Store Connect, the version's review type set to Notarization and submitted; on approval Apple generates the alternative distribution package (manifest, signature, IPA variants), which is downloaded through the App Store Connect API and hosted unchanged, plus an AltStore `source.json`. CI can do upload and the package download; the first submission is by hand | Claude | the Alternative Terms Addendum and the AltStore PAL marketplace token in App Store Connect (owner) |
| 8 | **Hardware pass** over the list below, on the release candidate | owner | 1–7 |
| 9 | **AltStore PAL listing**: screenshots, age rating, support URL, the terms side of distributing in the EU | owner | 8 |

### Built but never seen working on real hardware

Not code gaps — unverified ones. Quality on PAL is the whole point of the release, so these get a pass
before 1.0.

| Platform | Items |
|---|---|
| iOS | Obfuscated names; many-file releases in Downloads; game filing in iCloud; matching a real game release in the Library; Control Center controls; Shortcuts; the players SenPlayer, nPlayer, VidHub and Kodi; sending a book to PocketBook or by e-mail; adding from a plugin to Calibre; the FitGirl plugin inside the app |
| macOS | Services › Add to Dove; Spotlight results; the intents in Shortcuts and Spotlight; the Watchlist table with entries; an upgrade over a real weak release; a download into a picked folder; Dock progress and the download banner with a large file |

---

## 3. Left, not blocking

| Item | Note |
|---|---|
| More debrid services | EasyDebrid, Put.io, PikPak, Seedr — judged against what AIOStreams supports |
| `.dlc` containers | Only Premiumize opens them; on the list, not planned |
| Audiobookshelf as a place | Send audiobooks there, "In Audiobookshelf" on book screens. The owner does not use it, so it waits for demand |
| Ratings and anime numbering | OMDb would add IMDb and Rotten Tomatoes scores, TVDB anime episode numbering. Idea, not planned |
| CarPlay for audiobooks | Needs an entitlement granted on request; worth asking once signing is settled |
| Game items | Nothing planned; real game releases in the Library and iCloud filing not seen on a device yet |

---

## 4. Decided against

Kept here so the same ideas do not come back.

| Idea | Why not |
|---|---|
| Subtitles (`.srt`) | Infuse finds them itself, for streams and files alike |
| A built-in video player | Infuse is better at it; Dove's own player exists only for audiobooks and music, where nothing else keeps your place |
| Recommendations from the library | Built and removed: the library alone does not know what was watched or liked, and it covered video only |
| Camera text scan | Built and removed: OCR picked random lines. Image understanding would be a different feature |
| Third-party Real-Debrid cache hints | Unofficial or self-hosted, uncertain answers; Dove must not depend on the owner's VPS |
| Real-Debrid transcoding | Playback format is the player's job, and ranking already avoids what Apple TV struggles with |
| Trakt scrobbling, IPTV, YouTube, a server-side VFS | Other apps' jobs |
| OAuth device-code login | API keys are enough |
| Watched folders that add on their own | Dove never acts on its own |
| Automatic "try the next NZB" | The user decides what gets downloaded |
| InfiniDysk's own indexer search | Indexers stay on the device, away from the server's IP |
| Calibre for audiobooks | Its one-file-per-format model does not fit many-file audiobooks |
| Deezer as a built-in source | Its terms forbid it; possible as a user's own plugin |
| Scraper sites needing bot-detection evasion | jumo-dl, DoubleDouble and others fake human interaction signals; out of bounds |
| Biblioteka Narodowa | No covers, no free-text search, one record per edition |
| Server-side anything of Dove's | The user's own servers are fine, Dove's are not |
