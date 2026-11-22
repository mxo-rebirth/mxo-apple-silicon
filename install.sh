#!/bin/bash
# One-command setup of The Matrix Online speed-up for CrossOver on Apple Silicon Macs:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mxo-rebirth/mxo-apple-silicon/main/install.sh)"
#
# It checks the Mac, installs the build tools with Homebrew if they are missing, downloads the source
# to ~/mxo-apple-silicon and runs scripts/setup.sh there, which asks its questions first and changes
# only the bottle you choose. Without a game in CrossOver yet, that setup can make the bottle and fetch
# the game and the launchers. Running it again updates the source and repeats the setup.
#
# Arguments after the command go to scripts/setup.sh, for example:  ... install.sh)" --exe name.exe
#
# Environment:
#   MXO_DIR     where the source goes (default ~/mxo-apple-silicon)
#   MXO_SOURCE  the source archive to download (default: the main branch on GitHub)

set -euo pipefail

# After "bash -c" the first argument arrives as $0. Take it back when it is one of setup.sh's.
case "$0" in
  --?*|-y|-h|game|bottle|build|install|detail|intro|icons|music|video|uninstall) set -- "$0" "$@" ;;
esac
if [ "${1:-}" = -- ]; then shift; fi

# The same look as scripts/setup.sh: green under a header of falling code on a terminal, else plain.
GRN="" BLD="" DIM="" RED="" OFF="" LINE="-" ASK="" GLYPHS=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  GRN=$'\033[32m' BLD=$'\033[1;32m' DIM=$'\033[2;32m' RED=$'\033[1;31m' OFF=$'\033[0m' LINE="|" ASK="? "
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) GLYPHS=1; LINE="│" ;; esac
fi

say() { printf '\n%s%s%s %s%s%s\n' "$GRN" "$([ $GLYPHS = 1 ] && echo "▓▒░" || echo "==")" "$OFF" "$BLD" "$*" "$OFF"; }
die() { printf '\n%serror:%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

rain() {   # rain WIDTH DENSITY: one row of the game's falling code, DENSITY cells in ten filled
  local g=(ｦ ｱ ｳ ｴ ｵ ｶ ｷ ｹ ｺ ｻ ｼ ｽ ｾ ｿ ﾀ ﾂ ﾃ ﾅ ﾆ ﾇ ﾈ ﾊ ﾋ ﾎ ﾏ ﾐ ﾑ ﾒ ﾓ ﾔ ﾕ ﾗ ﾘ ﾜ 0 1 2 3 4 5 6 7 8 9) row="" i
  for ((i = 0; i < $1; i++)); do
    if [ $((RANDOM % 10)) -lt "$2" ]; then row="$row${g[RANDOM % ${#g[@]}]}"; else row="$row "; fi
  done
  printf '%s' "$row"
}

# Everything runs from this function, called on the last line, so a download that was cut short runs nothing.
main() {
  local dir=${MXO_DIR:-$HOME/mxo-apple-silicon}
  local source=${MXO_SOURCE:-https://github.com/mxo-rebirth/mxo-apple-silicon/archive/refs/heads/main.tar.gz}
  local yes=0 a
  for a in "$@"; do case "$a" in --yes|-y) yes=1 ;; esac; done

  [ "$(uname -s)" = Darwin ] || die "this is for macOS"
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] \
    || die "this is for Apple Silicon Macs; an Intel Mac gains nothing from it"
  local macos
  macos=$(sw_vers -productVersion 2>/dev/null || true)
  case "${macos%%.*}" in ''|*[!0-9]*) die "cannot read the macOS version" ;; esac
  [ "${macos%%.*}" -ge 26 ] || die "macOS 26 or newer is needed; this Mac has macOS $macos"
  [ -x /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine ] \
    || die "CrossOver not found in /Applications. Install it first: https://www.codeweavers.com/crossover"

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

  if [ $GLYPHS = 1 ]; then
    printf '\n %s%s%s\n %s%s%s\n %s%s%s\n' "$DIM" "$(rain 56 2)" "$OFF" "$DIM" "$(rain 56 4)" "$OFF" "$GRN" "$(rain 56 6)" "$OFF"
    printf ' %sTHE MATRIX ONLINE%s  %ssetup for CrossOver on Apple Silicon%s\n\n' "$BLD" "$OFF" "$GRN" "$OFF"
  else
    echo "The Matrix Online on Apple Silicon Macs"
    echo
  fi
  local line="  $LINE"
  [ -n "$GRN" ] && line=" $DIM$LINE$OFF"
  echo "${GRN:+ }This will:"
  if [ -n "$missing" ]; then
    echo "$line install the build tools with Homebrew: mingw-w64 meson ninja glslang"
  else
    echo "$line use the build tools that are already installed"
  fi
  if [ $fetch = 1 ]; then
    echo "$line download the source to $dir"
  else
    echo "$line use the git checkout in $dir as it is"
  fi
  echo "$line run its setup, which asks its questions first and changes only the bottle you choose"
  echo
  echo "${GRN:+ }${BLD}Our advice:${OFF} install and play under a separate, standard (non-admin) user account"
  echo "${GRN:+ }on your computer, with your main account behind its own password. A game client"
  echo "${GRN:+ }then cannot reach your everyday files and logins."
  echo
  if [ $yes = 0 ]; then
    local answer
    read -r -p "${GRN:+ }$BLD$ASK${OFF}Continue? $DIM[Y/n]$OFF " answer < "$input" || die "no answer; nothing was changed"
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
    cp -Rp "$tmp/source/." "$dir/"   # with the files' dates, so that the setup rebuilds only after a change
    rm -rf "${tmp:?}"
  fi

  say "Running the setup"
  MXO_ADVISED=1 exec /bin/bash "$dir/scripts/setup.sh" "$@" < "$input"   # the advice was given above
}

main "$@"
