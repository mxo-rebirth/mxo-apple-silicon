#!/bin/bash
# One-command setup of The Matrix Online speed-up for CrossOver on Apple Silicon Macs:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mxo-rebirth/mxo-apple-silicon/main/install.sh)"
#
# It checks the Mac, installs the build tools with Homebrew if they are missing, downloads the source
# to ~/mxo-apple-silicon and runs scripts/setup.sh there, which asks before each step and changes only
# the bottle you choose. Running it again updates the source and repeats the setup.
#
# Arguments after the command go to scripts/setup.sh, for example:  ... install.sh)" --exe name.exe
#
# Environment:
#   MXO_DIR     where the source goes (default ~/mxo-apple-silicon)
#   MXO_SOURCE  the source archive to download (default: the main branch on GitHub)

set -euo pipefail

# After "bash -c" the first argument arrives as $0. Take it back when it is one of setup.sh's.
case "$0" in
  --?*|-y|-h|bottle|build|install|music|uninstall) set -- "$0" "$@" ;;
esac
if [ "${1:-}" = -- ]; then shift; fi

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

# Everything runs from this function, called on the last line, so a download that was cut short runs nothing.
main() {
  local dir=${MXO_DIR:-$HOME/mxo-apple-silicon}
  local source=${MXO_SOURCE:-https://github.com/mxo-rebirth/mxo-apple-silicon/archive/refs/heads/main.tar.gz}
  local guide=https://github.com/mxo-rebirth/mxo-apple-silicon/blob/main/docs/crossover.md
  local yes=0 a
  for a in "$@"; do case "$a" in --yes|-y) yes=1 ;; esac; done

  [ "$(uname -s)" = Darwin ] || die "this is for macOS"
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] \
    || die "this is for Apple Silicon Macs; an Intel Mac gains nothing from it"
  [ -x /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine ] \
    || die "CrossOver not found in /Applications. Install it and the game first: $guide"
  ls "$HOME/Library/Application Support/CrossOver/Bottles"/*/cxbottle.conf >/dev/null 2>&1 \
    || die "no CrossOver bottle found. Create one and install the game in it first: $guide"

  # Questions are answered at the keyboard, also when the script itself arrives on standard input
  # (curl | bash), where an unanswered question would otherwise count as yes.
  local input=/dev/stdin
  if [ $yes = 0 ] && [ ! -t 0 ]; then
    ( : < /dev/tty ) 2>/dev/null || die "no terminal to ask questions on; run it in Terminal, or add --yes"
    input=/dev/tty
  fi

  # Homebrew may be installed without being on this shell's PATH.
  local b
  if ! command -v brew >/dev/null; then
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [ -x "$b" ]; then eval "$("$b" shellenv)"; break; fi
    done
  fi
  local missing="" t
  for t in i686-w64-mingw32-g++ meson ninja glslangValidator; do
    command -v "$t" >/dev/null || missing="$missing $t"
  done
  if [ -n "$missing" ] && ! command -v brew >/dev/null; then
    die "Homebrew not found. The build tools come from it; install it from https://brew.sh and run this again."
  fi

  local fetch=1
  [ -d "$dir/.git" ] && fetch=0

  echo "The Matrix Online on Apple Silicon Macs"
  echo
  echo "This will:"
  if [ -n "$missing" ]; then
    echo "  - install the build tools with Homebrew: mingw-w64 meson ninja glslang"
  else
    echo "  - use the build tools that are already installed"
  fi
  if [ $fetch = 1 ]; then
    echo "  - download the source to $dir"
  else
    echo "  - use the git checkout in $dir as it is"
  fi
  echo "  - run its setup, which asks before each step and changes only the bottle you choose"
  if [ $yes = 0 ]; then
    local answer
    read -r -p "Continue? [Y/n] " answer < "$input" || die "no answer; nothing was changed"
    case "$answer" in n|N|no|No) echo "Nothing was changed."; exit 0 ;; esac
  fi

  if [ -n "$missing" ]; then
    say "Installing the build tools with Homebrew"
    brew install mingw-w64 meson ninja glslang
  fi

  if [ $fetch = 1 ]; then
    say "Downloading the source to $dir"
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/source.tar.gz" "$source" || die "could not download $source"
    mkdir "$tmp/source"
    tar -xzf "$tmp/source.tar.gz" -C "$tmp/source" --strip-components 1
    [ -f "$tmp/source/scripts/setup.sh" ] || die "the downloaded archive has no scripts/setup.sh"
    # Copied over an earlier download: its build folder, with the large downloads, stays.
    mkdir -p "$dir"
    cp -R "$tmp/source/." "$dir/"
    rm -rf "${tmp:?}"
  fi

  say "Running the setup"
  exec /bin/bash "$dir/scripts/setup.sh" "$@" < "$input"
}

main "$@"
