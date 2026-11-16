#!/bin/bash
# Builds the patched Direct3D 9 DLL for The Matrix Online from CodeWeavers' DXVK source.
#
#   scripts/build.sh /path/to/client.dll [crossover-sources-<version>.tar.gz]
#
# client.dll is the game's own file (from your Rejacked or Revived install). The translated math
# routines are generated from it on your machine; nothing from the game is stored in this repository.
# Without a tarball argument, CodeWeavers' source for CrossOver $CROSSOVER_VERSION (default 26.3.0)
# is downloaded once into build/.
#
# Needs: mingw-w64 (i686), meson, ninja, glslang, python3.   brew install mingw-w64 meson ninja glslang
set -euo pipefail

if [ $# -lt 1 ] || [ ! -f "$1" ]; then
  echo "usage: $0 /path/to/client.dll [crossover-sources-<version>.tar.gz]" >&2
  exit 2
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLIENT=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
WORK="$ROOT/build"
VERSION=${CROSSOVER_VERSION:-26.3.0}

for tool in i686-w64-mingw32-g++ i686-w64-mingw32-objdump i686-w64-mingw32-strip meson ninja glslangValidator python3 patch; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

mkdir -p "$WORK"

if [ $# -ge 2 ]; then
  TARBALL=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
else
  TARBALL="$WORK/crossover-sources-$VERSION.tar.gz"
  if [ ! -f "$TARBALL" ]; then
    echo "== downloading CodeWeavers' source for CrossOver $VERSION"
    curl -L --fail -o "$TARBALL.part" "https://media.codeweavers.com/pub/crossover/source/crossover-sources-$VERSION.tar.gz"
    mv "$TARBALL.part" "$TARBALL"
  fi
fi

echo "== unpacking DXVK from $(basename "$TARBALL")"
rm -rf "$WORK/dxvk" "$WORK/unpack"
mkdir -p "$WORK/unpack"
tar -xzf "$TARBALL" -C "$WORK/unpack" sources/dxvk
mv "$WORK/unpack/sources/dxvk" "$WORK/dxvk"
rm -rf "$WORK/unpack"

echo "== applying the patch"
(cd "$WORK/dxvk" && patch -p1 -s < "$ROOT/dxvk/dxvk-d3d9-mxo.patch")

echo "== mapping the functions of client.dll (about a minute)"
python3 -I "$ROOT/translator/discover.py" "$CLIENT" "$WORK/client.map"

echo "== translating the x87 routines listed in translator/routines.list"
python3 -I "$ROOT/translator/xlat.py" pe "$CLIENT" MxoX "$WORK/dxvk/src/d3d9/d3d9_mxo_x87.inc" \
  --map "$WORK/client.map" "@$ROOT/translator/routines.list" > "$WORK/translate.log"
tail -n 1 "$WORK/translate.log"
grep -c '^SKIP' "$WORK/translate.log" | sed 's/^/   routines skipped (see build\/translate.log): /' || true

echo "== building d3d9.dll"
(
  cd "$WORK/dxvk"
  meson setup --cross-file build-win32.txt --buildtype release \
    -Denable_dxgi=false -Denable_d3d10=false -Denable_d3d11=false -Denable_d3d9=true \
    -Dcpp_args="-include cstdint -include cstring -include cstdlib -include algorithm -include limits -Wno-template-body" \
    build.w32 > "$WORK/meson.log" 2>&1
  ninja -C build.w32 > "$WORK/ninja.log" 2>&1
) || { echo "build failed, see build/meson.log and build/ninja.log" >&2; exit 1; }

i686-w64-mingw32-strip -o "$WORK/d3d9.dll" "$WORK/dxvk/build.w32/src/d3d9/d3d9.dll"
echo "== done: $WORK/d3d9.dll"
echo "   install steps: BUILD.md"
