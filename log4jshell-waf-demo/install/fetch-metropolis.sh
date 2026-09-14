#!/usr/bin/env bash
#
# fetch-metropolis.sh  -  download the Metropolis web fonts (Unlicense / public
# domain) from Fontsource and install the weights the console uses.
#
# Run this on a machine WITH internet + npm (your laptop, the api box, etc).
# web-a-03c is egress-locked and does NOT need this: the fonts already ship in
# the package under control-plane/fonts/ and the installer copies them.
#
# Usage:  ./fetch-metropolis.sh [DEST_DIR]     (default: /opt/log4shell-demo/fonts)
#
set -euo pipefail
DEST="${1:-/opt/log4shell-demo/fonts}"
VER="${METROPOLIS_VERSION:-5.3.0}"
TMP="$(mktemp -d)"
echo "==> fetching @fontsource/metropolis@${VER} from the npm registry"
( cd "$TMP" && npm pack "@fontsource/metropolis@${VER}" >/dev/null && tar xzf ./*.tgz )
mkdir -p "$DEST"
for w in 400 500 600 700; do
  src="$TMP/package/files/metropolis-latin-${w}-normal.woff2"
  [ -f "$src" ] || { echo "missing weight ${w} in package"; exit 1; }
  install -m 0644 "$src" "$DEST/Metropolis-${w}.woff2"
done
rm -rf "$TMP"
echo "==> installed Metropolis to $DEST:"
ls -1 "$DEST"
