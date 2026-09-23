#!/bin/bash
# Creates a self-signed code-signing identity "Slock" in a dedicated keychain.
# Signing with a stable identity (instead of ad-hoc) keeps macOS privacy permissions
# (Screen Recording, Accessibility, …) attached to the app across rebuilds.
# A separate keychain with a known password lets codesign use the key without GUI prompts.
set -euo pipefail
NAME="Slock"
KC="$HOME/Library/Keychains/slock-signing.keychain-db"
KC_PASS="slock-signing"

add_to_search_list() {
  # codesign only finds identities in keychains on the user search list.
  if ! security list-keychains -d user | grep -q "slock-signing"; then
    eval "security list-keychains -d user -s $(security list-keychains -d user | tr '\n' ' ') \"$KC\""
  fi
}

if [ -f "$KC" ]; then
  add_to_search_list
  security unlock-keychain -p "$KC_PASS" "$KC"
  if security find-identity -p codesigning "$KC" | grep -q "\"$NAME\""; then
    exit 0
  fi
else
  security create-keychain -p "$KC_PASS" "$KC"
fi
add_to_search_list
security set-keychain-settings "$KC"   # no auto-lock
security unlock-keychain -p "$KC_PASS" "$KC"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/slock.p12" -passout pass:slock
security import "$TMP/slock.p12" -k "$KC" -P slock -T /usr/bin/codesign >/dev/null
# Pre-authorise Apple's signing tools so codesign never shows "wants to use key" dialogs.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null
echo "Created signing identity \"$NAME\" in $KC"
