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
# The DLL is compiled with llvm-mingw, downloaded once into build/ (about 125 MB, checksum verified):
# Homebrew's 32-bit GCC uses setjmp/longjmp exceptions, whose bookkeeping on every function call cost
# about 5% of the game's main thread. MXO_COMPILER=gcc builds with Homebrew's GCC instead.
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

LLVM_MINGW_VERSION=20261104
LLVM_MINGW_SHA256=66cbd5178c4a71b0d473e68ede172f8eb7d15d023e67f39201d0a69e21f6bf3c
LLVM_MINGW="$WORK/toolchain/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal"
if [ "${MXO_COMPILER:-clang}" != gcc ] && [ ! -x "$LLVM_MINGW/bin/i686-w64-mingw32-clang++" ]; then
  echo "== downloading llvm-mingw $LLVM_MINGW_VERSION"
  mkdir -p "$WORK/toolchain"
  archive="$WORK/toolchain/llvm-mingw-$LLVM_MINGW_VERSION.tar.xz"
  curl -L --fail -o "$archive.part" \
    "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal.tar.xz"
  echo "$LLVM_MINGW_SHA256  $archive.part" | shasum -a 256 -c - >/dev/null || { echo "llvm-mingw checksum mismatch" >&2; exit 1; }
  mv "$archive.part" "$archive"
  # Unpacked next to its final place and renamed when complete, so an interrupted run never leaves a toolchain
  # folder that looks installed.
  unpack="$WORK/toolchain/unpacking"
  rm -rf "${unpack:?}" "${LLVM_MINGW:?}"
  mkdir -p "$unpack"
  tar -xJf "$archive" -C "$unpack"
  mv "$unpack/$(basename "$LLVM_MINGW")" "$LLVM_MINGW"
  rm -rf "${unpack:?}"
  rm -f "$archive"
fi

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
  cross=build-win32.txt
  extra=-Wno-template-body
  if [ "${MXO_COMPILER:-clang}" != gcc ]; then
    cross=build-win32-llvm-mingw.txt
    extra=
    L="$LLVM_MINGW/bin"
    printf "[binaries]\nc = '%s'\ncpp = '%s'\nar = '%s'\nstrip = '%s'\nwindres = '%s'\n\n[properties]\nneeds_exe_wrapper = true\n\n[host_machine]\nsystem = 'windows'\ncpu_family = 'x86'\ncpu = 'x86'\nendian = 'little'\n" \
      "$L/i686-w64-mingw32-clang" "$L/i686-w64-mingw32-clang++" "$L/llvm-ar" "$L/llvm-strip" "$L/i686-w64-mingw32-windres" > "$cross"
  fi
  meson setup --cross-file "$cross" --buildtype release \
    -Denable_dxgi=false -Denable_d3d10=false -Denable_d3d11=false -Denable_d3d9=true \
    -Dcpp_args="-include cstdint -include cstring -include cstdlib -include algorithm -include limits $extra" \
    build.w32 > "$WORK/meson.log" 2>&1
  ninja -C build.w32 > "$WORK/ninja.log" 2>&1
) || { echo "build failed, see build/meson.log and build/ninja.log" >&2; exit 1; }

if [ "${MXO_COMPILER:-clang}" != gcc ]; then
  "$LLVM_MINGW/bin/llvm-strip" -o "$WORK/d3d9.dll" "$WORK/dxvk/build.w32/src/d3d9/d3d9.dll"
else
  i686-w64-mingw32-strip -o "$WORK/d3d9.dll" "$WORK/dxvk/build.w32/src/d3d9/d3d9.dll"
fi
echo "== done: $WORK/d3d9.dll"
echo "   install steps: BUILD.md"
