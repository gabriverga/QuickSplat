#!/bin/bash
# QuickSplat for macOS - installer.
#
#   Public repo:   curl -fsSL https://github.com/__REPO__/releases/latest/download/install-mac.sh | bash
#   Private repo:  download QuickSplat-mac.zip and install-mac.sh from the release, then run
#                  bash ~/Downloads/install-mac.sh
#
# Puts "QuickSplat.app" in /Applications, clears the download quarantine flag (so Gatekeeper
# doesn't block the un-notarized app) and enables its Quick Look extension.
set -euo pipefail

REPO="__REPO__"
URL="https://github.com/$REPO/releases/latest/download/QuickSplat-mac.zip"
APP_NAME="QuickSplat.app"
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

# 1) find the app: argument, next to this script, in Downloads (zip or already unzipped by Safari), or download it
SRC=""
for candidate in "${1:-}" \
                 "$SCRIPT_DIR/QuickSplat-mac.zip" "$SCRIPT_DIR/$APP_NAME" \
                 "$HOME/Downloads/QuickSplat-mac.zip" "$HOME/Downloads/$APP_NAME"; do
  if [ -n "$candidate" ] && [ -e "$candidate" ] && [ "$candidate" != "/$APP_NAME" ]; then
    SRC="$candidate"
    break
  fi
done

if [ -z "$SRC" ]; then
  echo "Downloading QuickSplat..."
  curl -fL --progress-bar "$URL" -o "$TMP/QuickSplat-mac.zip"
  SRC="$TMP/QuickSplat-mac.zip"
fi

if [[ "$SRC" == *.zip ]]; then
  echo "Unpacking $SRC"
  ditto -x -k "$SRC" "$TMP/unzipped"
  APP_SRC="$TMP/unzipped/$APP_NAME"
else
  APP_SRC="$SRC"
fi
[ -d "$APP_SRC" ] || { echo "Can't find $APP_NAME in $SRC"; exit 1; }

# 2) install
echo "Installing to $DEST..."
pkill -x QuickSplat 2>/dev/null || true
pkill -x SplatViewer 2>/dev/null || true
rm -rf "${DEST:?}/${APP_NAME:?}" "${DEST:?}/Splat Viewer.app"   # also remove the pre-rename app
ditto "$APP_SRC" "$DEST/$APP_NAME"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

# 3) register the app and its Quick Look extension
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/$APP_NAME" 2>/dev/null || true
pluginkit -a "$DEST/$APP_NAME/Contents/PlugIns/QuickSplatPreview.appex" 2>/dev/null || true
pluginkit -e use -i it.gabriverga.QuickSplat.Preview 2>/dev/null || true
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

open "$DEST/$APP_NAME"
echo
echo "Done. Select a .ply / .spz / .splat / .ksplat / .sog file in Finder and press Space."
echo "If nothing shows up, enable \"QuickSplat\" in System Settings > General > Login Items & Extensions > Quick Look."
