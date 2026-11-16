# Releasing an app on AltStore PAL

A guide for the owner's other apps, written from Dove's first release (1.0.0, 2026-11-13). It assumes an iOS app
that already has a site and an unsigned IPA on GitHub Releases, and takes it to an installable, self-updating
listing in AltStore PAL.

AltStore's own docs: <https://faq.altstore.io/developers/distribute-with-altstore-pal>, `make-a-source`, `rest-api`,
`source-discoverability`. What follows is what those pages leave out or get wrong in practice. The detailed record
is `docs/implemented.md` › "AltStore PAL" and "iOS release from CI".

## What already exists (do not redo)

| Thing | State |
|---|---|
| Apple's Alternative Terms Addendum for the EU | accepted on the developer account |
| AltStore registration and the marketplace token in App Store Connect | done once for the account (Users and Access › Integrations › Marketplace) |
| The AltStore source | one for all of the owner's apps: `https://smigi.net/altstore/source.json`, file `altstore/source.json` in `lakafior/smigi-net`, deployed on push to `main` |
| Discovery on explore.alt.store | `@smigi@alt.store` (`fediUsername` cannot change), live since 2026-11-14. Explore re-reads the source by itself: a new app or version becomes a post the same day, with no second `/federate` |

So a new app is: get it notarized, attach its package to a GitHub release, add an entry to the same source.

## Steps for a new app

| # | Step | Where | Notes |
|---|---|---|---|
| 1 | Add the app to the marketplace | App Store Connect › Users and Access › Integrations › Marketplace › AltStore PAL | The integration lists which apps it distributes. The new app must be ticked. Keep "Yes, send notifications" |
| 2 | Upload a signed build | Xcode › Archive › Distribute, Xcode Cloud, or `build-ios.sh upload` | Apple Distribution signing, like an App Store build. The app needs its record in App Store Connect first |
| 3 | Submit for notarization | App Store Connect › the app › the version › App Review › Review Type: **Notarization** › submit | Review notes help: say what the app does and that it has no built-in content. Approval took hours to a day or two |
| 4 | Find the package ID | App Store Connect API | See "Getting the package" below. The `asc` CLI (0.18.9) cannot show it |
| 5 | Get the package from AltStore | `https://api.altstore.io/adps` | AltStore's API, not Apple's |
| 6 | Attach the files to the GitHub release of that version | `gh release upload vX.Y.Z …` | Six files for Dove: `manifest.json`, `signature`, four `<uuid>.ipa`. Unchanged, byte for byte |
| 7 | Add the app to the source | `smigi-net/altstore/source.json`, a new object in `apps` | See "The source entry" below |
| 8 | Push `smigi-net`, then install from AltStore PAL on an iPhone | Sources › + › the source URL | The install is the only real check of `appPermissions` |
| 9 | Check the posts on explore.alt.store/@smigi | — | Two per new app: the app (description and the first three screenshots) and its version. A `news` item is a post as well. Edits after posting may not change them |

Later versions repeat 2–6 and add one entry at the top of the app's `versions`.

## Getting the package

The version must be `READY_FOR_DISTRIBUTION`. The package (ADP) ID comes from the App Store Connect API:

```
GET /v1/apps/{appID}/appStoreVersions?include=alternativeDistributionPackage
```

`included[]` holds an item of type `alternativeDistributionPackages`; its `id` is the ADP ID. `scripts/asc_api.py`
signs the request with the standard library only.

Then AltStore:

```bash
curl https://api.altstore.io/adps/ADP_ID
```

```bash
curl --header "Content-Type: application/json" -X POST --data '{"adpID":"ADP_ID"}' https://api.altstore.io/adps
```

- `GET` answers 404 when AltStore has never heard of the package. That happened for Dove although the marketplace
  was connected. `POST` (202) queues it; it was ready in about three minutes.
- When `status` is `success` there is a `downloadURL`: a zip, on a signed link that lasts minutes (ask again for a
  fresh one; the download itself stays available for five days).
- The zip holds `manifest.json`, `signature` and `variant/<uuid>.ipa`. The IPAs are encrypted: they cannot be
  unzipped, inspected or sideloaded. Only AltStore PAL installs them.
- From a script, send a User-Agent. Cloudflare in front of the API answers Python's default one with 403
  (`error code: 1010`).

## The source entry

A new app is one more object in `apps`. Copy Dove's and change everything. Fields that matter:

