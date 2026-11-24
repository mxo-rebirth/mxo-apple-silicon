#!/bin/bash
# One-command setup of The Matrix Online speed-up for CrossOver on Apple Silicon Macs:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mxo-rebirth/mxo-apple-silicon/main/install.sh)"
#
# It clones the repository to ~/mxo-apple-silicon with git and runs scripts/setup.sh there. Running it
# again brings that clone up to date first. The setup checks the Mac, asks its questions first and
# changes only the bottle you choose.
#
# What it leaves as it is: the copy of the repository it is started from, a checkout it did not make,
# and a clone in which files were changed. Without git, and over an earlier download without git, the
# main branch is downloaded as an archive instead.
#
# Arguments after the command go to scripts/setup.sh, for example:  ... install.sh)" --exe name.exe
#
# Environment:
#   MXO_DIR     where the repository goes (default ~/mxo-apple-silicon)
#   MXO_REPO    the repository to clone (default: this project's on GitHub)
#   MXO_SOURCE  the archive to download where git cannot be used (default: the main branch on GitHub)

set -euo pipefail

# After "bash -c" the first argument arrives as $0. Take it back when it is one of setup.sh's.
case "$0" in
  --?*|-y|-h|game|bottle|build|install|detail|intro|icons|music|video|uninstall) set -- "$0" "$@" ;;
esac
if [ "${1:-}" = -- ]; then shift; fi

BRANCH=main
MARK=mxo.installer   # set in a clone this script made: only such a clone is brought up to date
export GIT_TERMINAL_PROMPT=0   # a repository that asks for a login fails at once

TMP=""   # the folder a download is unpacked in, removed however the script ends
trap 'if [ -n "$TMP" ]; then rm -rf "${TMP:?}"; fi' EXIT

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

have_git() {   # the git of macOS without the developer tools only opens a window that offers to install them
  local git
  git=$(command -v git) || return 1
  [ "$git" != /usr/bin/git ] || xcode-select -p >/dev/null 2>&1
}

is_empty() { [ ! -e "$1" ] || [ -z "$(ls -A "$1" 2>/dev/null)" ]; }

clone_source() {   # clone_source REPO DIR: the newest commit only
  git clone -q --depth 1 --branch "$BRANCH" "$1" "$2" || die "could not clone $1"
  git -C "$2" config "$MARK" true || die "could not mark the clone in $2"
}

update_source() {   # update_source DIR: git rewrites only the files that changed, so the setup rebuilds only after a change
  if [ "$(git -C "$1" config --get "$MARK" 2>/dev/null || true)" != true ]; then
    echo "Using the git checkout in $1 as it is."
  elif [ -n "$(git -C "$1" status --porcelain --untracked-files=no)" ]; then
    echo "Using $1 as it is: files in it were changed."
  elif git -C "$1" fetch -q --depth 1 origin "$BRANCH" 2>/dev/null; then
    git -C "$1" reset -q --hard FETCH_HEAD || die "could not bring $1 up to date"
  else
    echo "Could not reach the repository. Using $1 as it is."
  fi
}

download_source() {   # download_source URL DIR: over an earlier download, whose build folder with the large downloads stays
  TMP=$(mktemp -d) || die "could not make a temporary folder"
  curl -fsSL -o "$TMP/source.tar.gz" "$1" || die "could not download $1"
  mkdir "$TMP/source" || die "could not make a folder in $TMP"
  tar -xzf "$TMP/source.tar.gz" -C "$TMP/source" --strip-components 1 || die "could not unpack the download"
  [ -f "$TMP/source/scripts/setup.sh" ] || die "the downloaded archive has no scripts/setup.sh"
  mkdir -p "$2" || die "could not make $2"
  # with the files' dates, so that the setup rebuilds only after a change
  cp -Rp "$TMP/source/." "$2/" || die "could not copy the download to $2"
  rm -rf "${TMP:?}"
  TMP=""
}

main() {
  local dir=${MXO_DIR:-$HOME/mxo-apple-silicon}
  local repo=${MXO_REPO:-https://github.com/mxo-rebirth/mxo-apple-silicon.git}
  local source=${MXO_SOURCE:-https://github.com/mxo-rebirth/mxo-apple-silicon/archive/refs/heads/main.tar.gz}
  local here="" input=/dev/stdin

  [ "$(uname -s)" = Darwin ] || die "this is for macOS"
  # Through "bash -c" and on standard input the script has no path: BASH_SOURCE is empty there, and $0
  # is the shell or the first argument.
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    here=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || here=""
  fi
  if [ -n "$here" ] && [ -f "$here/install.sh" ] && [ -f "$here/scripts/setup.sh" ]; then
    dir=$here
  elif [ -d "$dir/.git" ]; then
    if have_git; then update_source "$dir"; else echo "Using the git checkout in $dir as it is."; fi
  elif have_git && is_empty "$dir"; then
    echo "Cloning the setup to $dir"
    clone_source "$repo" "$dir"
  else
    echo "Downloading the setup to $dir"
    download_source "$source" "$dir"
  fi

  # Questions are answered at the keyboard, also when the script itself arrives on standard input
  # (curl | bash), where the setup would find no answer and stop.
  if [ ! -t 0 ] && ( : < /dev/tty ) 2>/dev/null; then input=/dev/tty; fi
  exec /bin/bash "$dir/scripts/setup.sh" "$@" < "$input"
}

main "$@"
