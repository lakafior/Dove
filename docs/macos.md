# Dove for macOS: review and architecture plan

Status (2026-10-22): phases 0 and 1 done; phase 2 done except pasted magnets/links, Play and the filter editor (see §9).

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
| Download directory | Documents | `~/Downloads` itself (no Dove subfolder: it breaks the Downloads stack in the Dock); other folders per kind picked by the user (security-scoped bookmarks) |
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
| Bundle ID | `net.smigi.dove`, one App ID for both platforms (decided) | same iCloud container, same capabilities |
| App Sandbox | **on** (decided) | good hygiene, keeps the Mac App Store open, forces explicit folder access (bookmarks, also useful for the iOS "Folder" place) |
| Entitlements | network client, user-selected read/write, downloads folder (`com.apple.security.files.downloads.read-write`), keychain group, app group, iCloud Documents, MusicKit service | as iOS, plus sandbox ones |
| App Group | `group.net.smigi.dove` with the provisioning profile (macOS 15+), else `5TA8RF548P.net.smigi.dove` | to verify when the File Provider/widgets come |
| Updates | own check against GitHub Releases API, user confirms | no Sparkle (no third-party deps); no server of Dove's |
| Minimum | macOS 26 | Liquid Glass and Foundation Models without availability checks; no older Macs to carry |

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
| Menu bar | `MenuBarExtra`: downloads in progress, download-only jobs, now playing, Add from Clipboard; keeps running after the last window closes by default (downloads go on), can be turned off in Settings |
| Players | Infuse, IINA, VLC first (decided), plus the custom template; Kodi works as on iOS (JSON-RPC); `ExternalPlayer` gets a per-platform list |
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
| 1 | ✅ (2026-10-22) **Mac skeleton**: target in `project.yml`, sandbox and entitlements, sidebar shell, Settings scene with the shared forms | Mac sees the iPhone's settings through iCloud Keychain; services' status lights green |
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
links, title screens); checked briefly on a device by the owner (2026-10-22).

## 6. Decisions (owner, 2026-10-22)

| Question | Decision |
|---|---|
| Minimum macOS | **26** |
| App Sandbox | **on** |
| Bundle ID | **`net.smigi.dove`**, shared with iOS |
| After the last window closes | **keeps running in the menu bar** (downloads go on); a setting turns it off |
| Default download folder | **`~/Downloads`**, no Dove subfolder (it breaks the Downloads stack in the Dock) |
| Players first | **Infuse, IINA, VLC** (Kodi and the custom template come with `ExternalPlayer` anyway) |

## 7. Phase 1 as built (2026-10-22)

- `DoveMac` target in `project.yml` (macOS 26, sandbox, hardened runtime, network client, user-selected and Downloads
  folder access, the shared keychain group, iCloud Documents; same bundle ID and icon as iOS). Signed builds work
  with `-allowProvisioningUpdates` (Xcode made a macOS profile for `net.smigi.dove`).
- `MacPlatform`: `NSWorkspace` for players and links, the user's real `~/Downloads`, Now Playing artwork from
  `NSImage`; Finder, Spotlight, widgets and Dock progress hooks are empty until phases 4–5.
- `MacRouter` + `MacRootView`: sidebar with Search, Watchlist, Library (All and the kinds the library holds),
  Downloads, On services and the set-up services with status lights; a service shows its state, account and item
  count; the other pages are placeholders until phase 2. The app keeps running after its window closes; the menu bar
  extra comes in phase 4.
- Settings window: `SettingsCatalog` (shared with iOS, whose Settings list now reads it too) in a sidebar; each page
  is the iOS form with `.formStyle(.grouped)`. Shared views compile through `App/Components/PlatformShims.swift` and
  `SystemSettings`; `#if os(iOS)` only for the addon list's Edit button, the routing page's edit mode and the Files
  location reset.
- `CachedImage` works on both (`PlatformImage`).
- Checked on the owner's Mac (2026-10-22): iCloud Keychain brought every key from the iPhone; the sidebar listed
  the library's kinds and every service with a green light; the Settings window shows every page. A build run from
  `/tmp` is unknown to Launch Services: no `dove://` links and no notification permission prompt. Built into Xcode's
  DerivedData it is registered: `dove://settings` opens the Settings window through `MacRouter`. The notifications
  page now shows the error when the system refuses to ask.

