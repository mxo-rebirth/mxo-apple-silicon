#!/bin/bash
# One-command setup of The Matrix Online speed-up for CrossOver on Apple Silicon Macs:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mxo-rebirth/mxo-apple-silicon/main/install.sh)"
#
# It downloads the source to ~/mxo-apple-silicon and runs scripts/setup.sh there. The setup checks the
# Mac, asks its questions first and changes only the bottle you choose. Started from a copy of the
# repository, it runs that copy's setup and downloads nothing. Running it again updates the download.
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

TMP=""   # the folder a download is unpacked in, removed however the script ends
trap 'if [ -n "$TMP" ]; then rm -rf "${TMP:?}"; fi' EXIT

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

get_source() {   # get_source URL DIR: over an earlier download, whose build folder with the large downloads stays
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
    echo "Using the git checkout in $dir as it is."
  else
    echo "Downloading the setup to $dir"
    get_source "$source" "$dir"
  fi

  # Questions are answered at the keyboard, also when the script itself arrives on standard input
  # (curl | bash), where the setup would find no answer and stop.
  if [ ! -t 0 ] && ( : < /dev/tty ) 2>/dev/null; then input=/dev/tty; fi
  exec /bin/bash "$dir/scripts/setup.sh" "$@" < "$input"
}

main "$@"
