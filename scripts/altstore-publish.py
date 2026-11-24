#!/usr/bin/env python3
"""Publishes a notarized iOS version to AltStore PAL.

    ./scripts/altstore-publish.py --tag v1.1.0 --source ../smigi-net/altstore/source.json [--dry-run]

Run once Apple has approved the version scripts/asc-notarize.py submitted. It is safe to run early or twice:
it does nothing until the version is Ready for Distribution, and skips what is already done.

1. Reads the version's alternative distribution package (ADP) ID from App Store Connect.
2. Asks AltStore's API for the package (and to process it, if Apple's notification never reached AltStore).
3. Attaches the package's files, unchanged, to the GitHub release of the tag.
4. Puts the version first in the app's `versions` in the AltStore source file (the caller commits and pushes it).

Needs `gh` (signed in, or GH_TOKEN) and the App Store Connect key (see asc_api.py). How this was worked out:
docs/implemented.md › AltStore PAL.
"""
import argparse
import datetime
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

import asc_api

ALTSTORE = "https://api.altstore.io/adps"
REPO = "lakafior/Dove"


def release_notes(body):
    """The release's notes as AltStore shows them: without headings (`## What's Changed`), the "Full Changelog"
    link and any install instructions after them (they point at sideloading)."""
    lines = []
    for line in body.splitlines():
        if line.startswith(("**Install on iPhone", "**AltStore PAL")):
            break
        if line.startswith("## ") or "Full Changelog" in line:
            continue
        lines.append(line)
    return "\n".join(lines).strip()


def altstore(method, adp=None, body=None):
    url = ALTSTORE + (f"/{adp}" if adp else "")
    data = json.dumps(body).encode() if body is not None else None
    # Cloudflare in front of the API answers Python's default User-Agent with 403 (error code 1010).
    request = urllib.request.Request(url, data=data, method=method, headers={
        "Content-Type": "application/json", "User-Agent": "Dove-release/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            text = response.read().decode()
            return response.status, (json.loads(text) if text else {})
    except urllib.error.HTTPError as error:
        if error.code == 404:   # AltStore has not heard of this package
            return 404, {}
        sys.exit(f"AltStore: HTTP {error.code}: {error.read().decode(errors='replace')[:300]}")


def fetch_package(adp, timeout):
    """AltStore's zip of the package, once it has processed it."""
    status, answer = altstore("GET", adp)
    if status == 404:
        # Apple's notification did not reach AltStore (it did not for 1.0.0): ask for it.
        status, _ = altstore("POST", body={"adpID": adp})
        if status not in (200, 202):
            sys.exit(f"AltStore refused to process the package: HTTP {status}")
        answer = {}
    deadline = time.time() + timeout
    while "downloadURL" not in answer:
        if answer.get("status") in ("failed", "failure", "error"):
            sys.exit(f"AltStore failed to process the package: {answer}")
        if time.time() > deadline:
            sys.exit("Timed out waiting for AltStore to process the package")
        print(f"AltStore: {answer.get('status', 'queued')}", flush=True)
        time.sleep(15)
        _, answer = altstore("GET", adp)
    # The link is signed for a few minutes only: download at once.
    with urllib.request.urlopen(answer["downloadURL"], timeout=300) as response:
        return response.read()


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True, help="the release tag, e.g. v1.1.0")
    parser.add_argument("--source", required=True, help="path to the AltStore source JSON to update")
    parser.add_argument("--asc-version", help="the version string in App Store Connect, when it differs "
                        "from the tag (1.0.0 was entered there by hand as 1.0)")
    parser.add_argument("--timeout", type=int, default=20 * 60, help="seconds to wait for AltStore")
    parser.add_argument("--dry-run", action="store_true", help="download and check, but upload and write nothing")
    args = parser.parse_args()
    version_string = args.tag.removeprefix("v")

    with open(args.source) as f:
        source = json.load(f)
    app_entry = next((a for a in source["apps"] if a["bundleIdentifier"] == asc_api.BUNDLE_ID), None)
    if app_entry is None:
        sys.exit(f"{args.source} has no app {asc_api.BUNDLE_ID}")
    listed = any(v["version"] == version_string for v in app_entry["versions"])

    release = json.loads(gh("release", "view", args.tag, "--repo", REPO, "--json", "assets,body"))
    attached = {asset["name"] for asset in release["assets"]}
    if listed and "manifest.json" in attached:
        print(f"{version_string} is already in the source and its package is on the release: nothing to do")
        return

    app = asc_api.app_id()
    version, included = asc_api.ios_version(app, args.asc_version or version_string,
                                            include="alternativeDistributionPackage")
    state = version["attributes"]["appVersionState"] if version else "not in App Store Connect"
    packages = [item for item in included if item["type"] == "alternativeDistributionPackages"]
    if state != "READY_FOR_DISTRIBUTION" or not packages:
        print(f"{version_string} is {state}" + ("" if packages else ", no package yet") + ": not ready")
        return
    adp = packages[0]["id"]
    print(f"{version_string}: package {adp}")

    archive = zipfile.ZipFile(io.BytesIO(fetch_package(adp, args.timeout)))
    folder = tempfile.mkdtemp(prefix="adp-")
    archive.extractall(folder)
    with open(os.path.join(folder, "manifest.json")) as f:
        manifest = json.load(f)
    if manifest["bundleId"] != asc_api.BUNDLE_ID or manifest["shortVersionString"] != version_string:
        sys.exit(f"The package is {manifest['bundleId']} {manifest['shortVersionString']}, not {version_string}")

    # manifest.json, signature and variant/<uuid>.ipa, attached flat and byte for byte.
    files = [os.path.join(folder, "manifest.json"), os.path.join(folder, "signature")]
    files += sorted(os.path.join(folder, "variant", name) for name in os.listdir(os.path.join(folder, "variant")))
    names = [os.path.basename(path) for path in files]
    if len(set(names)) != len(names):
        sys.exit(f"Two package files share a name: {names}")
    base = f"https://github.com/{REPO}/releases/download/{args.tag}/"
    notes = release_notes(release["body"])
    entry = {
        "version": manifest["shortVersionString"],
        "buildVersion": str(manifest["bundleVersion"]),
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
        "localizedDescription": notes or f"Release notes: https://github.com/{REPO}/releases/tag/{args.tag}",
        "downloadURL": base + "manifest.json",
        "size": manifest["variants"][0]["variantDetails"]["compressedSize"],
        "minOSVersion": manifest["minimumSystemVersions"]["ios"],
        # The key is the file's name without its extension.
        "assetURLs": {os.path.splitext(name)[0]: base + name for name in names},
    }

    if args.dry_run:
        print(f"Dry run: would attach {names} to {args.tag} and list:\n{json.dumps(entry, indent=2)}")
        return

    gh("release", "upload", args.tag, *files, "--repo", REPO, "--clobber")
    print(f"Attached {len(files)} files to {args.tag}")

    # AltStore takes the first entry as the latest version.
    app_entry["versions"] = [entry] + [v for v in app_entry["versions"] if v["version"] != version_string]
    with open(args.source, "w") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"Listed {version_string} in {args.source}")


if __name__ == "__main__":
    try:
        main()
    except asc_api.APIError as error:
        sys.exit(f"App Store Connect: {error}")
    except subprocess.CalledProcessError as error:
        sys.exit(f"gh failed: {error.stderr}")
