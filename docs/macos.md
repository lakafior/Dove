# Dove for macOS: review and architecture plan

Status (2026-10-22): phase 0 done; the Mac app itself is not started.

Goal (owner): a native Mac app that uses what a computer does better, not the iPad app on a Mac and not
Catalyst. No hurry: the Mac app comes before the release pipeline (#6), which then builds both platforms.

## 1. What `App/` looks like today

94 Swift files, about 17,800 lines. DoveKit already builds and tests on macOS (`platforms: [.iOS(.v17), .macOS(.v14)]`).

| Layer | Files | Portable to macOS? |
|---|---|---|
| `AppModel` (1,160 lines) | 1 | **Almost.** No UIKit. Imports SwiftUI only for `NavigationPath` (`searchPath`); holds iOS navigation state (`selectedTab`, `searchPath`, `Destination`); downloads go to `.documentsDirectory`. |
| Feature models (`LibraryModel`, `LibraryReviewModel`, `WatchlistModel`, `PluginsModel`, `HomeModel`, `ServiceStatusModel`, `SpeedTestModel`) | 7 | **Yes**: DoveKit + Foundation + Observation only. |
| `PlaybackModel` | 1 | No: `UIApplication.canOpenURL`/`open`. One small seam. |
| `AudiobookPlayer` | 1 | Mostly: `AVAudioSession` (iOS only), `UIImage` for lock-screen artwork. `AVPlayer` and `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` exist on macOS. |
| Views (`Features/…`) | ~65 | Partly. 37 files use `navigationBarTitleDisplayMode`, 13 use `textInputAutocapitalization`/`keyboardType`, 6 use top-bar toolbar placements, 3 use `EditMode`. Leaf components (rows, covers, cards, badges) port with small `#if`s; screen containers should not be shared (see §4). |
| iOS-only integrations | ~15 | `DoveApp`/`AppDelegate`/`SceneDelegate` (UIKit lifecycle), `BackgroundRefresh` (BGTaskScheduler), `DownloadAlerts` Live Activity (ActivityKit), Quick Actions, `MFMailComposeViewController`, `UIActivityViewController`, `UIPasteboard` (6 files), `WKWebView` in `UIViewRepresentable`, `FilesLocation` (File Provider domain). |
| Extensions | `DoveShare`, `DoveFiles`, `DoveWidgets` | Share: UIKit view controller, rewrite. Files: `NSFileProviderReplicatedExtension` exists on macOS, the logic is in DoveKit; reusable later. Widgets: WidgetKit runs on macOS; Live Activity does not. |

Conclusion: the logic boundary is already good (DoveKit). The work is a **thin shared app layer** between DoveKit and
the views, and **platform seams** for about a dozen system services.

## 2. Target architecture

```
Packages/DoveKit
├─ DoveKit        (unchanged: all logic, UI-free, tested)
└─ DoveAppCore    (new library target: AppModel + feature models, Observation, AVFoundation; no UIKit/AppKit)
App/
├─ Components/    (SwiftUI leaf views shared by both apps: covers, rows, badges, status lights, settings forms)
├─ iOS/           (today's App/Dove: TabView shell, iOS screens, AppDelegate, Live Activity, Quick Actions…)
├─ Mac/           (new: NavigationSplitView shell, Tables, Commands, MenuBarExtra, Settings scene)
├─ Shared/, Activity/, DoveShare/, DoveFiles/, DoveWidgets/   (as today)
```

Why a package target for the models instead of a shared folder:

- The compiler enforces the rule: `DoveAppCore` builds for macOS with `swift build`, so a stray `UIApplication` fails at once.
- The models become testable with `swift test`, like DoveKit (today `LibraryModel`, `AppModel.getFile`, places… have no tests).
- Both app targets just depend on it; `project.yml` stays simple.

### Platform seams

One protocol the shell injects into `AppModel` at launch (`AppModel(platform:)`), each method small:

| Seam | iOS | macOS |
|---|---|---|
| `open(_ url:)`, `canOpen(_ url:)` | `UIApplication` | `NSWorkspace` (+ `urlForApplication(toOpen:)` to detect players) |
| Clipboard read/write | `UIPasteboard` (never read on appear) | `NSPasteboard` |
| Download directory | Documents | a folder the user picks (security-scoped bookmark), default `~/Downloads/Dove` |
| Audio session | `AVAudioSession` | none |
| Artwork image | `UIImage` | `NSImage` |
| Mail draft (Send to Kindle…) | `MFMailComposeViewController` | `NSSharingService(named: .composeEmail)` |
| Share a file | `UIActivityViewController` | `NSSharingServicePicker` / `ShareLink` |
| Background refresh | `BGTaskScheduler` | not needed: the app keeps running (menu bar); same refresh on a timer while open |
| Download progress outside the app | Live Activity | Dock tile progress + badge, `MenuBarExtra` |
| Notifications | `UNUserNotificationCenter` | same API |
| Spotlight, App Intents | same | same (macOS Spotlight runs App Intents) |

Navigation state leaves `AppModel`: `selectedTab`/`searchPath` become an iOS `Router`; the Mac has its own
(sidebar selection, open windows). `AppModel.show(_:)`/`open(_:)` keep producing a `Destination`; each shell routes it.

### Keychain and sync (important)

- On macOS, items with an access group must live in the **data protection keychain**: add
  `kSecUseDataProtectionKeychain: true` to every query in `KeychainStore` on macOS. The current fallback for unsigned
  builds (drop the group, then drop `synchronizable`) would otherwise land in the legacy file keychain.
- With the same team and the same group string (`5TA8RF548P.net.smigi.dove.shared`), iCloud Keychain delivers the
  iPhone's keys, addons, indexers, orders and `SyncedPreferences` to the Mac. **The Mac app starts configured.**
  This is the first thing to verify on a real Mac (phase 1).
- Device-local stores (library cache, matches, kinds, downloads) stay per device, as on iOS.

### Signing and sandbox

| Decision | Proposal | Why |
|---|---|---|
| Distribution | Developer ID + notarization, DMG on GitHub Releases | worldwide, automated review only |
| Bundle ID | `net.smigi.dove` (one App ID for both platforms) | same iCloud container, same capabilities |
| App Sandbox | **on** | good hygiene, keeps the Mac App Store open, forces explicit folder access (bookmarks, also useful for the iOS "Folder" place) |
| Entitlements | network client, user-selected read/write, downloads folder, keychain group, app group, iCloud Documents, MusicKit service | as iOS, plus sandbox ones |
| App Group | `group.net.smigi.dove` with the provisioning profile (macOS 15+), else `5TA8RF548P.net.smigi.dove` | to verify when the File Provider/widgets come |
| Updates | own check against GitHub Releases API, user confirms | no Sparkle (no third-party deps); no server of Dove's |
| Minimum | macOS 15 | `Inspector`, `Table` improvements, window APIs; Foundation Models gated on 26 as on iOS |

## 3. What the Mac app should do better

| Area | Mac design |
|---|---|
| Window | `NavigationSplitView`: sidebar (Search; Library › All, Movies, Series, Books, Audiobooks, Music, Games, Files; Downloads; On services; Watchlist; Services with status lights), content, detail/`Inspector` |
| Sources | a real `Table`: resolution, HDR, codec, audio, size, seeders, age, found by, ⚡ per service; click a header to sort; filters in an inspector, not a sheet; multi-select; Return = add (Automatic), context menu = add only to… |
| Library › Files | `Table` with name, service, kind, size, status, added; multi-select Move/Reinsert/Delete through menu commands |
| Library › Titles | adjustable grid (⌘+/⌘−), titles open in the detail column or in a new window |
| Downloads | `Table` with progress; Reveal in Finder; drag a finished file out to Finder or another app; Dock progress |
| Where files go | any folder per kind (NAS share, external disk): the Mac is where 40 GB remuxes can go to a Plex/Jellyfin folder. Naming per `LibraryFolderLayout` |
| Input | drop `.torrent`/`.nzb`/magnet text on the window or Dock icon; ⌘O; File › Add from Clipboard (⇧⌘V); Services menu "Add to Dove" for selected text; "Make Dove the default app for magnet links" (`NSWorkspace.setDefaultApplication`, user confirms) |
| Menus and keys | Commands: File (Add…, Open…), Library (Refresh ⌘R, Titles/Files), Go (⌘1…⌘5), Playback (Play in…) |
| Menu bar | `MenuBarExtra`: downloads in progress, download-only jobs, now playing, Add from Clipboard; optional "keep running after the last window closes" |
| Players | Infuse (Mac), IINA, VLC, custom template; `ExternalPlayer` gets a per-platform list |
| Audiobooks, music | same `AudiobookPlayer`; Now Playing and media keys work through `MPRemoteCommandCenter` |
| Settings | `Settings` scene with tabs (Services, Libraries, Search, Titles and covers, Playing and reading, App), reusing the iOS settings forms (`Form` + `.formStyle(.grouped)`) |
| Finder | later: the File Provider location in Finder's sidebar (DoveKit's `LibraryBrowser` is ready) |

