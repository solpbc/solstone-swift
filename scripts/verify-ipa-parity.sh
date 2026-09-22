#!/usr/bin/env bash
# Prove that the device-signed IPA and the App Store IPA carry the same compiled
# binary.
#
# Both are exported from one .xcarchive: the App Store export is what ships, the
# device export is what a hardware gate can actually install. Signing differs by
# construction (Apple Distribution vs Apple Development), so the comparison strips
# signatures before hashing. If these hashes diverge, a device run is no longer
# evidence about the shipping bytes and the gate is worthless -- so this check is
# a hard failure, not a warning.
set -euo pipefail

APPSTORE_IPA="${1:-build/ipa-appstore/solstone-swift.ipa}"
DEVICE_IPA="${2:-build/ipa-device/solstone-swift.ipa}"

for f in "$APPSTORE_IPA" "$DEVICE_IPA"; do
  [ -f "$f" ] || { echo "error: not found: $f" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

extract_binary() {
  # $1 = ipa path, $2 = label. Echoes the sha256 of the unsigned main executable.
  local ipa="$1" label="$2" dir="$work/$2"
  mkdir -p "$dir"
  unzip -q "$ipa" -d "$dir"
  local app
  app="$(find "$dir/Payload" -maxdepth 1 -name '*.app' -print -quit)"
  [ -n "$app" ] || { echo "error: no .app inside $ipa" >&2; exit 1; }
  local exe="$app/$(basename "$app" .app)"
  [ -f "$exe" ] || { echo "error: no main executable in $app" >&2; exit 1; }
  cp "$exe" "$work/$label.bin"
  # Signatures differ by design; remove them so the comparison is about code.
  codesign --remove-signature "$work/$label.bin" 2>/dev/null || true
  shasum -a 256 "$work/$label.bin" | cut -d' ' -f1
}

appstore_sha="$(extract_binary "$APPSTORE_IPA" appstore)"
device_sha="$(extract_binary "$DEVICE_IPA" device)"
appstore_size="$(wc -c < "$work/appstore.bin" | tr -d ' ')"
device_size="$(wc -c < "$work/device.bin" | tr -d ' ')"

echo "app store : $appstore_sha  ($appstore_size bytes)  $APPSTORE_IPA"
echo "device    : $device_sha  ($device_size bytes)  $DEVICE_IPA"

if [ "$appstore_sha" != "$device_sha" ]; then
  echo "" >&2
  echo "IPA PARITY FAILED: the device build is not the shipping build." >&2
  echo "A hardware run against this IPA proves nothing about what ships." >&2
  echo "Most likely cause: the two IPAs came from different archives." >&2
  echo "Export both from one archive -- 'make ipa-device' deliberately does not" >&2
  echo "re-archive for exactly this reason." >&2
  exit 1
fi

echo ""
echo "IPA PARITY OK: identical compiled binary; only the signature differs."
