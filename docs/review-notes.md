# Notes for notarization review

## What Dove is
Dove is an iOS client (with a separate, notarized macOS app outside this submission) for the user’s own debrid services, Usenet servers, and media servers. It sends sources the user already has (magnet links, hoster links, NZB files) to those services and hands playback to external players (Infuse, VLC, etc.) or downloads the file to the device.

## No built-in content
Dove ships no indexers, addons, catalogues, or plugins. Every source is configured by the user with their own API keys, Stremio addons, or indexer URLs. Out of the box, Dove can look up metadata for books and music (Open Library, Apple Books, MusicBrainz); movies and TV need the user's own free TMDB key. It finds no downloadable sources until the user configures one.

## Plugin model (guideline 2.5.2)
Dove supports JavaScript plugins run on-device in a sandbox (JavaScriptCore, no file system access, network only via `dove.fetch` to hosts the plugin declares). Plugins are:
- Installed only from a URL the user enters.
- Pinned by SHA-256; Dove refuses scripts that do not match.
- Explicitly consented to per plugin.
- Limited to API v1: search, metadata, resolve, links, and browse (no UI or code changes).

Plugins extend data sources, not app features, analogous to Stremio addons. The sandbox rules are:
- No access to files, Keychain, or other plugins.
- Network only through `dove.fetch` to declared hosts.
- No timers except `dove.sleep` (at most 5 s, for rate limits).
- 30-second timeout per call, 2 MB script limit, 10 MB response limit.

## Privacy
- No Dove server; no tracking or analytics.
- Secrets (API keys, passwords) are stored in the Keychain.
- Data reaches only the services the user configures (and the public metadata services above), straight from the device.

## Testing without accounts
Without keys configured, the following works:
- Metadata search for books and music (Open Library, Apple Books, MusicBrainz); movies and TV with a free TMDB key.
- Settings UI (services, plugins, priorities).
- Plugin installation (no functionality without user-provided URLs).

A test debrid key can be provided on request: **[test account details here]**.

## Adult content
Hidden by default behind a setting (`showAdult` in Settings).

## Contact
dove@smigi.net · privacy policy: https://dove.smigi.net/privacy
