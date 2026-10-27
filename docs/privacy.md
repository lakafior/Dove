# Privacy policy

**Effective date: 2026-10-27**

Dove is an iOS and macOS app that helps you manage files from your own services. The developer does not run any servers for Dove and does not receive any of your data.

## Data Dove does not collect

- No accounts or sign-ups
- No analytics or tracking
- No crash reporting of its own (if you opt in to sharing analytics with developers in your device's settings, Apple may pass on crash logs; they contain no account data)
- No ads

## Data you bring to Dove

Dove connects to services you already use. Their own privacy policies apply to what they do with your data:

- **Debrid services** (Real-Debrid, TorBox, Offcloud, Debrid-Link, Premiumize, AllDebrid): Dove sends magnets, torrent files, hoster links and NZBs to them from your device.
- **Usenet services** (nzbdav/InfiniDysk, TorBox, Offcloud, Premiumize): Dove sends NZBs to them from your device.
- **Indexers** (Newznab/Torznab): Dove searches them from your device with your API keys.
- **Stremio addons**: Dove searches them from your device.
- **Calibre**: Dove lists your books and sends new ones to your own Calibre Content server.
- **iCloud Drive**: files you send there are stored in your own iCloud account.
- **Kodi**: Dove sends play commands to your Kodi server.
- **Plugins**: Dove runs JavaScript you install, which may connect to sites the plugin declares.

## Metadata lookups

Dove looks up titles through public services:

- TMDB (The Movie Database)
- Open Library
- Apple's iTunes Search / Apple Books
- Google Books
- Hardcover
- MusicBrainz
- Apple Music
- IGDB
- Wikidata

The only data sent is the title being looked up.

## On-device processing

- Natural-language filters and "find by description" use Apple's Foundation Models on your device.
- Secrets (API keys, passwords) live in your device's Keychain.
- Settings sync to your other devices through iCloud Keychain (end-to-end encrypted).
- Some data stays on one device only: library matches, content kinds, downloads.

## Downloaded files

- Files you download stay on your device.
- They are excluded from iCloud backup.

## Sending files

- Sending a book by e-mail or to Kindle goes through your system mail or the service you pick.

## Plugins

- Plugins are JavaScript you install from repositories you add.
- Each plugin declares which hosts it connects to.
- You must enable each plugin before it runs.
- What a plugin sends to the hosts it declares is governed by those hosts' privacy policies.

## Children

Dove is not directed at children under 13.

## Contact

Questions or concerns? Write to [dove@smigi.net](mailto:dove@smigi.net) or open an issue on GitHub: <https://github.com/lakafior/Dove/issues>
