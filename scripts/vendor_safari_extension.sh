#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Vendor the Safari build of the solstone extension, and the native-browser
# contract its native handler checks frames against, from one clean
# solstone-browser checkout. Both come from the same revision, recorded with a
# digest of the vendored trees in vendor/safari-extension.json.
# Usage: scripts/vendor_safari_extension.sh <solstone-browser checkout>
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$(cd "${1:?solstone-browser checkout}" && pwd)"
if [ -n "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]; then
  echo "solstone-browser checkout has uncommitted changes" >&2
  exit 1
fi
REV="$(git -C "$SRC" rev-parse HEAD)"
(cd "$SRC" && node scripts/build.mjs >/dev/null)
VERSION="$(node -p "JSON.parse(require('fs').readFileSync('$SRC/extension/manifest.json','utf8')).version")"
STAGE="$SRC/dist/solstone-browser-$VERSION-safari"
test -f "$STAGE/manifest.json"
rm -rf vendor/safari-extension vendor/browser-contract
mkdir -p vendor
cp -R "$STAGE" vendor/safari-extension
# This app's copy starts on the normal logo: iPhone and iPad never repaint the toolbar.
node --input-type=module -e "
import { iosSafariManifest } from '$SRC/scripts/verify-package.mjs';
import { readFileSync, writeFileSync } from 'node:fs';
const path = 'vendor/safari-extension/manifest.json';
writeFileSync(path, JSON.stringify(iosSafariManifest(JSON.parse(readFileSync(path, 'utf8'))), null, 2) + '\\n');
"
mkdir -p vendor/browser-contract/contracts/native-browser vendor/browser-contract/crates/native-browser-frame/src
for f in authority.json envelope.schema.json browser.schema.json manifest.json; do
  cp "$SRC/contracts/native-browser/$f" vendor/browser-contract/contracts/native-browser/
done
cp "$SRC/crates/native-browser-frame/src/constants.rs" vendor/browser-contract/crates/native-browser-frame/src/
digest() { (cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"; done | shasum -a 256 | cut -d' ' -f1); }
cat > vendor/safari-extension.json <<JSON
{
  "source": "solstone-browser",
  "revision": "$REV",
  "version": "$VERSION",
  "tree_sha256": "$(digest vendor/safari-extension)",
  "contract_sha256": "$(digest vendor/browser-contract)"
}
JSON
echo "vendored solstone-browser $VERSION at $REV"