| Field | Value |
|---|---|
| `bundleIdentifier` | exactly as in Info.plist, case included |
| `marketplaceID` | the app's Apple ID (App Store Connect › App Information), as a string |
| `appPermissions.entitlements` | every entitlement of the app **and its extensions**, as strings. Leave out `application-identifier` and the team identifier |
| `appPermissions.privacy` | every `NS…UsageDescription` from Info.plist, key → text |
| `versions[0].version` / `buildVersion` | `shortVersionString` / `bundleVersion` from the package's `manifest.json` |
| `versions[0].size` | `variants[0].variantDetails.compressedSize` from the manifest |
| `versions[0].minOSVersion` | `minimumSystemVersions.ios` from the manifest |
| `versions[0].downloadURL` | the release URL of `manifest.json` |
| `versions[0].assetURLs` | one entry per package file: key = file name without extension (`manifest`, `signature`, each UUID), value = its release download URL |
| `screenshots` | objects with `imageURL`, `width`, `height`. Dove's are the site's WebP files |
| `category` | one of `developer`, `entertainment`, `games`, `lifestyle`, `other`, `photo-video`, `social`, `utilities` |

- If `appPermissions` does not match the signed app, AltStore refuses to install. The package cannot be inspected, so
  take the list from the entitlements files and `project.yml`/Info.plist, and let the test install confirm it.
- The newest version goes first in `versions`.
- Strict JSON: AltStore's examples have trailing commas, which are invalid.
- Add the bundle ID to the source's `featuredApps` if it should be featured.
- AltStore's PAL example-source link is dead; Dove's entry is the template.

## Hosting: why GitHub Releases

`assetURLs` lets every package file live at its own URL, so the files are release assets
(`https://github.com/<owner>/<repo>/releases/download/<tag>/<file>`). Free, no repository growth.

- `manifest.json` and `signature` are fixed names: one iOS version per release tag.
- Say in the release notes that the UUID-named `.ipa` files are for AltStore PAL, so nobody takes them for the
  unsigned IPA.
- Rejected: committing the package to the site's repository (about 48 MB per version, forever) and Cloudflare R2
  (needs a card on the account).

## Automating it (copy from Dove)

| File | Does | Change for another app |
|---|---|---|
| `scripts/build-ios.sh` | `unsigned` → `<App>-<version>-unsigned.ipa`; `upload` → signed build to App Store Connect | project, scheme and product names |
| `scripts/asc_api.py` | App Store Connect API client, no dependencies | `BUNDLE_ID` |
| `scripts/asc-notarize.py` | waits for the build, sets review type Notarization, submits | nothing |
| `scripts/altstore-publish.py` | steps 4–7 for a new version of an app already in the source | `REPO` |
| `.github/workflows/release.yml` › `ios` | runs the first three on a `v*` tag | names; it expects another job to create the release |
| `.github/workflows/altstore.yml` | runs `altstore-publish.py` every six hours and by hand, pushes `smigi-net` | nothing |

Repository secrets the workflows need:

| Secret | What |
|---|---|
| `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | App Store Connect API key |
| `IOS_DISTRIBUTION_P12_BASE64`, `IOS_DISTRIBUTION_P12_PASSWORD` | Apple Distribution certificate |
| `SMIGI_NET_TOKEN` | fine-grained GitHub token, Contents: Read and write on `lakafior/smigi-net` only |

State of the automation, as of 2026-11-13:

- Run for real: the unsigned build; `altstore.yml` end to end with nothing to publish; `altstore-publish.py`'s dry
  run, which rebuilt Dove's live source entry.
- Never run: the signed upload from CI, the submission through the API, and the push to `smigi-net`. Apple's docs
  confirm `reviewType: NOTARIZATION` but not that the submission goes through `reviewSubmissions`. If it fails,
  submit by hand (step 3); the rest still works.
- `altstore-publish.py` only adds versions. The app's entry in the source (step 7) is written by hand the first time.
- The version string in App Store Connect must equal the tag without `v`. Dove's 1.0.0 was typed there as `1.0`,
  hence the script's `--asc-version`.

## Things that cost time

- The marketplace being connected does not mean AltStore got Apple's notification. Check with `GET /adps/{id}`.
- `asc versions list` printed `PREPARE_FOR_SUBMISSION` for a version the API called `READY_FOR_DISTRIBUTION`.
- A new entitlement or usage description in the app must go into the source before that version is listed.
- `fediUsername` belongs to the source, not an app, and the account it creates is automated: changes go through
  apps@altstore.io. Do not submit the source to `/federate` again without a reason; how repeats are treated is not
  documented.
- Not looked into: Apple's Core Technology Fee and the other terms of distributing in the EU, and whether an app
  can later move between sources without users losing updates.
