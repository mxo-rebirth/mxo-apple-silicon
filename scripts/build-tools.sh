#!/bin/bash
# The programs scripts/build.sh needs and their Homebrew packages. Not run by itself: read with "source"
# by scripts/build.sh, which checks for them, and scripts/setup.sh, which offers to install them.

BUILD_TOOLS=(i686-w64-mingw32-g++ i686-w64-mingw32-objdump i686-w64-mingw32-strip meson ninja glslangValidator python3 patch)
BREW_PACKAGES=(mingw-w64 meson ninja glslang)   # mingw-w64 brings the three i686-w64-mingw32 programs

missing_build_tools() {   # those not on the PATH, each after a space
  local tool
  for tool in "${BUILD_TOOLS[@]}"; do
    command -v "$tool" >/dev/null || printf ' %s' "$tool"
  done
}

brew_command() {
  echo "brew install ${BREW_PACKAGES[*]}"
}