Out, per "What belongs in Dove": watched folders that add `.torrent`s on their own (acts on its own), a built-in video
player, managing Plex/Jellyfin/Calibre content.

## 4. What is shared and what is not

| Kind of code | Shared? |
|---|---|
| Models (`DoveAppCore`) | always |
| Leaf views: `CachedImage`, covers (`GameCover`, book covers), `BackendBadge`, `StatusLight`, `SourceOriginLine`, `SeedingRatio`, rows, cards | yes, `#if os` for details |
| Settings forms (each service page) | yes, inside different containers |
| Detail screens (title, series, book, album, game, item) | the sections yes, the layout no: Mac uses wider two-column layouts and the inspector |
| Containers: tab bar vs sidebar, sheets vs inspectors, lists vs tables | **no**: written per platform |
| `LibraryView` (1,399 lines) | split first: `LibraryItemView`, `TitleCard`, `ShelfItemRow`, `LibraryStatusMark` already are separate structs; move them to `Components/` |

Rule of thumb: share what draws a thing, not what arranges things.

## 5. Phases

| # | Phase | Done when |
|---|---|---|
| 0 | ✅ (2026-10-22) **Prepare on iOS, no visible change**: create `DoveAppCore`, move `AppModel` and feature models into it, add the platform seam with the iOS implementation, move navigation state to an iOS router, make the download directory injectable, `KeychainStore` data protection flag on macOS, first model tests | iOS app behaves exactly as before (Simulator + owner's device), `swift test` covers the models |
| 1 | **Mac skeleton**: target in `project.yml`, sandbox and entitlements, sidebar shell, Settings scene with the shared forms | Mac sees the iPhone's settings through iCloud Keychain; services' status lights green |
| 2 | **Core flows**: Search → sources `Table` → add; Library (Titles grid, Files table); Downloads to chosen folders with Dock progress | add, list, download and delete work against the owner's services |
| 3 | **Detail screens and playback**: title/series/book/album/game screens, Play in Infuse/IINA/VLC, audiobook and music player | Play all and audiobook positions sync with the iPhone |
| 4 | **Mac integration**: drag and drop, ⌘O, Dock drop, magnet default handler, Services menu, MenuBarExtra, notifications, App Intents/Spotlight | each checked on the owner's Mac |
| 5 | **Finder and widgets**: File Provider location on macOS, desktop widgets | browse and download in Finder |
| 6 | **Distribution**: Developer ID, notarization, update check, then CI for both platforms (#6) | a notarized DMG from a GitHub release |

Phase 0 is the risky one (it touches every screen's environment) and gives nothing visible; it should land on its
own, checked on a device, before any Mac view is written.

Phase 0 as built: `DoveAppCore` holds `AppModel` (+ `AppModel+Actions`: continue/play audiobook, watchlist toggle,
iCloud state), the feature models, `AudiobookPlayer`, `PlaybackModel`, `DownloadAlerts` (notifications only),
`LocalNotifications`/`NotificationKind`, `DeepLink`, `SourceBatch`, `AppleMusicCatalog`, `BrowserCookieTransport`.
`AppPlatform` has fewer methods than the table in §2: clipboard, mail and sharing are used only by views, so they
stay in the iOS views until the Mac needs them. Audio session calls are `#if os(iOS)` inside `AudiobookPlayer`.
`AppModel.Destination` gained `.library(category)` and `.settings`, so the home screen and `dove://` links route
through the platform like Siri and Spotlight. Checked on the Simulator (tabs, shelf → Library category, `dove://`
links, title screens); not yet on a device.

## 6. Open questions for the owner

1. Minimum macOS: 15 (proposed) or 26?
2. App Sandbox on (proposed)?
3. Keep running in the menu bar after the last window closes: on by default, off, or ask?
4. Default download folder: `~/Downloads/Dove` or ask on first download?
5. Mac players to support first: Infuse, IINA, VLC?
6. Same bundle ID as iOS (proposed) or `net.smigi.dove.mac`?
