#!/usr/bin/env bash
# Builds "Splat Viewer.app" (viewer app + Quick Look extension) WITHOUT an Xcode project:
# plain swiftc, universal binary (Apple Silicon + Intel), ad-hoc signature.
# Runs on macOS with the Xcode command line tools (GitHub Actions macOS runners have them).
set -euo pipefail
cd "$(dirname "$0")"
MAC_DIR=$(pwd)
ROOT=$(cd .. && pwd)

VERSION=${VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)}
MIN_OS=13.0
OUT="$MAC_DIR/build"
APP="$OUT/Splat Viewer.app"
APPEX="$APP/Contents/PlugIns/SplatPreview.appex"

echo "==> Splat Viewer for macOS $VERSION"
rm -rf "$OUT"
mkdir -p "$OUT/obj" "$APP/Contents/MacOS" "$APP/Contents/Resources/web" \
         "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources/web"

# 1) web viewer (shared with the Windows plugin)
echo "==> web viewer"
(cd "$ROOT/web" && { [ -d node_modules ] || npm ci --no-audit --no-fund; } && npm run build --silent)

# 2) Swift binaries, one per architecture, then lipo
SDK=$(xcrun --sdk macosx --show-sdk-path)
SWIFTC=(xcrun --sdk macosx swiftc -swift-version 5 -O -sdk "$SDK" -parse-as-library)
xcrun --sdk macosx swiftc --version

for ARCH in arm64 x86_64; do
  TARGET="$ARCH-apple-macos$MIN_OS"
  echo "==> app ($ARCH)"
  "${SWIFTC[@]}" -target "$TARGET" -module-name SplatViewer \
    Sources/Shared/*.swift Sources/App/*.swift \
    -o "$OUT/obj/SplatViewer-$ARCH"

  echo "==> Quick Look extension ($ARCH)"
  "${SWIFTC[@]}" -target "$TARGET" -module-name SplatPreview -application-extension \
    Sources/Shared/*.swift Sources/Preview/*.swift \
    -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -application_extension \
    -o "$OUT/obj/SplatPreview-$ARCH"
done

lipo -create "$OUT/obj/SplatViewer-arm64" "$OUT/obj/SplatViewer-x86_64" -output "$APP/Contents/MacOS/SplatViewer"
lipo -create "$OUT/obj/SplatPreview-arm64" "$OUT/obj/SplatPreview-x86_64" -output "$APPEX/Contents/MacOS/SplatPreview"

# 3) bundle resources
echo "==> bundle"
sed "s/__VERSION__/$VERSION/g" Resources/App-Info.plist > "$APP/Contents/Info.plist"
sed "s/__VERSION__/$VERSION/g" Resources/Preview-Info.plist > "$APPEX/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/web/dist/index.html" "$ROOT/web/dist/viewer.js" "$APP/Contents/Resources/web/"
cp "$ROOT/web/dist/index.html" "$ROOT/web/dist/viewer.js" "$APPEX/Contents/Resources/web/"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# if this macOS already knows a type identifier for one of our extensions, accept that one too
for EXT in ply spz splat ksplat sog; do
  UTI=$(swift Resources/uti.swift "$EXT" 2>/dev/null || true)
  if [ -n "$UTI" ] && ! /usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionAttributes:QLSupportedContentTypes" "$APPEX/Contents/Info.plist" | grep -qx "    $UTI"; then
    echo "    + system type for .$EXT: $UTI"
    /usr/libexec/PlistBuddy -c "Add :NSExtension:NSExtensionAttributes:QLSupportedContentTypes:0 string $UTI" "$APPEX/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string $UTI" "$APP/Contents/Info.plist"
  fi
done
plutil -lint "$APP/Contents/Info.plist" "$APPEX/Contents/Info.plist"

# 4) ad-hoc signature (inside out). The extension must be sandboxed to be loaded by Quick Look.
echo "==> sign (ad-hoc)"
codesign --force --sign - --timestamp=none --entitlements Resources/Preview.entitlements "$APPEX"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APPEX" 2>/dev/null | head -20 || true

# 5) zip for distribution (ditto keeps bundle metadata intact)
echo "==> package"
(cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent "Splat Viewer.app" "SplatViewer-mac.zip")
ls -la "$OUT"
echo "OK -> $OUT/SplatViewer-mac.zip"