## 8. Phase 2 as built so far (2026-10-22)

Split in three: Library, then Downloads, then Search → sources → add.

- **Library** (done): `MacLibraryView` for each sidebar entry (All or a kind). Titles: cover grids in the iPhone's
  order (movies, series, books, audiobooks, music by artist, games, other files) with larger tiles; Files: a `Table`
  (name with the service's own name under renamed items, service, kind, status, seeding ratio as its own column, size, added),
  sortable, several rows selected at once, Copy Name and Delete in the context menu, ⌫ deletes. Filter field in the
  toolbar, Titles/Files remembered, Refresh (⌘R), "Updated … · N items, size" as the window subtitle, load failures
  above. Deletes ask first. The cards are the iPhone's, moved to `App/Components/LibraryCards.swift`. Title, book and
  game screens are phase 3, so a card has no click action yet.
- Checked on the owner's Mac: the Titles grid with posters, the status line and the Files table. The ratio first sat
  next to the status and stayed cut to "0…" however wide the column; it is its own column now.
- **Downloads** (checked by the owner, 2026-10-22: an EPUB from Calibre and one from Offcloud landed in `~/Downloads`;
  iCloud Drive items show their files in the Finder): `MacDownloadsView`, a table of this Mac's downloads (name
  with its folder, source, progress with bytes, place, added); double-click opens the file; context menu Open, Show
  in Finder, Pause, Resume/Retry, Remove from List (the file stays: `DownloadManager.remove(_:deletingFile:)`), Move to
  Trash, Cancel Download; ⌫ removes from the list; toolbar Show Downloads Folder and Clear Finished. A release starts
  from the Library (cards and Files rows: Download): `AppModel.downloadItem` takes every file of a ready item (services
  that list no files are asked), to the kind's place from Settings › Save to (`DownloadDestination.device` is
  `~/Downloads` on the Mac and is named "Downloads" there; books, audiobooks and music default to iCloud Drive), one
  file loose, several in a folder named after the item. `MacOnServicesView`: what the services are still fetching
  and failures of the last 3 days as a table with progress, speed and time left, re-listed every 20 s while open.
  Dock icon: a badge with the running count and a bar for their bytes (`DockProgress`, redrawn per percent).
  Download notices show as banners in front too; a click opens Downloads. Download-only jobs poll from launch.
  iCloud Drive items are already on the Mac: their menu says Show in Finder instead of Download (the first try sent
  their `file://` URL to URLSession: "unsupported URL"). The sidebar's Downloads row could not be selected while its
  `.badge` came after `.tag`; the tag goes last.
  Per-kind folders outside `~/Downloads` (a NAS share) still to do: they need a folder picker and security-scoped
  bookmarks.

