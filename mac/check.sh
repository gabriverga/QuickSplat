#!/usr/bin/env bash
# Smoke test on a macOS machine/runner after build.sh:
# installs the app in a temp folder, registers the Quick Look extension and checks the system accepts it.
# Prints diagnostics; exits non-zero only if the bundle itself is broken.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
APP="build/QuickSplat.app"
APPEX="$APP/Contents/PlugIns/QuickSplatPreview.appex"
ID=it.gabriverga.QuickSplat.Preview

echo "==> architectures"
lipo -info "$APP/Contents/MacOS/QuickSplat" || exit 1
lipo -info "$APPEX/Contents/MacOS/QuickSplatPreview" || exit 1

echo "==> entry point / linked frameworks of the extension"
otool -L "$APPEX/Contents/MacOS/QuickSplatPreview" | grep -E "QuickLookUI|WebKit|AppKit" || exit 1
nm -u "$APPEX/Contents/MacOS/QuickSplatPreview" | grep -q _NSExtensionMain && echo "_NSExtensionMain: ok" || { echo "missing _NSExtensionMain"; exit 1; }

echo "==> signature"
codesign --verify --strict --verbose=2 "$APP" || exit 1
codesign -d --entitlements - "$APPEX" 2>&1 | grep -q app-sandbox && echo "sandbox entitlement: ok" || { echo "extension not sandboxed"; exit 1; }

echo "==> registration (informational)"
DEST=$(mktemp -d)/Applications
mkdir -p "$DEST"
ditto "$APP" "$DEST/QuickSplat.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/QuickSplat.app" || true
pluginkit -a "$DEST/QuickSplat.app/Contents/PlugIns/QuickSplatPreview.appex" || true
sleep 2
pluginkit -e use -i "$ID" || true
pluginkit -mAvvv -i "$ID" || true
if pluginkit -m -i "$ID" | grep -q "$ID"; then
  echo "Quick Look extension registered OK"
else
  echo "WARNING: pluginkit does not list the extension on this runner"
fi
exit 0
