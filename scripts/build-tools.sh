#!/bin/bash
# The programs scripts/build.sh needs and the Homebrew packages they come from. Not run by itself:
# scripts/build.sh, which checks for them, and scripts/setup.sh, which offers to install them, both
# read this file with "source".

BUILD_TOOLS=(i686-w64-mingw32-g++ i686-w64-mingw32-objdump i686-w64-mingw32-strip meson ninja glslangValidator python3 patch)
BREW_PACKAGES=(mingw-w64 meson ninja glslang)   # mingw-w64 brings the three i686-w64-mingw32 programs

missing_build_tools() {   # prints the build tools that are not on the PATH, each after a space
  local tool
  for tool in "${BUILD_TOOLS[@]}"; do
    command -v "$tool" >/dev/null || printf ' %s' "$tool"
  done
}

brew_command() {   # the command that installs them
  echo "brew install ${BREW_PACKAGES[*]}"
}