- **Search, Movies & TV** (built 2026-10-22; title page and sources table seen on the owner's Mac with Interstellar,
  adding not tried yet): `MacSearchView` (TMDB/addon results as posters, title links
  open the title; `MacRouter.searchPath`, so `dove://media…`, Spotlight and Siri land there too), `MacTitleView`
  (header; a movie lists its releases, a series has seasons, episodes and whole-season/whole-series packs on the left
  and the picked one's releases on the right), `MacSourcesTable` (Recommended order from the saved filter, sortable
  columns: release, resolution, video, audio, size, seeders, age, cached on, found by; Return or double-click adds
  (Automatic), context menu Add Only To… with ⚡ for cached services, Copy Name; Download only toggle in the toolbar;
  sources that did not answer behind a link with a popover). Loading and adding moved from the iPhone's
  `SourcesView` into `DoveAppCore` (`AppModel.sources(for:)`, `checkingCache`, `add(_:for:only:)`, `SourceQuery`),
  so both apps use one code path. Layout (owner's call, 2026-10-22, after a toolbar field with a segmented
  All/Movies/Series, then a sidebar field, both judged weak): Search is the start page and Dove's showpiece. A large
  Spotlight-style field (`SpotlightField`, Liquid Glass, the category as a menu inside it, `macSearchCategory`) on a
  soft accent glow; under it, before a search, `MacHomeSections`: service capsules (light, days left; click = the
  service), In progress (Mac downloads and service items with bars), Recently added (posters; a matched title opens
  with its sources), Your library (a card per kind with fanned covers; click = that Library category), Recent searches
  (chips; `HomeModel`, this Mac only). After a search the results replace the sections (All/Movies/Series above
  them, Home or Esc goes back). ⌘F (Edit › Search…) focuses that field on the Search page and opens the same field
  floating over any other page (`QuickSearchPanel`; Return searches; Esc clears the words, then closes; a click
  outside closes). Polish (owner: "all of them", 2026-10-22): suggestions while typing in every category with
  metadata (`SearchSuggestions`: what the library holds in that category first, then up to six from its services
  after a pause (300 ms, 500 ms for MusicBrainz): TMDB/addons, `library.searchBooks`, `musicMetadata`,
  `gameMetadata`; then "Search for …"; Software/Adult/All only the search line; ↑↓ and Return, `MacRouter.open(_:)`;
  a book, album or game from the services searches its name until its releases screen exists); the backdrop is the newest title's, blurred under the field
  (`HeroBackdrop`), and follows the poster the pointer rests on in the poster rows (its backdrop, else its cover;
  150 ms wait so a sweep does not fade through every cover, 0.4 s cross-fade, the last one stays); Recently added mixes every kind (titles, books, albums, games); New episodes and Watchlist rows;
  service capsules say only what needs attention (offline/free/expired red, under 30 days orange); cards rise under
  the pointer (`hoverLift`, still with Reduce Motion) and offer Download; Edit › Search In › a category (⌘1…⌘7). Then
  (owner): covers in a mixed row share one height (square and box covers are wider) so names line up; the sidebar
  starts hidden; anything the library holds opens through one method, `MacRouter.openLibrary(_:)`, from the start
  page, the Library's cards and suggestions alike (until phase 3's screens: the Library at its kind); only titles
  not held (watchlist, search results) open with their sources. The start page follows the window's width (`HomeLayout`): content up to
  1800 pt, posters, field and shelf cards up to 1.5× on a large window; recent searches have Clear and sit left.
  Text grows with them: cards and the start page use `scaledFont` (`App/Components/ScaledFont.swift`, an
  environment `textScale`; at 1, the iPhone and every other page, it is exactly the plain text style). `dove://search?q=`
  opens a search (both apps). The main window is a `WindowGroup` without File › New Window (a Dock click brings it
  back; `Window` did not). `LibraryShelfSummary` moved to `App/Components`. Not on the Mac yet: Play, the filter editor (the saved filter applies), plugins'
  results, the described filter, upgrades.

