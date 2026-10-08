#!/usr/bin/env python3
"""Read Pelu's App Store Connect status; never writes to Apple's API.

Requires Python's cryptography package. Credentials stay in an ignored local
configuration file. Relative key paths resolve from the configuration directory.
"""
import base64
import json
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature


def encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def main():
    config_path = Path(__file__).resolve().parent.parent / ".appstoreconnect.local.json"
    config = json.loads(config_path.read_text())
    key_path = Path(config["private_key_path"]).expanduser()
    if not key_path.is_absolute():
        key_path = config_path.parent / key_path
    key = serialization.load_pem_private_key(
        key_path.read_bytes(), password=None
    )
    if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1):
        raise ValueError("Expected a P-256 App Store Connect private key")
    now = int(time.time())
    header = {"alg": "ES256", "kid": config["key_id"], "typ": "JWT"}
    payload = {"iss": config["issuer_id"], "iat": now, "exp": now + 300,
               "aud": "appstoreconnect-v1"}
    message = ".".join(encode(json.dumps(part, separators=(",", ":")).encode())
                       for part in (header, payload))
    r, s = decode_dss_signature(key.sign(message.encode(), ec.ECDSA(hashes.SHA256())))
    token = message + "." + encode(r.to_bytes(32, "big") + s.to_bytes(32, "big"))

    def get(path, params):
        request = Request("https://api.appstoreconnect.apple.com/v1/" + path
                          + "?" + urlencode(params),
                          headers={"Authorization": "Bearer " + token})
        with urlopen(request, timeout=30) as response:
            return json.load(response)["data"]

    apps = get("apps", {"filter[bundleId]": config["bundle_id"], "limit": 2})
    if len(apps) != 1:
        raise ValueError("Expected exactly one accessible app with the configured bundle ID")
    app = apps[0]
    versions = get("apps/" + app["id"] + "/appStoreVersions", {"limit": 20})
    builds = get("builds", {"filter[app]": app["id"], "sort": "-uploadedDate", "limit": 10})
    print(json.dumps({"app": {"id": app["id"], **app["attributes"]},
                      "versions": [{"id": row["id"], **row["attributes"]} for row in versions],
                      "recent_builds": [{"id": row["id"], **row["attributes"]} for row in builds]},
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except HTTPError as error:
        print(f"App Store Connect returned HTTP {error.code}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, URLError) as error:
        print(f"Connection check failed ({type(error).__name__}): {error}", file=sys.stderr)
        sys.exit(1)
