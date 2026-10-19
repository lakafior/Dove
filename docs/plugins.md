# Dove plugins — API v1

Plugins let Dove find books, metadata and files on sites without an official API, **on the phone**: no
server to run. Dove ships no plugins and knows no site; the user adds a plugin repository by URL, like a Stremio
addon or an indexer. This document is the contract between Dove (the host, `DoveKit/Plugins`) and plugin
authors (for example the `dove-plugins` repository).

Status: draft, API version `1`.

## What a plugin can do

| Capability | Dove calls | Used for |
|---|---|---|
| `metadata` | `metadata({query, format}, ctx)` | covers, titles and authors for Books and Audiobooks (like Open Library or Apple Books) |
| `search` | `search({query, category, book}, ctx)` | rows under a search category's results, each one downloadable |
| `resolve` | `resolve({id}, ctx)` | turns a search row or a file page into a file link Dove downloads or hands to a service |
| `browse` (manifest only) | — | "Search on <site>" opens the site's own search page in Dove's browser |
| `links` (manifest only) | — | a file page (opened in the browser, pasted, shared) is recognised and `resolve`d |

A plugin declares the ones it has. It never chooses where a file goes: Dove does (This iPhone, iCloud Drive, a
service that fetches links), from the user's settings.

## Repository

A repository is one JSON file at a URL the user adds in Settings:

```json
{
  "format": "dove-plugins",
  "version": 1,
  "name": "Marcin's plugins",
  "plugins": [
    {
      "id": "pl.books.metadata",
      "name": "Polskie metadane książek",
      "version": "1.0.0",
      "summary": "lubimyczytac, Audioteka, Storytel, Audible",
      "script": "plugins/pl-books-metadata.js",
      "sha256": "9f2c…",
      "api": 1,
      "adult": false
    }
  ]
}
```

- `script` is relative to the index URL (or absolute https).
- `sha256` is the hex SHA-256 of the script file. Dove refuses a script that does not match, and runs only what
  it installed: a changed file needs a new index entry.
- `api` is the plugin API version the script was written for; Dove skips versions it does not support.
- `adult: true` plugins are hidden unless the user shows adult content.
- Dove checks the index when the app starts (at most once a day) and offers updates; it installs only on a tap.

## Script

One JavaScript file (bundle libraries such as an HTML parser into it). It runs in JavaScriptCore: no DOM, no
`window`, no `localStorage`, no timers except `dove.sleep`. It defines one global:

```js
globalThis.plugin = {
  manifest: { /* see below */ },
  async metadata({ query, format }, ctx) { return [/* Book */] },
  async search({ query, category, book }, ctx) { return [/* Result */] },
  async resolve({ id }, ctx) { return { url, headers, fileName, size } },
}
```

Every function may be `async`; return plain JSON values (objects, arrays, strings, numbers, booleans, null).
Throw an `Error` with a readable message to fail; Dove shows `message` to the user.

### Manifest

```js
manifest: {
  id: "pl.books.metadata",          // same as the index entry
  name: "Polskie metadane książek",
  version: "1.0.0",
  api: 1,
  capabilities: ["metadata", "search", "resolve"],
  categories: ["books", "audiobooks"],   // search categories it serves: media, books, audiobooks, music, software, adult, all
  hosts: ["lubimyczytac.pl", "*.storytel.com", "{domain}"],
  settings: [
    { key: "domain", title: "Address", type: "text", required: true, help: "The site's current domain" },
    { key: "key", title: "Secret key", type: "secret", required: true },
    { key: "fallback", title: "Use Audible", type: "toggle", default: true }
  ],
  browse: "https://{domain}/search?q={query}",
  links: ["^https://{domain}/md5/(?<id>[0-9a-fA-F]{32})"],
  adult: false
}
```

- `{name}` placeholders are setting keys (a letter first, then letters, digits, `_`); anything else in braces,
  such as `{32}` in a regular expression, stays as written.
- `hosts`: the only hosts `dove.fetch` may reach. `*.example.com` covers subdomains (not `example.com`
  itself; list both). `{name}` takes the value of a setting, so a site that moves is followed by the setting.
  Dove shows the list when the plugin is installed.
