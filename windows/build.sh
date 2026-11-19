#!/usr/bin/env bash
# Builds QuickLook.Plugin.QuickSplat.qlplugin (plugin for QuickLook on Windows).
# Runs on Linux or macOS: needs Node.js, the .NET SDK (for the C# compiler), git and zip.
# Nothing Windows-specific is needed: the plugin is compiled against .NET Framework 4.6.2
# reference assemblies (from mono/reference-assemblies) and a reference-only QuickLook.Common stub.
set -euo pipefail
cd "$(dirname "$0")"
WIN_DIR=$(pwd)
ROOT=$(cd .. && pwd)
VERSION=${VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)}
OUT="$WIN_DIR/build"

# .NET Framework 4.6.2 reference assemblies
REF=${REF:-$ROOT/.cache/refasm/v4.6.2}
if [ ! -f "$REF/mscorlib.dll" ]; then
  echo "==> fetching .NET Framework reference assemblies"
  rm -rf "$ROOT/.cache/refasm"
  git clone --depth 1 --filter=blob:none --sparse https://github.com/mono/reference-assemblies "$ROOT/.cache/refasm"
  git -C "$ROOT/.cache/refasm" sparse-checkout set v4.6.2
fi

# C# compiler from the .NET SDK
if [ -z "${CSC:-}" ]; then
  DOTNET_ROOT_DIR=$(dirname "$(readlink -f "$(command -v dotnet)")")
  CSC_DLL=$(ls "$DOTNET_ROOT_DIR"/sdk/*/Roslyn/bincore/csc.dll | sort -V | tail -1)
  CSC="dotnet $CSC_DLL"
fi

echo "==> QuickLook QuickSplat for Windows $VERSION"

# 1) web viewer
(cd "$ROOT/web" && { [ -d node_modules ] || npm ci --no-audit --no-fund; } && npm run build --silent)

# 2) reference-only QuickLook.Common + plugin
rm -rf "$OUT" && mkdir -p "$OUT"
$CSC -nologo -nostdlib -noconfig -target:library -langversion:7.3 -nowarn:CS0067 \
  -out:"$OUT/QuickLook.Common.dll" -r:"$REF/mscorlib.dll" -r:"$REF/System.dll" -r:"$REF/WindowsBase.dll" stub/*.cs
$CSC -nologo -nostdlib -noconfig -target:library -langversion:7.3 -optimize+ -deterministic \
  -out:"$OUT/QuickLook.Plugin.QuickSplat.dll" \
  -r:"$REF/mscorlib.dll" -r:"$REF/System.dll" -r:"$REF/System.Core.dll" -r:"$REF/WindowsBase.dll" \
  -r:"$REF/System.Drawing.dll" -r:"$REF/System.Xaml.dll" -r:"$OUT/QuickLook.Common.dll" plugin/*.cs

# 3) package (the stub QuickLook.Common.dll is NOT shipped)
PKG="$OUT/pkg"
mkdir -p "$PKG/web"
cp "$OUT/QuickLook.Plugin.QuickSplat.dll" "$PKG/"
sed "s#<Version>.*</Version>#<Version>$VERSION</Version>#" plugin/QuickLook.Plugin.Metadata.config > "$PKG/QuickLook.Plugin.Metadata.config"
cp "$ROOT/web/dist/index.html" "$ROOT/web/dist/viewer.js" "$PKG/web/"
(cd "$PKG" && zip -qr "$OUT/QuickLook.Plugin.QuickSplat.qlplugin" .)
echo "OK -> $OUT/QuickLook.Plugin.QuickSplat.qlplugin"
