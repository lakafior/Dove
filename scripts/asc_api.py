"""App Store Connect API with the standard library only (shared by asc-notarize.py and altstore-publish.py).

The key comes from NOTARY_KEY_PATH (.p8), NOTARY_KEY_ID and NOTARY_ISSUER_ID, the same variables the build
scripts use. On the owner's Mac, without them, the key the `asc` CLI saved in ~/.asc/credentials.json is used.
ES256 signing is done by /usr/bin/openssl, so nothing has to be installed.
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "net.smigi.dove"


class APIError(Exception):
    def __init__(self, status, body):
        super().__init__(f"HTTP {status}: {body[:600]}")
        self.status = status
        self.body = body


def _find(obj, names):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key in names and isinstance(value, str):
                return value
        obj = list(obj.values())
    if isinstance(obj, list):
        for value in obj:
            found = _find(value, names)
            if found:
                return found
    return None


def _credentials():
    path = os.environ.get("NOTARY_KEY_PATH")
    if path:
        with open(path) as f:
            return os.environ["NOTARY_KEY_ID"], os.environ["NOTARY_ISSUER_ID"], f.read()
    saved = os.path.expanduser("~/.asc/credentials.json")
    if os.path.exists(saved):
        with open(saved) as f:
            data = json.load(f)
        key = _find(data, ("privateKeyPEM", "privateKey", "key"))
        if key and "-----BEGIN" not in key:
            key = "-----BEGIN PRIVATE KEY-----\n" + key.strip() + "\n-----END PRIVATE KEY-----\n"
        return _find(data, ("keyID", "keyId")), _find(data, ("issuerID", "issuerId")), key
    sys.exit("No App Store Connect key: set NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID")


def _b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def _der_to_raw(der):
    """An ECDSA signature from openssl is DER (SEQUENCE of two INTEGERs); a JWT wants r||s, 32 bytes each."""
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        assert der[i] == 0x02
        length = der[i + 1]
        parts.append(der[i + 2:i + 2 + length].lstrip(b"\0").rjust(32, b"\0"))
        i += 2 + length
    return parts[0] + parts[1]


_token = (0, "")


def token():
    global _token
    if _token[0] > time.time() + 60:
        return _token[1]
    key_id, issuer, pem = _credentials()
    now = int(time.time())
    head = _b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    body = _b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}).encode())
    message = head + b"." + body
    fd, key_path = tempfile.mkstemp(suffix=".pem")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(pem)
        der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                             input=message, capture_output=True, check=True).stdout
    finally:
        os.unlink(key_path)
    _token = (now + 900, (message + b"." + _b64(_der_to_raw(der))).decode())
    return _token[1]


def call(method, path, body=None, query=None):
    url = BASE + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            text = response.read().decode()
    except urllib.error.HTTPError as error:
        raise APIError(error.code, error.read().decode(errors="replace")) from None
    return json.loads(text) if text else {}


def app_id():
    apps = call("GET", "/v1/apps", query={"filter[bundleId]": BUNDLE_ID})["data"]
    # The filter matches prefixes too (net.smigi.dove.share…): take the exact one.
    for app in apps:
        if app["attributes"]["bundleId"] == BUNDLE_ID:
            return app["id"]
    sys.exit(f"No app with bundle ID {BUNDLE_ID} in App Store Connect")


def ios_version(app, version_string, include=None):
    """The iOS App Store version with this version string, and the response's `included` list."""
    query = {"filter[versionString]": version_string, "filter[platform]": "IOS"}
    if include:
        query["include"] = include
    answer = call("GET", f"/v1/apps/{app}/appStoreVersions", query=query)
    return (answer["data"][0] if answer["data"] else None), answer.get("included", [])