- **Search, every category** (2026-10-22): `ReleaseList` and `PluginSearch` moved from the iPhone's views into
  `DoveAppCore` (both apps use them). Books, Audiobooks, Music, Games: the category's metadata services answer with
  covers (`CoverResult`), a click (or a suggestion) opens `MacReleasesView` (`ReleaseTarget`: header with cover and
  description; the iPhone's queries: `t=book`/`t=music` where indexers know them, the game's title; this item's
  releases first, "Show N other results"; `MacReleasesTable`: format column (book formats, music formats, game
  platform), size, seeders, age, found by; Return/double-click adds through `ReleaseList.add`, which records the hint
  and the kind; a Plugins tab when plugins answer, Get to the kind's place). "Search releases for …" and categories
  without metadata (Software, Adult, All), or nothing found, show the indexers by name as a table with the plugins
  under it. Music covers seen on the owner's Mac ("green day dookie"); the releases page not opened yet.

- **Library screens at the iPhone's options** (2026-10-23, owner: the first item screens lost the iPhone's actions
  and the season list could not open downwards). Library page: Filters (services, status; the kind is the sidebar's),
  ⋯ (Shuffle All for music, Re-match All Titles, Show Adult Content); cards, rows and selections share
  `MacLibraryActions` (Download / Show in Finder, Copy Magnet Links, Refresh Status, Reinsert, Move To › Move/Copy,
  Change Type, Delete; titles add Watchlist). Release screen (`MacItemView`): each release row has a visible ⋯ with
  its menu (plus Choose Files… for Real-Debrid's `awaitingFileSelection` through `FileSelectionView`, Send to the next
  Usenet service after a compressed-archive failure), files Play / Play in… / Download / Save to iCloud Drive / Copy
  Link; toolbar Watchlist and ⋯ (Find Other Releases for books, albums, games; Wrong Title/Book/Album/Game? through
  the shared pickers in `App/Components/MatchPickers.swift`; Refresh; Delete All). Series: the list mode is one
  `MacEpisodeTable` (seasons → episodes → versions, Play / Play in… / Play from Here / Version / Copy Link /
  Download / Find; the season page uses the same table), the iPhone's review sections as `MacReviewSection`
  (new/missing episodes with Hide These, Could be better with Keep What I Have, Find), toolbar Wrong Title?,
  Show Hidden Suggestions. Books: `MacBookActions` (Read opens the file in its reader, Send to Kindle/PocketBook/
  e-mail through the system's compose service, Show in Finder, Add to Calibre; audiobooks Play/Continue/Start Over).
  Dove's audio player has a bar at the bottom of the window (`MacNowPlayingBar`: ±15/30 s or previous/next, scrubber,
  chapters, speed, sleep timer, shuffle and queue); music started without any controls before. Moved to
  `App/Components` for both apps: `MatchPickers`, `FileSelectionView`, `SearchRows`, `WatchlistControls`. Built and
  tested; not looked at in the running app yet.

- **Library pages after a test pass in the running app** (2026-10-23; the owner gave the test tools Accessibility, so
  pages are clicked and screenshotted before they are handed over). One header for every page (`MacPageHeader`:
  backdrop or blurred cover, artwork, facts, badges, one row of buttons, description with More; text on a darkened
  band). Buttons: Play (prominent) / Shuffle / Download / ⋯ (`MacItemsButtons`, same height). Albums and series show
  their releases as a tab (`PageTabPicker`: Tracks or Seasons | N Releases, one remembered choice), not a sheet: the
  sheet was too narrow and cut off the release rows' ⋯. `MacHeldReleases` is the releases table on its own (item
  pages, both tabs). Library page as in the Finder: the Icons/List switch is the first item of the trailing toolbar
  group, then Filters, Share (the selection's magnet links, else names) and Action (⋯: the selection's menu, then
  Shuffle All, Re-match, Show Adult); icons are selectable (click, ⌘-click, ⇧-click range, double-click or Return
  opens, Delete deletes, Esc or a click between icons clears), one selection with the list; a right-click on a
  selected icon acts on the whole selection. Album and artist menus have Play and Shuffle; season cards a menu.
  Item, series and album pages have one ⋯, in the header (as Music and TV): the page's own items first (Wrong
  Title/Book/Album/Game?, Find Other Releases, Show Hidden Suggestions), then the releases' actions; their toolbar
  keeps only the view switch and the Watchlist bookmark (Apple's pattern: the toolbar acts on a list's selection, a
  page about one thing has its buttons beside it).

- **Adding from outside, and Play from sources** (2026-10-23, built, not run yet): `MacSourceIntake` (`MacAddSources.swift`)
  turns a magnet, link, info hash, `.torrent` or `.nzb` into `AppModel.openedSource`, which `MacRootView` shows as the
  iPhone's `AddSourceView` (shared file, now in the Mac target) in `MacAddSourceSheet`. Entry points: dropping files,
  links or text on the window, File › Open… (⌘O), File › Add from Clipboard (⇧⌘V; Finder-copied files first), the
  Search field (a magnet there opens the sheet), `magnet:` links and `.torrent`/`.nzb` documents (Dock drop, Open With;
  `CFBundleURLTypes`/`CFBundleDocumentTypes`). `MacRouter.notice` is the window alert for results and refusals. Play in
  the sources table: toolbar button, context menu Play / Play in… (addon link, or an NZB through Dove's nzbdav job as
  on the iPhone; a compressed archive points to Add Only To instead of the iPhone's one-tap fallback).

## 9. Where to pick up (2026-10-22)

1. **Phase 2c, the rest of Search**: Books, Audiobooks, Music, Games (metadata first, then the indexers:
   `BookReleasesView`, `AlbumReleasesView`, `GameReleasesView`, `ReleaseList` on iOS), Software/Adult/All (indexers by
   name), plugins' results, pasted magnets and links (`AddSourceView`), the source filter editor, Play from a release.
2. Per-kind download folders outside `~/Downloads` (NAS): folder picker + security-scoped bookmarks, shown in
   Settings › Save to on the Mac.
3. Phase 3 left: the described filter and upgrades in the source list, audiobook queue niceties (the player bar
   covers the iPhone's controls but has no AirPlay picker).
4. Not yet checked: the Dock progress bar and the download notice banner with a big file.
