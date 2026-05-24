#!/bin/bash
# One-time: generate Sparkle Ed25519 keypair.
# Private key is stored in your login Keychain (item: "https://sparkle-project.org").
# Public key is printed to stdout — copy it into the PeluMac target's
# `SUPublicEDKey` build setting (replaces REPLACE_WITH_ED25519_PUBLIC_KEY).
set -euo pipefail

GEN_KEYS="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path "*/Sparkle*/bin/generate_keys" -perm +111 2>/dev/null | head -1)"

if [[ -z "$GEN_KEYS" ]]; then
  echo "Error: generate_keys not found." >&2
  echo "Open Pelu.xcodeproj in Xcode and build PeluMac once first so SPM fetches Sparkle." >&2
  exit 1
fi

echo "==> Running $GEN_KEYS"
exec "$GEN_KEYS"