- `settings`: fields the user fills in Settings › Plugins › <plugin>. `secret` values live in the Keychain,
  every value reaches only this plugin (in `ctx.settings`). Types: `text`, `secret`, `toggle`.
- `browse`: optional URL template; `{query}` is the search words (URL-encoded), other `{name}`s are settings.
- `links`: optional regular expressions (JavaScript syntax, `{name}`s replaced with escaped setting values) over
  a full URL; the named group `id` is passed to `resolve`.

### Context (`ctx`)

```js
{ settings: { domain: "…", key: "…" }, locale: "pl-PL", region: "PL", apiVersion: 1 }
```

### Values

`Book` (from `metadata`):

```js
{ id, title, authors: ["…"], year, cover, description, link, narrators: ["…"], series, isbn, asin, language }
```

Only `id` and `title` are required. `cover` and `link` are https URLs; `description` is plain text or simple HTML.

`Result` (from `search`):

```js
{ id, title, author, kind, format, size, language, year, cover, link }
```

`kind`: `books`, `audiobooks`, `music`, `video`, `software`, `other`; `format`: a file extension (`epub`, `m4b`);
`size` in bytes. `id` is what `resolve` gets back.

`Link` (from `resolve`), or an array of them for several files:

```js
{ url, headers: { "Referer": "…" }, fileName: "Title - Author.epub", size }
```

A link with `headers` can only be downloaded by Dove (This iPhone, iCloud Drive); one without can also go to a
service that fetches plain links (Offcloud, TorBox, Premiumize).

## Host API (`dove`)

| Function | Does |
|---|---|
| `await dove.fetch(url, { method, headers, body })` | HTTPS request to an allowed host. Resolves to `{ status, url, headers, body, text(), json() }` (`body` is the text, UTF-8). Rejects for a host outside `hosts`, a redirect to one, a network error, or more than 10 MB. Does not reject for HTTP errors: check `status`. No cookies are kept between calls. |
| `await dove.sleep(ms)` | Waits up to 5000 ms (rate limits). |
| `dove.log(...values)` | Debug output (Dove's log; never shown to the user). |

## Limits

- A call (`metadata`, `search`, `resolve`) has 30 seconds; Dove abandons it after that.
- A script is at most 2 MB; a response at most 10 MB.
- Each call runs in a new, empty JavaScript context: nothing survives between calls.
- No access to files, the Keychain, other plugins, or Dove's data; nothing but `dove.fetch` reaches the network.

## Example: resolve-only plugin

```js
globalThis.plugin = {
  manifest: {
    id: "example.fast-download", name: "Fast download", version: "1.0.0", api: 1,
    capabilities: ["resolve"], categories: ["books"],
    hosts: ["{domain}"],
    settings: [
      { key: "domain", title: "Address", type: "text", required: true },
      { key: "key", title: "Secret key", type: "secret", required: true }
    ],
    browse: "https://{domain}/search?q={query}",
    links: ["^https://{domain}/md5/(?<id>[0-9a-fA-F]{32})"]
  },
  async resolve({ id }, ctx) {
    const { domain, key } = ctx.settings
    const response = await dove.fetch(`https://${domain}/dyn/api/fast_download.json?md5=${id}&key=${encodeURIComponent(key)}`)
    const answer = response.json()
    if (!answer.download_url) throw new Error(answer.error || "No download link")
    const name = decodeURIComponent(new URL(answer.download_url).pathname.split("/").pop() || id)
    return { url: answer.download_url, fileName: name }
  }
}
```

## For App Review (guideline 4.7)

Plugins are JavaScript run in JavaScriptCore, in a fresh context per call, without native APIs: the only bridge
is `dove.fetch`, limited to the hosts the plugin declares and the user sees at install. Settings reach only
their plugin and are entered by the user. Scripts are pinned by SHA-256 and installed or updated only by the
user. Adult plugins are hidden behind the app's adult-content switch. Dove ships no plugin and no repository
address.
