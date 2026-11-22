#!/bin/bash
# Builds the patched Direct3D 9 DLL for The Matrix Online from CodeWeavers' DXVK source.
#
#   scripts/build.sh /path/to/client.dll [crossover-sources-<version>.tar.gz]
#
# client.dll is the game's own file (from your Rejacked or Revived install). The translated math
# routines are generated from it on your machine. No game file is stored in this repository.
# Without a tarball argument, CodeWeavers' source for the CrossOver version in $CROSSOVER_VERSION
# (default: SOURCE_VERSION below) is downloaded once into build/. The default version is checked
# against a fixed checksum.
#
# Needs the programs listed in scripts/build-tools.sh, which also names their Homebrew packages.
# The DLL is compiled with llvm-mingw, downloaded once into build/ (about 125 MB, checksum verified):
# Homebrew's 32-bit GCC uses setjmp/longjmp exceptions, whose bookkeeping on every function call cost
# about 5% of the game's main thread. MXO_COMPILER=gcc builds with Homebrew's GCC instead.
set -euo pipefail

if [ $# -lt 1 ] || [ ! -f "$1" ]; then
  echo "usage: $0 /path/to/client.dll [crossover-sources-<version>.tar.gz]" >&2
  exit 2
fi

die() { echo "$*" >&2; exit 1; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLIENT=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
WORK="$ROOT/build"
SOURCE_VERSION=26.3.0   # the CrossOver whose DXVK the patch is made for
SOURCE_SHA256=ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872
VERSION=${CROSSOVER_VERSION:-$SOURCE_VERSION}

# shellcheck source=build-tools.sh
. "$ROOT/scripts/build-tools.sh"
missing=$(missing_build_tools)
[ -z "$missing" ] || die "missing tools:$missing. They come from Homebrew: $(brew_command)"

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
  echo "$LLVM_MINGW_SHA256  $archive.part" | shasum -a 256 -c - >/dev/null || die "llvm-mingw checksum mismatch"
  mv "$archive.part" "$archive"
  # Unpacked next to its final place and renamed when complete, so an interrupted run never leaves a toolchain
  # folder that looks installed.
  unpack="$WORK/toolchain/unpacking"
  rm -rf "${unpack:?}" "${LLVM_MINGW:?}"
  mkdir -p "$unpack"
  tar -xJf "$archive" -C "$unpack"
  mv "$unpack/$(basename "$LLVM_MINGW")" "$LLVM_MINGW"
  rm -rf "${unpack:?}"
  rm -f "${archive:?}"
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
  # The checksum is the default version's. Another version from CROSSOVER_VERSION and a tarball given
  # as the second argument are taken as they are.
  if [ "$VERSION" = "$SOURCE_VERSION" ] && ! echo "$SOURCE_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null 2>&1; then
    rm -f "${TARBALL:?}"
    die "$(basename "$TARBALL") did not match its checksum and was deleted. Run this again to download it afresh"
  fi
fi

echo "== unpacking DXVK from $(basename "$TARBALL")"
rm -rf "${WORK:?}/dxvk" "${WORK:?}/unpack"
mkdir -p "$WORK/unpack"
tar -xzf "$TARBALL" -C "$WORK/unpack" sources/dxvk
mv "$WORK/unpack/sources/dxvk" "$WORK/dxvk"
rm -rf "${WORK:?}/unpack"

echo "== applying the patch"
(cd "$WORK/dxvk" && patch -p1 -s < "$ROOT/dxvk/dxvk-d3d9-mxo.patch")
# The tests include translator/mxo_x87_apply.h, the DLL its copy in the patch. They must be the same file.
cmp -s "$ROOT/translator/mxo_x87_apply.h" "$WORK/dxvk/src/d3d9/d3d9_mxo_x87.h" \
  || die "translator/mxo_x87_apply.h differs from src/d3d9/d3d9_mxo_x87.h in the patch"

echo "== mapping the functions of client.dll (about a minute)"
python3 -I "$ROOT/translator/discover.py" "$CLIENT" "$WORK/client.map"

echo "== translating the x87 routines listed in translator/routines.list"
python3 -I "$ROOT/translator/xlat.py" pe "$CLIENT" MxoX "$WORK/dxvk/src/d3d9/d3d9_mxo_x87.inc" \
  --map "$WORK/client.map" "@$ROOT/translator/routines.list" > "$WORK/translate.log"
tail -n 1 "$WORK/translate.log"
grep -c '^SKIP' "$WORK/translate.log" | sed 's/^/   routines skipped (see build\/translate.log): /' || true

echo "== building d3d9.dll"
(   # "set -e" does not reach into the left side of "||": each step that can fail says so itself
  cd "$WORK/dxvk" || exit 1
  cross=build-win32.txt
  extra=-Wno-template-body
  if [ "${MXO_COMPILER:-clang}" != gcc ]; then
    cross=build-win32-llvm-mingw.txt
    extra=
    L="$LLVM_MINGW/bin"
    printf "[binaries]\nc = '%s'\ncpp = '%s'\nar = '%s'\nstrip = '%s'\nwindres = '%s'\n\n[properties]\nneeds_exe_wrapper = true\n\n[host_machine]\nsystem = 'windows'\ncpu_family = 'x86'\ncpu = 'x86'\nendian = 'little'\n" \
      "$L/i686-w64-mingw32-clang" "$L/i686-w64-mingw32-clang++" "$L/llvm-ar" "$L/llvm-strip" "$L/i686-w64-mingw32-windres" > "$cross" || exit 1
  fi
  meson setup --cross-file "$cross" --buildtype release \
    -Denable_dxgi=false -Denable_d3d10=false -Denable_d3d11=false -Denable_d3d9=true \
    -Dcpp_args="-include cstdint -include cstring -include cstdlib -include algorithm -include limits $extra" \
    build.w32 > "$WORK/meson.log" 2>&1 || exit 1
  ninja -C build.w32 > "$WORK/ninja.log" 2>&1
) || die "build failed, see build/meson.log and build/ninja.log"

if [ "${MXO_COMPILER:-clang}" != gcc ]; then
  "$LLVM_MINGW/bin/llvm-strip" -o "$WORK/d3d9.dll" "$WORK/dxvk/build.w32/src/d3d9/d3d9.dll"
else
  i686-w64-mingw32-strip -o "$WORK/d3d9.dll" "$WORK/dxvk/build.w32/src/d3d9/d3d9.dll"
fi
echo "== done: $WORK/d3d9.dll"
echo "   install steps: docs/building.md"
