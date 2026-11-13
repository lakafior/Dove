#!/usr/bin/env python3
"""Submits an uploaded iOS build for notarization (alternative distribution, AltStore PAL).

    ./scripts/asc-notarize.py --version 1.1.0 --build 140 [--whats-new "…"] [--dry-run]

After scripts/build-ios.sh upload: waits until App Store Connect has processed the build, makes (or reuses)
the App Store version with review type Notarization, attaches the build and submits it for review.
Apple then reviews it (hours to a day or two); scripts/altstore-publish.py does the rest once the version
is Ready for Distribution.

The key: see asc_api.py. --dry-run reads everything and changes nothing.
"""
import argparse
import sys
import time

import asc_api
from asc_api import APIError, call

# Nothing to submit in these states: the version is with Apple or already out.
BUSY = {"WAITING_FOR_REVIEW", "IN_REVIEW", "PROCESSING_FOR_DISTRIBUTION", "READY_FOR_DISTRIBUTION",
        "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "ACCEPTED"}


def wait_for_build(app, version, build, timeout):
    query = {"filter[app]": app, "filter[version]": build, "filter[preReleaseVersion.version]": version,
             "filter[preReleaseVersion.platform]": "IOS"}
    deadline = time.time() + timeout
    while True:
        builds = call("GET", "/v1/builds", query=query)["data"]
        state = builds[0]["attributes"]["processingState"] if builds else "not listed yet"
        print(f"build {version} ({build}): {state}", flush=True)
        if state == "VALID":
            return builds[0]["id"]
        if state in ("FAILED", "INVALID"):
            sys.exit(f"App Store Connect rejected the build: {state}")
        if time.time() > deadline:
            sys.exit("Timed out waiting for App Store Connect to process the build")
        time.sleep(60)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--whats-new", default="")
    parser.add_argument("--timeout", type=int, default=45 * 60, help="seconds to wait for build processing")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    app = asc_api.app_id()
    existing, _ = asc_api.ios_version(app, args.version)
    if existing and existing["attributes"]["appVersionState"] in BUSY:
        print(f"Version {args.version} is {existing['attributes']['appVersionState']}: nothing to submit")
        return
    if args.dry_run:
        state = existing["attributes"]["appVersionState"] if existing else "not created"
        print(f"Dry run: app {app}, version {args.version} is {state}; would wait for build {args.build}, "
              "set review type NOTARIZATION and submit")
        return

    build = wait_for_build(app, args.version, args.build, args.timeout)
    build_link = {"data": {"type": "builds", "id": build}}

    if existing:
        version = existing["id"]
        call("PATCH", f"/v1/appStoreVersions/{version}", {"data": {
            "type": "appStoreVersions", "id": version, "attributes": {"reviewType": "NOTARIZATION"}}})
        call("PATCH", f"/v1/appStoreVersions/{version}/relationships/build", build_link)
        print(f"Reusing version {args.version} ({version})")
    else:
        version = call("POST", "/v1/appStoreVersions", {"data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": args.version, "reviewType": "NOTARIZATION"},
            "relationships": {"app": {"data": {"type": "apps", "id": app}}, "build": build_link}}})["data"]["id"]
        print(f"Created version {args.version} ({version})")

    if args.whats_new:
        # Not possible on an app's first version; a failure here should not stop the submission.
        try:
            for item in call("GET", f"/v1/appStoreVersions/{version}/appStoreVersionLocalizations")["data"]:
                call("PATCH", f"/v1/appStoreVersionLocalizations/{item['id']}", {"data": {
                    "type": "appStoreVersionLocalizations", "id": item["id"],
                    "attributes": {"whatsNew": args.whats_new}}})
        except APIError as error:
            print(f"::warning::Could not set What's New: {error}")

    # One open submission per app and platform: reuse one left over from an earlier failed run.
    app_link = {"data": {"type": "apps", "id": app}}
    open_ones = call("GET", "/v1/reviewSubmissions", query={
        "filter[app]": app, "filter[platform]": "IOS", "filter[state]": "READY_FOR_REVIEW"})["data"]
    if open_ones:
        submission = open_ones[0]["id"]
    else:
        submission = call("POST", "/v1/reviewSubmissions", {"data": {
            "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
            "relationships": {"app": app_link}}})["data"]["id"]
    try:
        call("POST", "/v1/reviewSubmissionItems", {"data": {
            "type": "reviewSubmissionItems", "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version}}}}})
    except APIError as error:
        if error.status != 409:   # 409: the version is already an item of this submission
            raise
    call("PATCH", f"/v1/reviewSubmissions/{submission}", {"data": {
        "type": "reviewSubmissions", "id": submission, "attributes": {"submitted": True}}})
    print(f"Submitted {args.version} ({args.build}) for notarization")


if __name__ == "__main__":
    try:
        main()
    except APIError as error:
        sys.exit(f"App Store Connect: {error}")
