# Dove support

Dove sends torrents, hoster links and NZBs to your own debrid and Usenet services, then plays or downloads the result. It has no built-in content sources: you add your own API keys, Stremio addons and indexers.

## Getting started

1. **Add at least one service account.**
   You need an account with a debrid service (Real-Debrid, TorBox, Offcloud, Debrid-Link, Premiumize, AllDebrid) or a Usenet service (nzbdav/InfiniDysk, TorBox, Offcloud, Premiumize) and its API key.
   Enter it in **Settings › Services › Add service**.

2. **Add a source.**
   - Paste a magnet, a `.torrent` link, a hoster link or an NZB link in the smart field on the Search tab.
   - Share a link, a `.torrent` file or an `.nzb` file to Dove from another app.
   - Drop a `.torrent` or `.nzb` file into a service’s folder in the Files app.

## FAQ

**Why does Real-Debrid say “infringing file”?**
Real-Debrid blocks some release names (`WEB-DL`, `WEBRip`, `BluRay.x264`…) and sometimes pauses all adds on an account for 20 seconds to 5 minutes. Try another release, or wait and try again.

**Why does Real-Debrid say a torrent is not cached when I know it is?**
Real-Debrid removed its instant-availability check. You cannot know if a torrent is cached before adding it.

**Why does an NZB fail at once with “Compressed RAR archives are unsupported”?**
nzbdav and InfiniDysk stream archives without unpacking them, so only uncompressed (stored) RAR and 7z releases work. The NZB cannot tell in advance. Dove offers to send it to your next Usenet service, or to play it through that service, instead.

**Which players does Dove use?**
Infuse (recommended; it also gets episode names and playlists), VLC, Outplayer, SenPlayer, nPlayer, VidHub, and Kodi through its remote control. A custom URL template covers any other player that opens links. Pick yours in **Settings › Player**; the choice is per device.

**Why do statuses not update while Dove is closed?**
iOS limits background refresh to save battery. Dove updates statuses when you open the app and on pull-to-refresh. There are no push notifications.

**Why does the Files app say “Turn On” for Dove?**
The Files app asks once to enable the Dove location. Tap **Turn On** in the banner.

**Why does Calibre say “read-only”?**
Calibre’s Content server needs “Require username and password” and an account with write access. Dove sends Basic authentication, so the server’s authentication type must be Basic.

**Why does AllDebrid block my new API key?**
AllDebrid may block a new API key or IP until you confirm it by e-mail. Check your inbox for a confirmation link.

**Why do my settings not sync to another device?**
Settings sync through iCloud Keychain (end-to-end encrypted). Make sure iCloud Keychain is on on both devices and both use the same Apple ID.

**Why does a hoster link fail on a service that lists the site?**
Some services (TorBox, Offcloud) accept unsupported links and fail later. Automatic skips services that do not list the site or have it down.

**Why are private-tracker torrents sent only to some services?**
Private trackers need seeding, so Dove sends them only to services that seed (Debrid-Link, TorBox on a paid plan). If one of your services already has the release cached, Dove sends it there as a bare magnet, so your passkey never leaves the device.

**Why can’t Dove add the plugin repository?**
DNS filters such as NextDNS, AdGuard DNS or Pi-hole sometimes block `*.github.io`, where plugin repositories are hosted. Dove then cannot load `https://lakafior.github.io/dove-plugins/index.json`. Allow `lakafior.github.io` in your filter (or the host of any other repository you add) and try again.

## Reporting a problem

Report problems on GitHub: [github.com/lakafior/Dove/issues](https://github.com/lakafior/Dove/issues), or write to [dove@smigi.net](mailto:dove@smigi.net).

Include:
- Dove version (shown in Settings)
- Device and iOS/macOS version
- Service you used
- Steps to reproduce

Never paste API keys, addon URLs or indexer links: they contain tokens.

## Privacy

[Dove privacy policy](https://dove.smigi.net/privacy)
