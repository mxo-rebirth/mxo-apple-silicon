#!/bin/bash
# Guided setup of The Matrix Online in a CrossOver bottle, for any MxO install (Rejacked, Revived or
# another project's client). Run it from the repository folder:
#
#   scripts/setup.sh                      everything, after asking what it needs to know
#   scripts/setup.sh --yes                everything but the game step, no questions
#   scripts/setup.sh --bottle NAME step…  only the named steps, in the named bottle
#   scripts/setup.sh --fps 120 install    another frame-rate limit (default 90, 0 for none)
#
# Options:
#   --yes, -y      no questions: every default is taken, in the first bottle that has a game
#   --bottle NAME  the bottle to work in
#   --fps NUMBER   the frame-rate limit, 0 for none
#   --exe NAME     another client's game executable, if not matrix.exe or mxorev.exe. Repeatable
#   --dll FILE     install this d3d9.dll and build none
#
# Steps:
#   game       the game and the launchers. A run of every step takes it only for a bottle without
#              a game. It makes a missing bottle, gets the game from the MxOEmu project, a folder,
#              an archive or a direct link, offers CrossOver's icon for an MxOEmu launcher that
#              came with it, and downloads the Rejacked and Revived installers from the projects'
#              sites, checked against the checksums there. Rejacked's runs without its window,
#              Revived's needs your clicks
#   bottle     what the game needs to start: Microsoft's shader compiler, DirectMusic and DirectSound,
#              the music sound bank and a larger memory limit
#   build      build d3d9.dll from this bottle's client.dll. Asks before it installs missing
#              build tools, which only an administrator account can (docs/building.md)
#   install    install that d3d9.dll for the game executables, with the bottle settings it needs
#   detail     graphics settings: a lighter set for an M1 or M2, every option at its maximum, or an
#              experimental enhanced set past the menu's maximum.
#              Also the main display's resolution and 16x anisotropic filtering
#   intro      the game starts without its logo movies
#   music      Revived only: keep its starter from switching the game's music off
#   video      Revived only: switch off the rain animation (a video) behind its launcher's window,
#              which costs frame rate while the game runs
#   icons      CrossOver's icons for the launchers: CrossOver reads the bottle's shortcuts again,
#              and the Rejacked launcher's shortcut is made when the bottle has none
#   uninstall  the game executables go back to Wine's Direct3D 9 (DirectMusic stays, the game needs it)
#
# The script never looks for, prints or sends passwords, launcher logins or credential stores, and
# never prints command lines of running programs. It reads the settings files it edits. Every file it
# replaces is kept with a ".setup-backup" suffix.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPERS="$ROOT/scripts/setup-helpers.py"   # file edits and page readings
# shellcheck source=build-tools.sh
. "$ROOT/scripts/build-tools.sh"           # the build tools and their Homebrew packages
CX=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver
WINE="$CX/bin/wine"
BOTTLES=${CX_BOTTLE_PATH:-$HOME/Library/Application Support/CrossOver/Bottles}   # CrossOver's own variable
BOTTLES=${BOTTLES%%:*}
NEW_BOTTLE=MatrixOnline
CACHE="$HOME/Library/Caches/mxo-apple-silicon"
LOG="$CACHE/setup.log"   # what the spinners hide
MIN_MACOS=26
TESTED_MACOS=27          # the only version this was tried on

# folders on the bottle's drive C, and what counts as the game there
CLIENT_FOLDER=Games/MxO       # where the game step puts the game
DXVK_FOLDER=Games/dxvk        # the DLL's log, pipeline caches and settings file. The DLL looks for its flag files there
CLIENT_VERSION=7.6005
CLIENT_ARCHIVE_SIZE="1.3 GB"  # the full client as the projects offer it
CLIENT_MIN_KB=5000            # a client.dll is larger than this
CLIENT_DEPTH=4                # levels below drive C searched for a client.dll
UNPACK_NAME=.setup-unpack     # where the game step unpacks, inside the bottle's folder
MUSIC_GUARD=MxORevived-audio.txt

# Microsoft's DirectX redistributables, the same files winetricks uses
DX2010_URL="https://web.archive.org/web/20100205000000id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe"
DX2010_SHA=f6d191e89a963d7cca34f169d30f49eab99c1ed3bb92da73ec43617caaa1e93f
DX2006_URL="https://web.archive.org/web/20100920035904/https://download.microsoft.com/download/3/9/7/3972f80c-5711-4e14-9483-959d48a2d03b/directx_apr2006_redist.exe"
DX2006_SHA=dd8c3d401efe4561b67bd88475201b2f62f43cd23e4acc947bb34a659fa74952
HTTPS_ONLY=(--proto "=https" --proto-redir "=https")   # for every download, redirects included
PAGE_LIMIT=(--max-filesize 8000000)                # a web page or list the setup reads

DM_DLLS=(dmband dmcompos dmime dmloader dmscript dmstyle dmsynth dmusic dswave dsound)

# the projects' installer pages, each with a SHA-256, and Microsoft's .NET release list
REJACKED_PAGE=https://mxo-rejacked.com/download
REVIVED_PAGE=https://mxorevived.com/download.html
DOTNET_MAJOR=10   # the .NET Revived's launcher asks for
DOTNET_RELEASES=https://builds.dotnet.microsoft.com/dotnet/release-metadata/$DOTNET_MAJOR.0/releases.json
MXOEMU_PAGE=https://mxoemu.info/   # offers the full client
# the Rejacked launcher's Qt setting "game/install_dir"
REJACKED_KEY='HKCU\Software\Rejacked\Rejacked Launcher\game'
# Shortcut names as CrossOver lists them. The installers make Rejacked's and Revived's, the setup
# MxOEmu's, and Rejacked's when it is missing.
REJACKED_ICON="Rejacked Launcher"
REVIVED_ICON="MxO Revived"
MXOEMU_ICON="MxOEmu Launcher"

# The install step sets the first list, the answers and the detail step the second. Uninstall removes both.
SPEEDUP_ENV=(
  MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1
  "DXVK_LOG_PATH=C:/$DXVK_FOLDER"
  "DXVK_STATE_CACHE_PATH=C:/$DXVK_FOLDER"
  "DXVK_HUD=fps,frametimes,gpuload"   # hidden until Ctrl+Shift+F
)
SPEEDUP_ENV_BY_CHOICE=(DXVK_FRAME_RATE DXVK_MXO_RESPECT_ADDONS DXVK_CONFIG_FILE)
LARGE_ADDRESS_ENV=WINE_LARGE_ADDRESS_AWARE=1   # the game crashed after a minute without it. Stays after uninstall

YES=0
BOTTLE=""
DLL=""
EXTRA_EXES=()
FPS=90
FPS_GIVEN=0
STEPS=()

usage_error() { echo "$1 (see --help)" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --bottle|--dll|--exe|--fps) [ $# -ge 2 ] || usage_error "$1 needs a value" ;;
  esac
  case "$1" in
    --yes|-y) YES=1 ;;
    --bottle) BOTTLE=$2; shift ;;
    --dll) DLL=$2; shift ;;
    --exe)
      case "$2" in ''|*[\\/]*) usage_error "--exe takes the file name of a program, such as name.exe" ;; esac
      EXTRA_EXES+=("$2"); shift ;;
    --fps) FPS=$2; FPS_GIVEN=1; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    game|bottle|build|install|detail|intro|icons|music|video|uninstall) STEPS+=("$1") ;;
    *) usage_error "unknown argument: $1" ;;
  esac
  shift
done
case "$FPS" in ''|*[!0-9]*) usage_error "--fps takes a number, 0 for no limit" ;; esac

# --- look ---------------------------------------------------------------------------------------
# Piped, or with NO_COLOR set: plain lines without control codes. MXO_THEME=light or dark overrides the
# guess at the terminal's background.

FANCY=0; GLYPHS=0; COLS=80; WIDTH=76; IN_FRAME=0
ACC="" GRN="" DIM="" RED="" YEL="" OFF=""
SITE="" SITE_DIM=""   # the stats site's frame has the site's second colour
M_OK=" " M_NOTE=" " M_ASK=" " M_BAD=" " M_PICK=">" M_KEYS="up, down"
SPIN=('|' / - "\\")
RULE="" BAR_FULL="" BAR_EMPTY=""
WRAPPED=()
ROW_INK=""   # a row's text colour, which a note sets for its own row
SIDE="│"     # a frame's side, heavier in the last frame
ROW_LINES=1  # terminal lines the last row took
CHOICE=0
CHOICE_START=0   # the item a menu starts on, which Enter takes. Back to the first after each menu
ANSWER=""
JOB=""        # the background job a spinner waits for
LEFTOVERS=()  # temporary folders, removed however the setup ends
TMP=""

end_job() {   # end_job PID: ends the job and what it started. A background job ignores Ctrl-C
  local pid=$1 table child parent
  table=$(ps -axo pid=,ppid=) || table=""
  while read -r child parent; do
    if [ "$parent" = "$pid" ]; then end_job "$child"; fi
  done <<< "$table"
  kill "$pid" 2>/dev/null || true
}

on_exit() {   # however the setup ends: no job, no temporary folder, frame closed, cursor back
  local item job=$JOB
  set +e   # go on past a failing step, such as writing to a terminal that is gone
  if [ -n "$job" ]; then end_job "$job"; fi
  for item in "${LEFTOVERS[@]+"${LEFTOVERS[@]}"}"; do rm -rf "${item:?}"; done
  if [ $FANCY = 1 ]; then
    if [ -n "$job" ]; then printf '\r\033[K'; fi   # the spinner's line
    frame_close
    printf '\033[?25h'   # a spinner or a menu hides the cursor
  fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

light_background() {   # asks the terminal. No answer counts as dark
  local old reply rgb r g b
  ( : < /dev/tty ) 2>/dev/null || return 1
  old=$(stty -g < /dev/tty 2>/dev/null) || return 1
  stty -echo -icanon min 0 time 3 < /dev/tty
  printf '\033]11;?\007' > /dev/tty
  reply=$(dd bs=64 count=1 < /dev/tty 2>/dev/null) || reply=""
  stty "$old" < /dev/tty
  case "$reply" in *rgb:*) ;; *) return 1 ;; esac
  rgb=${reply#*rgb:}
  r=${rgb%%/*}; rgb=${rgb#*/}; g=${rgb%%/*}; b=${rgb#*/}
  r=${r:0:2}; g=${g:0:2}; b=${b:0:2}
  case "$r$g$b" in *[!0-9A-Fa-f]*) return 1 ;; esac
  [ ${#r}${#g}${#b} = 222 ] || return 1
  [ $(( (16#$r * 299 + 16#$g * 587 + 16#$b * 114) / 1000 )) -gt 140 ]
}

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  FANCY=1
  COLS=$( (stty size < /dev/tty) 2>/dev/null | cut -d' ' -f2) || COLS=80   # tput would ask the pipe, not the terminal
  case "$COLS" in ''|*[!0-9]*) COLS=80 ;; esac
  [ "$COLS" -ge 50 ] || COLS=80
  [ "$COLS" -ge 78 ] || WIDTH=$((COLS - 2))
  # the terminal's own green on a light background, the site's greens on a dark one
  ACC=$'\033[1;32m' GRN=$'\033[32m' DIM=$'\033[2;32m' RED=$'\033[1;31m' YEL=$'\033[1;33m' OFF=$'\033[0m'
  SITE=$'\033[1;34m' SITE_DIM=$'\033[34m'
  if [ "${MXO_THEME:-}" != light ] && [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ] \
    && { [ "${MXO_THEME:-}" = dark ] || ! light_background; }; then
    ACC=$'\033[1;38;5;84m' GRN=$'\033[38;5;41m' DIM=$'\033[38;5;35m'
    SITE=$'\033[1;38;5;75m' SITE_DIM=$'\033[38;5;68m'
    YEL=$'\033[1;38;5;214m'   # amber, apart from all the green
  fi
  M_OK="+" M_NOTE="!" M_ASK="?" M_BAD="x"
  probe="─"   # glyphs only where the shell counts characters, not bytes
  case "${#probe}${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in 1*[Uu][Tt][Ff]-8*|1*[Uu][Tt][Ff]8*)
    GLYPHS=1
    M_OK="✓" M_BAD="✗" M_PICK="❯" M_DOWN="↓" M_KEYS="↑ ↓"
    SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    while [ ${#RULE} -lt 160 ]; do RULE="${RULE}─"; BAR_FULL="${BAR_FULL}━"; BAR_EMPTY="${BAR_EMPTY}─"; done ;;
  esac
fi

frame_open() {
  local title rest
  title=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  rest=$((WIDTH - 5 - ${#title}))
  [ $rest -ge 1 ] || rest=1
  printf '%s┌%s─ %s%s %s%s┐%s\n' "$ACC" "$DIM" "$ACC" "$title" "$DIM" "${RULE:0:rest}" "$OFF"
  IN_FRAME=1
}

frame_close() {
  [ $IN_FRAME = 1 ] || return 0
  printf '%s└%s%s┘%s\n' "$DIM" "${RULE:0:WIDTH-2}" "$ACC" "$OFF"
  IN_FRAME=0
}

wrap() {   # wrap WIDTH TEXT: sets WRAPPED to the lines
  local width=$1 line="" word words
  WRAPPED=()
  read -ra words <<< "$2" || true
  for word in "${words[@]+"${words[@]}"}"; do
    while [ ${#word} -gt "$width" ]; do   # a long path or link breaks where the frame ends
      if [ -n "$line" ]; then WRAPPED+=("$line"); line=""; fi
      WRAPPED+=("${word:0:width}")
      word=${word:width}
    done
    if [ -z "$line" ]; then
      line=$word
    elif [ $(( ${#line} + 1 + ${#word} )) -le "$width" ]; then
      line="$line $word"
    else
      WRAPPED+=("$line")
      line=$word
    fi
  done
  if [ -n "$line" ]; then WRAPPED+=("$line"); fi
  [ ${#WRAPPED[@]} -gt 0 ] || WRAPPED=("")
}

# row MARK COLOUR TEXT [TAIL]: a line in the frame, TAIL at the right. Sets ROW_LINES for redraws in place.
row() {
  local mark=$1 colour=$2 text=$3 tail=${4:-} inner line first=1 width
  if [ $GLYPHS = 0 ]; then
    printf ' %s%s%s %s%s\n' "$colour" "$mark" "$OFF" "$ROW_INK$text${ROW_INK:+$OFF}" "${tail:+  $DIM$tail$OFF}"
    width=$((3 + ${#text}))
    [ -z "$tail" ] || width=$((width + 2 + ${#tail}))
    ROW_LINES=$(( (width + COLS - 1) / COLS ))
    return 0
  fi
  inner=$((WIDTH - 6))
  [ -z "$tail" ] || inner=$((inner - ${#tail} - 1))
  wrap "$inner" "$text"
  ROW_LINES=${#WRAPPED[@]}
  for line in "${WRAPPED[@]}"; do
    if [ $first = 1 ]; then
      printf '%s%s%s %s%s%s %s%*s%s %s%s%s\n' "$DIM" "$SIDE" "$OFF" "$colour" "$mark" "$OFF" \
        "$ROW_INK$line${ROW_INK:+$OFF}" $((inner - ${#line})) "" "${tail:+ $DIM$tail$OFF}" "$DIM" "$SIDE" "$OFF"
      first=0
    else
      printf '%s%s%s   %s%*s%s %s%s%s\n' "$DIM" "$SIDE" "$OFF" "$ROW_INK$line${ROW_INK:+$OFF}" $((inner - ${#line})) "" \
        "${tail:+ ${tail//?/ }}" "$DIM" "$SIDE" "$OFF"
    fi
  done
}

say() {
  if [ $GLYPHS = 1 ]; then
    frame_close
    echo
    frame_open "$1"
  else
    printf '\n%s==%s %s%s%s\n' "$GRN" "$OFF" "$ACC" "$1" "$OFF"
  fi
}

info() { row " " "" "$1"; }
ok()   { row "$M_OK" "$ACC" "$1" "${2:-}"; }
note() { local ROW_INK=$YEL; row "$M_NOTE" "$YEL" "$1"; }   # the whole line in amber, not only its mark
picked() { local ROW_INK=$ACC; row "$M_PICK" "$ACC" "$1"; }   # a menu's picked item, the whole line in colour
bad()  { row "$M_BAD" "$RED" "$1"; }

field() {   # field LABEL VALUE
  local inner=$((WIDTH - 14)) value=$2
  if [ $GLYPHS = 0 ]; then
    printf ' %s%-9s%s %s\n' "$DIM" "$1" "$OFF" "$value"
    return 0
  fi
  value=${value:0:inner}
  printf '%s│%s %s%-9s%s %s%*s %s│%s\n' "$DIM" "$OFF" "$GRN" "$1" "$OFF" "$value" $((inner - ${#value})) "" "$DIM" "$OFF"
}

die() {   # a job prints its error plain: the frame belongs to the setup itself
  if [ $IN_FRAME = 1 ] && [ "$BASH_SUBSHELL" = 0 ]; then
    bad "error: $*"
  elif [ "$BASH_SUBSHELL" = 0 ]; then
    printf '\n%serror:%s %s\n' "$RED" "$OFF" "$*" >&2
  else
    printf 'error: %s\n' "$*" >&2
  fi
  exit 1
}

lower() { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }   # plain letters only, so any bytes pass through

job_output() {   # where a failed job's output is: in the log behind a spinner, above when piped
  if [ $FANCY = 1 ]; then echo "Its output is in $LOG"; else echo "Its output is above"; fi
}

named() {   # named STEP: it was named on the command line
  local step
  for step in "${STEPS[@]+"${STEPS[@]}"}"; do
    if [ "$step" = "$1" ]; then return 0; fi
  done
  return 1
}

# python3 does the file edits and reads the download pages. Without Apple's command line developer
# tools, the python3 of macOS is a stand-in that only offers to install them.
python3_there() {
  local python
  python=$(command -v python3) || return 1
  [ "$python" = /usr/bin/python3 ] || return 0
  # after a macOS upgrade the tools' folder can be there without its programs
  xcode-select -p >/dev/null 2>&1 && python3 -I -c '' >/dev/null 2>&1
}

# Homebrew installs only from the account that installed it, an administrator account: another
# administrator can write its Cellar and still not its locks.
can_brew_install() {
  local prefix
  prefix=$(brew --prefix 2>/dev/null) || return 1
  if [ -e "$prefix/Cellar" ]; then [ -w "$prefix/Cellar" ] || return 1; else [ -w "$prefix" ] || return 1; fi
  [ ! -e "$prefix/var/homebrew/locks" ] || [ -w "$prefix/var/homebrew/locks" ]
}

find_brew() {   # Homebrew is not on every account's PATH
  local brew
  command -v brew >/dev/null && return 0
  for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$brew" ]; then eval "$("$brew" shellenv)"; return 0; fi
  done
  return 1
}

temp_dir() {   # sets TMP
  TMP=$(mktemp -d) || die "could not make a temporary folder"
  LEFTOVERS+=("$TMP")
}

CODE=(ｦ ｱ ｳ ｴ ｵ ｶ ｷ ｹ ｺ ｻ ｼ ｽ ｾ ｿ ﾀ ﾂ ﾃ ﾅ ﾆ ﾇ ﾈ ﾊ ﾋ ﾎ ﾏ ﾐ ﾑ ﾒ ﾓ ﾔ ﾕ ﾗ ﾘ ﾜ 0 1 2 3 4 5 6 7 8 9)   # the game's falling code

rain() {   # rain WIDTH DENSITY: a row of falling code, DENSITY cells in ten filled
  local row="" i
  for ((i = 0; i < $1; i++)); do
    if [ $((RANDOM % 10)) -lt "$2" ]; then row="$row${CODE[RANDOM % ${#CODE[@]}]}"; else row="$row "; fi
  done
  printf '%s' "$row"
}

# Letters traced from Miltown, a free typeface by Apostrophic Labs: blocks are strokes, thin lines streaks.
reveal() {   # reveal ROW…: block letters, 72 columns wide, come out of falling code
  local art=("$@") rows=$# code=() lit=() r i ch row mask colour last pos
  for ((r = 0; r < rows; r++)); do   # every row twice: as code, and in its final colours
    row="" mask="" last=""
    for ((i = 0; i < ${#art[r]}; i++)); do
      ch=${art[r]:i:1}
      case "$ch" in
        ' ') row="$row "; mask="$mask "; continue ;;
        ▔|─|▁) colour=$DIM ;;
        [A-Z]) colour=$GRN ;;
        *) colour=$ACC ;;
      esac
      if [ "$colour" != "$last" ]; then row="$row$OFF$colour"; last=$colour; fi
      row="$row$ch"
      mask="$mask${CODE[RANDOM % ${#CODE[@]}]}"
    done
    lit[r]="$row$OFF"
    code[r]=$mask
  done
  printf '\033[?25l'
  if [ -z "${MXO_NO_ANIMATION:-}" ]; then
    for ((pos = 0; pos < 72; pos += 4)); do   # resolved letters, two bright cells of code at the front, code ahead
      for ((r = 0; r < rows; r++)); do
        printf '  %s%s%s%s%s%s%s\033[K\n' "$GRN" "${art[r]:0:pos}" "$ACC" "${code[r]:pos:2}" "$DIM" "${code[r]:pos + 2}" "$OFF"
      done
      sleep 0.03
      printf '\033[%dA' "$rows"
    done
  fi
  for ((r = 0; r < rows; r++)); do printf '  %s\033[K\n' "${lit[r]}"; done
  printf '\033[?25h'
}

banner() {   # the opening words, one of them in big letters
  [ $FANCY = 1 ] || return 0
  echo
  if [ $GLYPHS = 1 ] && [ $WIDTH -ge 76 ]; then
    printf ' %s%s%s\n %s%s%s\n' "$DIM" "$(rain $((WIDTH - 2)) 2)" "$OFF" "$DIM" "$(rain $((WIDTH - 2)) 4)" "$OFF"
    printf '  %sW I T N E S S   T H E%s\n' "$GRN" "$OFF"
    reveal \
      '   ▄▄▄▄▖  ▔▔▔▜███▙▄   ▔▔▔▝▙▄▄▄▄    ─▄▞▘▔  ▗▄▄▄▖   ▄▄▄▄▖─▗▖▔▔▐█▘   ▄     ' \
      '   █  ▝▌     ▐█   ▝      ▗▌  ▗▟     █▌    ▐   █   ▘  █▌     ▐█    █     ' \
      '   █▄▄▛▘     ▐█▄▄▄▖      ▝▜█▀▀█     █▌    ▐▄▄▟▀      █▌     ▝█▛▀▀▀█     ' \
      '▔▔▔█ ▝█▄     ▐█          ▗█  ▗▟▘▔▔  █▌  ▔▔▜ ▝▜▙      █▌▔▔▔   █    █▔▔▔  ' \
      '   ▀─  ▀▀────▀▀▀▀▀▀▔▔▔▀───▛▀▀▀▘   ─▀▀▀─   ▝─  ▀▀────▐▛▀─    ▝▀▘  ▁█     ' \
      '                                               Y O U R S E L F  ▝▀▀     '
    echo
  else
    printf '  %sWitness the rebirth yourself.%s\n' "$ACC" "$OFF"
  fi
  printf '  %sThe Matrix Online%s  %ssetup for CrossOver on Apple Silicon%s\n' "$GRN" "$OFF" "$DIM" "$OFF"
}

SITE_SHOWN=0
site_frame() {   # the stats site under its logo, in its blue. The first line is typed only once
  local blink=$'\033[5m' knock="Knock, knock." i ch
  [ -z "${MXO_NO_ANIMATION:-}" ] || blink=""
  if [ $GLYPHS = 1 ]; then frame_close; fi
  local ACC=$SITE DIM=$SITE_DIM   # for this frame only: what is called from here draws in them
  if [ $GLYPHS = 1 ]; then
    echo
    printf '%s┌%s─ %sMXO%s//%sSERVER STATS%s_%s %s%s┐%s\n' "$ACC" "$DIM" "$ACC" "$DIM" "$ACC" "$blink" "$OFF" \
      "$DIM" "${RULE:0:WIDTH - 23}" "$OFF"
    IN_FRAME=1
  else
    say "MXO//SERVER STATS"
  fi
  if [ $FANCY = 1 ]; then
    if [ $GLYPHS = 1 ] && [ $SITE_SHOWN = 0 ] && [ -z "${MXO_NO_ANIMATION:-}" ]; then
      # the row's right edge first, then back to where the text starts
      printf '%s│%s%*s%s│%s\r\033[4C%s' "$DIM" "$OFF" $((WIDTH - 2)) "" "$DIM" "$OFF" "$ACC"
      sleep 0.3
      for ((i = 0; i < ${#knock}; i++)); do
        ch=${knock:i:1}
        printf '%s' "$ch"
        case "$ch" in ,) sleep 0.4 ;; ' ') ;; *) sleep 0.06 ;; esac
      done
      sleep 0.3
      printf '%s\n' "$OFF"
    else
      local ROW_INK=$ACC
      info "$knock"
      ROW_INK=""
    fi
  fi
  SITE_SHOWN=1
  info "Who is jacked in on The Matrix Online community servers: https://whoisjackedin.com"
  if [ $GLYPHS = 1 ]; then frame_close; fi
}

clock() { printf '%d:%02d' $(( (SECONDS - $1) / 60 )) $(( (SECONDS - $1) % 60 )); }
mb()    { printf '%d.%d' $(( $1 / 1048576 )) $(( $1 % 1048576 * 10 / 1048576 )); }

moving() {   # moving TICK TEXT TAIL: the line a spinner redraws in place
  local text=$2 tail=$3 inner
  if [ $GLYPHS = 1 ]; then
    inner=$((WIDTH - 7 - ${#tail}))
    text=${text:0:inner}
    printf '\r%s│%s %s%s%s %s%*s %s%s%s %s│%s' "$DIM" "$OFF" "$GRN" "${SPIN[$1 % ${#SPIN[@]}]}" "$OFF" "$text" \
      $((inner - ${#text})) "" "$DIM" "$tail" "$OFF" "$DIM" "$OFF"
  else
    printf '\r %s%s%s %s  %s%s%s\033[K' "$GRN" "${SPIN[$1 % ${#SPIN[@]}]}" "$OFF" "${text:0:WIDTH-16}" "$DIM" "$tail" "$OFF"
  fi
}

spin() {   # spin TITLE COMMAND…: a spinner while the command works, its output in the log
  local title=$1 start=$SECONDS rc=0 i=0 from stage="" line
  shift
  if [ $FANCY = 0 ]; then
    info "$title"
    ( "$@" ) </dev/null || rc=$?
    return $rc
  fi
  mkdir -p "$CACHE" || die "could not make $CACHE"
  printf '\n-- %s\n' "$title" >> "$LOG"
  from=$(( $(wc -c < "$LOG") + 1 ))
  ( "$@" ) >> "$LOG" 2>&1 </dev/null &
  JOB=$!
  printf '\033[?25l'
  while kill -0 "$JOB" 2>/dev/null; do
    # a long job names its stages on lines that start with "=="
    if [ $((i % 12)) = 0 ]; then
      stage=$(tail -c +"$from" "$LOG" 2>/dev/null | grep '^== ' | tail -1 | cut -c4- || true)
    fi
    moving "$i" "$title${stage:+ · $stage}" "$(clock "$start")"
    i=$((i + 1))
    sleep 0.08
  done
  wait "$JOB" || rc=$?
  JOB=""
  printf '\r\033[K\033[?25h'
  if [ $rc = 0 ]; then
    ok "$title" "$(clock "$start")"
  else
    bad "$title"
    tail -n 12 "$LOG" | while IFS= read -r line; do info "$line"; done
  fi
  return $rc
}

fetch_file() {   # fetch_file URL OUT TITLE [resume]: with a progress bar, returns curl's status
  local url=$1 out=$2 title=$3 resume=${4:-} rc=0 total have pct fill width tail i=0 rows=0
  if [ $FANCY = 0 ]; then
    info "$title"
    curl "${HTTPS_ONLY[@]}" -L --fail -sS ${resume:+-C -} -o "$out" "$url" || rc=$?
    return $rc
  fi
  mkdir -p "$CACHE" || die "could not make $CACHE"
  total=$(curl "${HTTPS_ONLY[@]}" -sIL --max-time 20 "$url" 2>/dev/null | tr -d '\r' \
    | awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }') || total=0
  if [ $GLYPHS = 1 ]; then
    row "$M_DOWN" "$GRN" "$title"
    rows=$ROW_LINES
  fi
  curl "${HTTPS_ONLY[@]}" -L --fail -sS ${resume:+-C -} -o "$out" "$url" 2>> "$LOG" &
  JOB=$!
  printf '\033[?25l'
  while kill -0 "$JOB" 2>/dev/null; do
    have=$(stat -f %z "$out" 2>/dev/null || echo 0)
    if [ "$total" -gt 0 ] && [ $GLYPHS = 1 ]; then
      tail="$(mb "$have") / $(mb "$total") MB"
      width=$((WIDTH - 13 - ${#tail}))
      pct=$(( have * 100 / total )); [ $pct -le 100 ] || pct=100
      fill=$(( pct * width / 100 ))
      printf '\r%s│%s %s%s%s %s%s%s%s%s %3d%%  %s%s%s %s│%s' "$DIM" "$OFF" "$GRN" "${SPIN[i % ${#SPIN[@]}]}" "$OFF" \
        "$ACC" "${BAR_FULL:0:fill}" "$DIM" "${BAR_EMPTY:0:width-fill}" "$OFF" "$pct" "$DIM" "$tail" "$OFF" "$DIM" "$OFF"
    else
      moving "$i" "$([ $GLYPHS = 1 ] || printf '%s' "$title")" "$(mb "$have") MB"
    fi
    i=$((i + 1))
    sleep 0.1
  done
  wait "$JOB" || rc=$?
  JOB=""
  printf '\r\033[K\033[?25h'
  if [ "$rows" -gt 0 ]; then printf '\033[%dA\033[J' "$rows"; fi   # the result takes the title line's place
  if [ $rc = 0 ]; then ok "$title" "$(mb "$(stat -f %z "$out")") MB"; else bad "$title"; fi
  return $rc
}

choose_by_number() {   # the menu as plain lines. Enter takes the item the menu starts on
  local n=$# i key
  for ((i = 1; i <= n; i++)); do printf '  %d) %s\n' "$i" "${!i}"; done
  while :; do
    read -r -p "   Number [$((CHOICE + 1))]: " key || [ -n "$key" ] || die "no answer"   # a last line without its newline is an answer too
    case "$key" in
      '') return 0 ;;
      *[!0-9]*) ;;
      *) if [ $((10#$key)) -ge 1 ] && [ $((10#$key)) -le "$n" ]; then CHOICE=$((10#$key - 1)); return 0; fi ;;
    esac
  done
}

choose() {   # choose ITEM…: sets CHOICE to the picked item's index. Starts on item CHOICE_START
  local n=$# i key rest lines
  local items=("$@")
  CHOICE=$CHOICE_START
  CHOICE_START=0
  if [ $FANCY = 0 ]; then choose_by_number "$@"; return 0; fi
  printf '\033[?25l'
  while :; do
    lines=0
    # numbered, and the picked one in colour: plainly a list to move through
    for ((i = 0; i < n; i++)); do
      if [ $i = "$CHOICE" ]; then picked "$((i + 1)). ${items[i]}"; else row " " "" "$((i + 1)). ${items[i]}"; fi
      lines=$((lines + ROW_LINES))
    done
    row " " "" "" "$M_KEYS or 1-$((n < 9 ? n : 9)) to choose, Enter to confirm"   # one key each, so up to 9
    lines=$((lines + ROW_LINES))
    IFS= read -rsn1 key || { printf '\033[?25h'; die "no answer"; }
    case "$key" in
      $'\033')
        rest=""
        IFS= read -rsn2 -t 1 rest || true
        case "$rest" in
          '[A') CHOICE=$(( (CHOICE + n - 1) % n )) ;;
          '[B') CHOICE=$(( (CHOICE + 1) % n )) ;;
        esac ;;
      k) CHOICE=$(( (CHOICE + n - 1) % n )) ;;
      j) CHOICE=$(( (CHOICE + 1) % n )) ;;
      [1-9]) if [ "$key" -le "$n" ]; then CHOICE=$((key - 1)); fi ;;
      '') break ;;
    esac
    printf '\033[%dA' "$lines"
  done
  printf '\033[%dA\033[J\033[?25h' "$lines"   # the list goes and the caller says what was picked
}

ask_in_frame() {   # ask_in_frame QUESTION HINT: leaves the cursor where the answer goes
  local hint=$2 i n last
  wrap $((WIDTH - 18)) "$1"
  n=${#WRAPPED[@]}
  last=${WRAPPED[n - 1]}
  for ((i = 0; i < n - 1; i++)); do
    printf '%s│%s %s%s%s %s%*s %s│%s\n' "$DIM" "$OFF" "$ACC" "$([ $i = 0 ] && echo "$M_ASK" || echo " ")" "$OFF" \
      "${WRAPPED[i]}" $((WIDTH - 6 - ${#WRAPPED[i]})) "" "$DIM" "$OFF"
  done
  # the frame's edge first, then back to where the answer goes
  printf '%s│%s %s%s%s %s %s%s%s%*s%s│%s\r\033[%dC' "$DIM" "$OFF" "$ACC" "$([ "$n" = 1 ] && echo "$M_ASK" || echo " ")" "$OFF" \
    "$last" "$DIM" "$hint" "$OFF" $((WIDTH - 11 - ${#last})) "" "$DIM" "$OFF" $((${#last} + 11))
}

# ask QUESTION [yes|no]: 0 for yes. Enter and --yes take the default, yes unless "no" is given.
ask() {
  local default=${2:-yes} hint="[Y/n]" answer
  [ "$default" = yes ] || hint="[y/N]"
  while :; do
    if [ $YES = 1 ]; then
      answer=""   # --yes answers like Enter
    elif [ $GLYPHS = 1 ]; then
      ask_in_frame "$1" "$hint"
      read -r answer || [ -n "$answer" ] || die "no answer"   # end of input is not a yes
    else
      read -r -p " $ACC$M_ASK$OFF $1 $DIM$hint$OFF " answer || [ -n "$answer" ] || die "no answer"
    fi
    case "$(lower "$answer")" in
      n|no) return 1 ;;
      y|yes) return 0 ;;
      '') if [ "$default" = yes ]; then return 0; else return 1; fi ;;
    esac
  done
}

ask_text() {   # ask_text QUESTION: sets ANSWER to the line typed
  if [ $GLYPHS = 1 ]; then
    row "$M_ASK" "$ACC" "$1"
    printf '%s│%s %s%s%s ' "$DIM" "$OFF" "$ACC" "$M_PICK" "$OFF"
    read -r ANSWER || [ -n "$ANSWER" ] || die "no answer"
  else
    read -r -p " $ACC$M_ASK$OFF $1 " ANSWER || [ -n "$ANSWER" ] || die "no answer"
  fi
}

banner
site_frame

# --- the Mac ------------------------------------------------------------------------------------

say "System"
[ "$(uname -s)" = Darwin ] || die "this is for macOS"
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] \
  || die "this is for Apple Silicon Macs. An Intel Mac gains nothing from it"
ok "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")"
MACOS=$(sw_vers -productVersion 2>/dev/null || true)
case "${MACOS%%.*}" in ''|*[!0-9]*) die "cannot read the macOS version" ;; esac
[ "${MACOS%%.*}" -ge $MIN_MACOS ] || die "macOS $MIN_MACOS or newer is needed. This Mac has macOS $MACOS"
ok "macOS $MACOS"
[ "${MACOS%%.*}" -ge $TESTED_MACOS ] || note "tried on macOS $TESTED_MACOS only"
[ -x "$WINE" ] || die "CrossOver not found in /Applications. Install it first: https://www.codeweavers.com/crossover"
ok "CrossOver $(defaults read "${CX%/SharedSupport/*}/Info" CFBundleShortVersionString 2>/dev/null || true)"

# Homebrew and the tools the speed-up is built with: checked here, before anything is downloaded or
# changed. BUILD_AHEAD is 1 when this run surely builds. With a DLL from an earlier build, a run of
# every step builds again only if the sources or the game are newer: that shows once the bottle is
# known, and is settled with the other questions, before any step.
find_brew || true
python3_there || die "Apple's command line developer tools are missing, and the setup needs them. Install Homebrew first, which brings them along (https://brew.sh), then run this again"
BUILD_AHEAD=0
if [ -z "$DLL" ] && { named build || { [ ${#STEPS[@]} = 0 ] && [ ! -f "$ROOT/build/d3d9.dll" ]; }; }; then BUILD_AHEAD=1; fi
TOOLS_MISSING=$(missing_build_tools)
if command -v brew >/dev/null; then
  ok "Homebrew"
elif [ $BUILD_AHEAD = 1 ] && [ -n "$TOOLS_MISSING" ]; then
  die "Homebrew is missing, and the tools that build the speed-up come from it. Install it first (https://brew.sh), then run this again"
else
  note "Homebrew: not found. This run does not need it"
fi
if [ -z "$TOOLS_MISSING" ]; then
  ok "build tools (${BREW_PACKAGES[*]})"
elif [ $BUILD_AHEAD = 0 ]; then
  note "build tools: not all there. They are needed only if the speed-up has to be built"
elif can_brew_install; then
  note "build tools: not installed yet (${BREW_PACKAGES[*]}). The setup asks before it installs them"
else
  die "the build tools are missing, and this account cannot install them: Homebrew installs only from the account that installed it, an administrator account. Run this there, then run the setup here again: $(brew_command)"
fi

# The CrossOver app shows a bottle's new icons only after it starts again. Its window, in this account
# only: the programs in the bottles run on without it.
# crossover_pid [all]: the app's process number in this account, or in any account, or nothing. The
# path can differ from the one in /Applications: macOS runs a freshly downloaded app from a folder
# of its own. "ww": ps cuts its lines to the terminal's width otherwise.
crossover_pid() {
  local pid program
  while read -r pid program; do
    case "$program" in
      */CrossOver.app/Contents/MacOS/CrossOver) printf '%s' "$pid"; return 0 ;;
    esac
  done < <(ps -x${1:+a}wwo pid=,comm=)
}

crossover_open() { [ -n "$(crossover_pid)" ]; }

crossover_gone() {   # crossover_gone SECONDS: waits that long for the app to close
  local tick
  for ((tick = 0; tick < $1 * 2; tick++)); do
    crossover_open || return 0
    sleep 0.5
  done
  ! crossover_open
}

# The ordinary way to quit an app. The first time, macOS asks whether the terminal may control
# CrossOver, and the request waits for that answer.
ask_crossover_to_quit() {
  osascript -e 'with timeout of 30 seconds' -e 'tell application id "com.codeweavers.CrossOver" to quit' \
    -e 'end timeout' >/dev/null 2>&1 || true
}

CROSSOVER_CLOSED=0
quit_crossover() {   # asks first. With --yes it stays open: an app is not closed unasked
  local pid
  if ! crossover_open; then
    # in another account of this Mac it shows that account's bottles and can stay
    if [ -n "$(crossover_pid all)" ]; then info "CrossOver is open in another account of this Mac. It is left alone."; fi
    return 0
  fi
  if [ $YES = 1 ] || ! ask "CrossOver is open. Quit it now? It shows new icons only after it starts again."; then
    note "CrossOver stays open. Quit and open it again when the setup is done, to see new icons"
    return 0
  fi
  info "If macOS asks whether the terminal may control CrossOver, either answer is fine."
  spin "Quitting CrossOver" ask_crossover_to_quit || true
  # a window of its own or a refused request can keep it open
  if ! crossover_gone 5 && ask "CrossOver has not closed. End it now? Anything it is doing in another bottle is cut off."; then
    pid=$(crossover_pid)
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  fi
  if crossover_gone 5; then
    ok "CrossOver closed"
    CROSSOVER_CLOSED=1
  else
    note "CrossOver is still open. Quit it with Cmd+Q and open it again when the setup is done"
  fi
}
# Said before anything is installed: in a full run and with the game step.
if [ ${#STEPS[@]} = 0 ] || named game; then
  say "Before you start"
  note "This setup is independent: it is not connected to any server project. It cannot promise that their game files, launchers or downloads are safe, and takes no responsibility for damage they cause. You install them at your own risk."
  note "Our advice: install and play under a separate, standard (non-admin) user account on your computer, with your main account behind its own password."
  info "A game client then cannot reach your everyday files and logins."
  case " $(id -Gn 2>/dev/null || true) " in
    *" admin "*)
      info "This account is an administrator account."
      if [ -n "$TOOLS_MISSING" ] && command -v brew >/dev/null; then
        info "A standard account cannot install the build tools. For one, install them from the account that installed Homebrew first: $(brew_command)"
      fi ;;
    *) ok "This account is a standard account." ;;
  esac
fi
if [ $FANCY = 1 ]; then
  mkdir -p "$CACHE" || die "could not make $CACHE"
  : > "$LOG"
fi

# --- bottle -------------------------------------------------------------------------------------

wants_game() {   # only the game step may make a bottle, and --yes leaves it out unless named
  named game || { [ ${#STEPS[@]} = 0 ] && [ $YES = 0 ]; }
}

# find_clients FOLDER DEPTH: sorted folders with the game's client.dll. Skips temporary and unreadable ones
find_clients() {
  local file dir
  while IFS= read -r file; do
    dir=$(dirname "$file")
    case "${dir#"$1"}/" in */Temp/*|*/temp/*|*/"$UNPACK_NAME"/*) continue ;; esac
    printf '%s\n' "$dir"
  done < <(find "$1" -maxdepth "$2" -iname client.dll -size +"${CLIENT_MIN_KB}k" 2>/dev/null | sort)
}

first_client() {   # first_client FOLDER DEPTH: the first of those folders, or nothing
  local dir=""
  IFS= read -r dir < <(find_clients "$1" "$2") || true
  printf '%s' "$dir"
}

has_game() { [ -n "$(first_client "$1/drive_c" "$CLIENT_DEPTH")" ]; }

create_bottle() {
  # as the CrossOver app makes one: MSync on, and icons for installed programs
  spin "Creating the bottle $1 (Windows 10 64-bit)" \
    "$CX/bin/cxbottle" --bottle "$1" --create --template win10_64 --description "The Matrix Online" \
    --param "EnvironmentVariables:WINEMSYNC=1" --param "Bottle:MenuMode=install" \
    --param "Bottle:AssocMode=install" || die "CrossOver could not create the bottle"
  [ -f "$BOTTLES/$1/cxbottle.conf" ] || die "CrossOver could not create the bottle"
  BOTTLE=$1
}

pick_bottle() {
  if [ -n "$BOTTLE" ]; then
    [ -f "$BOTTLES/$BOTTLE/cxbottle.conf" ] && return
    if ! wants_game || ! ask "No bottle called $BOTTLE yet. Create it?"; then die "no bottle called $BOTTLE"; fi
    create_bottle "$BOTTLE"
    return
  fi
  local list=() d
  for d in "$BOTTLES"/*/; do
    if [ -f "$d/cxbottle.conf" ]; then list+=("$(basename "$d")"); fi
  done
  if [ ${#list[@]} = 0 ]; then
    wants_game || die "no CrossOver bottles found. The game step makes one: scripts/setup.sh game"
    ask "No CrossOver bottle yet. Create one called $NEW_BOTTLE for the game?" || die "no bottle to work in"
    create_bottle "$NEW_BOTTLE"
    return
  fi
  # What Enter and --yes take: a bottle that has the game, or else the bottle of this setup's own
  # name, there or new. Never a bottle made for something else.
  local items=("${list[@]}") new=0 i start=-1
  if wants_game && [ ! -e "$BOTTLES/$NEW_BOTTLE" ]; then
    new=1
    items+=("a new bottle called $NEW_BOTTLE")
    start=${#list[@]}
  fi
  for ((i = ${#list[@]} - 1; i >= 0; i--)); do
    if [ "${list[i]}" = "$NEW_BOTTLE" ] && [ "$start" -lt 0 ]; then start=$i; fi
  done
  for ((i = ${#list[@]} - 1; i >= 0; i--)); do
    if has_game "$BOTTLES/${list[i]}"; then start=$i; fi
  done
  if [ $YES = 1 ]; then
    if [ "$start" -lt 0 ] || { ! wants_game && ! has_game "$BOTTLES/${list[start]}"; }; then
      die "no bottle has a game in it. Name the bottle to work in: --bottle NAME"
    fi
    CHOICE=$start
  elif [ ${#list[@]} = 1 ] && { ! wants_game || has_game "$BOTTLES/${list[0]}"; }; then
    CHOICE=0
  else
    [ "$start" -lt 0 ] || CHOICE_START=$start
    choose "${items[@]}"
  fi
  if [ $new = 1 ] && [ "$CHOICE" = ${#list[@]} ]; then
    create_bottle "$NEW_BOTTLE"
    return
  fi
  BOTTLE=${list[CHOICE]}
}

say "Bottle"
pick_bottle
BOTTLE_DIR="$BOTTLES/$BOTTLE"
CONF="$BOTTLE_DIR/cxbottle.conf"   # the bottle's settings
DRIVE="$BOTTLE_DIR/drive_c"
SYS="$DRIVE/windows/syswow64"
DXVK_DIR="$DRIVE/$DXVK_FOLDER"
temp_dir
WINE_SAID="$TMP/wine-said.txt"     # Wine's output from the last registry write
field bottle "$BOTTLE"

win_path() {   # win_path FILE: a file on drive C the way Windows writes it
  local path=${1#"$DRIVE"}
  printf 'C:%s' "${path//\//\\}"
}

helper() { python3 -I "$HELPERS" "$@"; }

edit() {   # edit WHAT COMMAND…: a file edit by the helper, whose own words go into the error
  local what=$1 said
  shift
  said=$(helper "$@" 2>&1) || die "could not change $what: $said"
}

# reg_write KEY NAME VALUE: Wine's output goes to a file and is shown on failure. A pipe would keep the
# setup waiting for as long as Wine's services run.
reg_write() {
  if "$WINE" --bottle "$BOTTLE" -- reg add "$1" /v "$2" /d "$3" /f > "$WINE_SAID" 2>&1; then return 0; fi
  cat "$WINE_SAID"
  return 1
}

reg_add() { reg_write "$@" || die "registry write failed: $1 $2"; }
reg_del() { "$WINE" --bottle "$BOTTLE" -- reg delete "$1" /v "$2" /f >/dev/null 2>&1 || true; }   # the value may not be there

# running PROGRAM…: one of these Windows programs runs, in any bottle. ps is read whole first: grep -q
# on a pipe can end it early, which pipefail takes for a failure.
running() {
  local programs name
  programs=$(ps -axwwo comm= | LC_ALL=C tr '[:upper:]' '[:lower:]') || die "could not list the running programs"
  programs=$'\n'"$programs"$'\n'
  for name in "$@"; do
    name=$(lower "$name")
    case "$programs" in
      *"\\$name"$'\n'*|*"/$name"$'\n'*|*$'\n'"$name"$'\n'*) return 0 ;;
    esac
  done
  return 1
}

game_running() { running "${EXES[@]}"; }

need_game_closed() {   # need_game_closed [WHY]: before replacing files the game has open or writes itself
  if game_running; then die "close the game first${1:+. $1}"; fi
}

need_game() {   # for a step that works on the game's own files
  [ ${#INSTALLS[@]} -gt 0 ] || die "no game in this bottle (no folder with client.dll). The game step gets one: scripts/setup.sh game"
}

is_wine_builtin() {   # Wine marks its own DLLs with this text in the DOS header
  [ -f "$1" ] && [ "$(dd if="$1" bs=1 skip=64 count=16 2>/dev/null)" = "Wine builtin DLL" ]
}

copy_whole() {   # copy_whole SOURCE TARGET: the target is there whole or not at all
  rm -f "${2:?}.new" || die "could not remove $2.new"   # a leftover, or a link that would be written through
  cp "$1" "$2.new" || { rm -f "${2:?}.new"; die "could not copy $(basename "$1") to $2"; }
  mv "$2.new" "$2" || die "could not put $2 in place"
}

backup_once() {   # the first copy stays: the file as it was before the setup
  if [ -f "$1" ] && [ ! -f "$1.setup-backup" ]; then copy_whole "$1" "$1.setup-backup"; fi
}

put_file() {   # put_file SOURCE TARGET: keeps the bottle file it replaces
  backup_once "$2"
  copy_whole "$1" "$2"
}

bottle_env() {   # bottle_env NAME: its value in the bottle's settings, or nothing
  helper get-env "$CONF" "$1" 2>/dev/null || true
}

set_env() {   # set_env NAME=VALUE…: in cxbottle.conf, [EnvironmentVariables]
  backup_once "$CONF"
  edit "the bottle's settings (cxbottle.conf)" set-env "$CONF" "$@"
}

unset_env() {   # unset_env NAME…
  backup_once "$CONF"
  edit "the bottle's settings (cxbottle.conf)" unset-env "$CONF" "$@"
}

# --- the game installs in this bottle ----------------------------------------------------------

INSTALLS=()        # folders that hold a client.dll
EXES=()            # the game executables the bottle's settings are made for
REVIVED=""         # Revived's folder, when Revived is installed
INSTALLER=""       # set by fetch_installer
CLIENT_SOURCE=""   # set by client_source
CLIENT_ARCHIVE=""  # set by download_client
STAGED_CLIENT=""   # set by stage_client

find_installs() {
  INSTALLS=(); EXES=(matrix.exe); REVIVED=""
  local d
  while IFS= read -r d; do
    INSTALLS+=("$d")
    if [ -f "$d/MxORevived-Launcher.exe" ]; then
      [ -n "$REVIVED" ] || EXES+=(mxorev.exe)
      REVIVED=$d
    fi
  done < <(find_clients "$DRIVE" "$CLIENT_DEPTH")
  EXES+=("${EXTRA_EXES[@]+"${EXTRA_EXES[@]}"}")
}

show_installs() {
  local d
  if [ ${#INSTALLS[@]} = 0 ]; then
    field game "none in this bottle yet (no folder with client.dll)"
  else
    for d in "${INSTALLS[@]}"; do field game "$(win_path "$d")"; done
  fi
  field programs "${EXES[*]}"
}

client_dir() {   # the first game folder that is not Revived's own copy
  local d
  for d in "${INSTALLS[@]+"${INSTALLS[@]}"}"; do
    if [ "$d" != "$REVIVED" ]; then echo "$d"; return; fi
  done
}

find_installs
show_installs

# The install step leaves DXVK_LOG_PATH. The player chose that bottle's settings, so they are the defaults.
SPEEDUP_BEFORE=0
if [ -n "$(bottle_env DXVK_LOG_PATH)" ]; then SPEEDUP_BEFORE=1; fi

# A step named on the command line works on a game. Without this, a lone bottle made for something
# else would be taken without a question and changed. Only the game step may start from nothing,
# and uninstall still has its work where the speed-up was installed and the game deleted since.
if [ ${#STEPS[@]} -gt 0 ] && ! named game && [ ${#INSTALLS[@]} = 0 ] \
  && ! { [ "${STEPS[*]}" = uninstall ] && [ $SPEEDUP_BEFORE = 1 ]; }; then
  die "no game in the bottle $BOTTLE (no folder with client.dll), so nothing was changed. Name the game's bottle with --bottle NAME, or get the game first: scripts/setup.sh game"
fi

# The folder of DXVK's log, shader cache and settings. mkdir cannot make it through a link whose folder is gone.
if [ -L "$DXVK_DIR" ] && [ ! -e "$DXVK_DIR" ] && { [ ${#STEPS[@]} = 0 ] || named install || named detail; }; then
  die "$DXVK_DIR is a link to a folder that is gone ($(readlink "$DXVK_DIR")), so nothing was changed. Make that folder again or delete the link, then run this again."
fi

# only where icons can change: a run of every step, the game step and the icons step
if [ ${#STEPS[@]} = 0 ] || named game || named icons; then quit_crossover; fi

# --- steps --------------------------------------------------------------------------------------

checksum() {   # checksum FILE EXPECTED: SHA-512 when the expected one has 128 digits, else SHA-256
  local bits=256
  [ ${#2} = 128 ] && bits=512
  shasum -a $bits "$1" | cut -d' ' -f1
}

download() {   # download URL CHECKSUM FILE FROM: into the cache, unless it is there already
  mkdir -p "$CACHE" || die "could not make $CACHE"
  local out="$CACHE/$3"
  if [ -f "$out" ] && [ "$(checksum "$out" "$2")" = "$2" ]; then return 0; fi
  fetch_file "$1" "$out.part" "Downloading $3 from $4" || die "$3: download failed"
  [ "$(checksum "$out.part" "$2")" = "$2" ] || { rm -f "${out:?}.part"; die "$3: the download is not the file its publisher published (the checksum does not match)"; }
  mv "$out.part" "$out" || die "could not keep $3 in the cache"
  ok "$3: checked, it is the file its publisher published"
}

page_link() {   # page_link PAGE NAME-PATTERN: "URL SHA256" of the installer on a project's download page
  curl "${HTTPS_ONLY[@]}" "${PAGE_LIMIT[@]}" -fsSL --max-time 60 "$1" 2>/dev/null | helper page-link - "$1" "$2"
}

dotnet_link() {   # "URL SHA512" of the newest .NET Desktop Runtime installer (x64) on Microsoft's release list
  curl "${HTTPS_ONLY[@]}" "${PAGE_LIMIT[@]}" -fsSL --max-time 120 "$DOTNET_RELEASES" 2>/dev/null | helper dotnet-link -
}

fetch_installer() {   # fetch_installer "URL CHECKSUM" FROM: into the cache. Sets INSTALLER
  local url=${1%% *} name
  name=${url##*/}
  case "$name" in ''|*[!A-Za-z0-9._-]*) die "unexpected file name in $url" ;; esac
  download "$url" "${1##* }" "$name" "$2"
  INSTALLER="$CACHE/$name"
}

wine_run() { "$WINE" --bottle "$BOTTLE" -- "$@" >/dev/null 2>&1 || true; }

run_installer() {   # the installer's own window: nothing is answered for the user
  spin "$(basename "$1") is open: click through its window" wine_run "$1" || true
}

wait_for_install() {   # wait_for_install WHAT TEST: until the installer's result is there or the user moves on
  local what=$1
  shift
  until "$@"; do
    if [ $YES = 1 ]; then note "$what: not found after its installer closed"; return 0; fi
    ask_text "$what: not found yet. Enter to look again once its installer has finished, s to skip:"
    case "$ANSWER" in s|S) note "$what: skipped"; return 0 ;; esac
  done
  ok "$what: installed"
}

rejacked_exe() {   # the Rejacked launcher's program, or nothing
  local exe=""
  IFS= read -r exe < <(find "$DRIVE" -path "$DRIVE/windows" -prune -o -iname rejacked-launcher.exe -print 2>/dev/null) || true
  printf '%s' "$exe"
}

has_rejacked() { [ -n "$(rejacked_exe)" ]; }

# MxOEmu's launcher: the game's launcher.exe changed to load mxowrap.dll. Both come with its game files,
# without a shortcut.
mxoemu_exe() {   # that launcher, or nothing
  local d
  d=$(client_dir)
  if [ -n "$d" ] && [ -f "$d/launcher.exe" ] && [ -f "$d/mxowrap.dll" ]; then printf '%s' "$d/launcher.exe"; fi
}
has_dotnet() { ls -d "$DRIVE/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App/$DOTNET_MAJOR".* >/dev/null 2>&1; }

has_revived() {   # looks afresh: Revived's installer may just have finished
  local d
  while IFS= read -r d; do
    if [ -f "$d/MxORevived-Launcher.exe" ]; then return 0; fi
  done < <(find_clients "$DRIVE" "$CLIENT_DEPTH")
  return 1
}

mxoemu_link() {   # the "Full Client" link on the MxOEmu page: https, on that project's own hosts only
  local page link="" version=${CLIENT_VERSION//./\\.}
  page=$(curl "${HTTPS_ONLY[@]}" "${PAGE_LIMIT[@]}" -fsSL --max-time 60 "$MXOEMU_PAGE" 2>/dev/null) || return 1
  IFS= read -r link < <(grep -oE "https://([A-Za-z0-9-]+\\.)*mxoemu\\.info/[A-Za-z0-9./_-]*${version}[A-Za-z0-9._-]*\\.7z" <<< "$page") || true
  [ -n "$link" ] || return 1
  printf '%s\n' "$link"
}

client_source() {   # asks where the game comes from. Sets CLIENT_SOURCE to a link, a folder, a file or nothing
  CLIENT_SOURCE=""
  if [ $YES = 1 ]; then
    note "the game itself: skipped, because --yes cannot ask where it comes from"
    return 0
  fi
  info "The game itself: version $CLIENT_VERSION, about 6 GB, for $(win_path "$DRIVE/$CLIENT_FOLDER"). Where does it come from?"
  choose "Download it from the MxOEmu project ($CLIENT_ARCHIVE_SIZE, mxoemu.info)" \
    "I have it: a folder, an archive file or a direct link" \
    "Skip: only Revived, whose installer downloads the game itself"
  case $CHOICE in
    0)
      CLIENT_SOURCE=$(mxoemu_link) || die "no client link found on $MXOEMU_PAGE. Download it there and give the file instead" ;;
    1)
      ask_text "Where is it? (a folder or a file can be dragged in from Finder)"
      CLIENT_SOURCE=${ANSWER%"${ANSWER##*[![:space:]]}"}   # a path dragged in from Finder ends with a space
      case "$CLIENT_SOURCE" in \'*\'|\"*\") CLIENT_SOURCE=${CLIENT_SOURCE:1:${#CLIENT_SOURCE}-2} ;; esac
      case "$CLIENT_SOURCE" in \~/*) CLIENT_SOURCE="$HOME/${CLIENT_SOURCE#\~/}" ;; esac
      [ -n "$CLIENT_SOURCE" ] || note "nothing given, skipped" ;;
    *)
      note "skipped. Revived can still be installed" ;;
  esac
}

download_client() {   # download_client LINK: into the cache, resuming an earlier download. Sets CLIENT_ARCHIVE
  local link=$1 part=0 rc=0
  mkdir -p "$CACHE" || die "could not make $CACHE"
  CLIENT_ARCHIVE="$CACHE/client-$(printf %s "$link" | shasum | cut -c1-12).part"
  if [ -s "$CLIENT_ARCHIVE" ]; then part=1; fi
  fetch_file "$link" "$CLIENT_ARCHIVE" "Downloading the game from ${link#*://}" resume || rc=$?
  case "$part$rc" in 122|133|136)   # the server would not continue an earlier download: from the start
    rm -f "${CLIENT_ARCHIVE:?}" || die "could not delete the unfinished download $CLIENT_ARCHIVE"
    rc=0
    fetch_file "$link" "$CLIENT_ARCHIVE" "Downloading the game from ${link#*://}" || rc=$? ;;
  esac
  [ $rc = 0 ] || die "download failed"
}

no_links() {   # a game has no symbolic links: one could make a later write land outside the bottle
  if [ -n "$(find "$1" -type l -print -quit 2>/dev/null)" ]; then
    die "the game files contain a link to somewhere else on the Mac, which a game never has. They were not used, to be safe"
  fi
}

# stage_client FROM STAGING [DOWNLOAD]: copies a folder or unpacks an archive to STAGING, outside drive C.
# One rename then puts the game in drive C whole or not at all. Sets STAGED_CLIENT to client.dll's folder.
stage_client() {
  local from=$1 staging=$2 download=${3:-} src
  rm -rf "${staging:?}" || die "could not clear $staging"
  mkdir -p "$staging/game" || die "could not make $staging"
  LEFTOVERS+=("$staging")
  if [ -d "$from" ]; then
    src=$(first_client "$from" 3)
    [ -n "$src" ] || die "no client.dll in $from"
    spin "Copying the game into the bottle" cp -Rc "$src/." "$staging/game/" || die "copying failed"
    no_links "$staging/game"
    STAGED_CLIENT="$staging/game"
    return 0
  fi
  if ! spin "Unpacking the game (some minutes)" tar -xf "$from" -C "$staging/game"; then
    if [ -n "$download" ]; then rm -f "${download:?}" || true; fi   # or the next run would continue a broken download
    die "could not unpack it (zip, 7z and tar archives work, and a link has to lead to the file itself, not to a web page)"
  fi
  no_links "$staging/game"
  STAGED_CLIENT=$(first_client "$staging/game" "$CLIENT_DEPTH")
  [ -n "$STAGED_CLIENT" ] || die "no client.dll in that archive"
}

get_client() {
  local target="$DRIVE/$CLIENT_FOLDER" staging="$BOTTLE_DIR/$UNPACK_NAME" from download=""
  client_source
  from=$CLIENT_SOURCE
  [ -n "$from" ] || return 0
  if [ -e "$target" ] && ! rmdir "$target" 2>/dev/null; then
    die "$(win_path "$target") is there already, without the game in it. Move it away or delete it, then run this again"
  fi
  case "$from" in
    https://*)
      download_client "$from"
      download=$CLIENT_ARCHIVE
      from=$download ;;
    http://*)
      die "a link has to start with https://" ;;
    *)
      [ -e "$from" ] || from=${from//\\/}   # a dragged-in path also has its spaces escaped
      [ -e "$from" ] || die "not found: $from" ;;
  esac
  stage_client "$from" "$staging" "$download"
  mkdir -p "$(dirname "$target")" || die "could not make $(dirname "$target")"
  mv "$STAGED_CLIENT" "$target" || die "could not move the game into drive C"
  rm -rf "${staging:?}" || true
  if [ -n "$download" ]; then rm -f "${download:?}" || true; fi
  # the client has no matrix.exe of its own: its launcher.exe runs under that name
  [ -f "$target/launcher.exe" ] || note "no launcher.exe next to client.dll. Is that the whole game folder?"
  ok "game files in place: $(win_path "$target")"
}

rejacked_folder() {   # so that the launcher need not be told where the game is
  local d
  d=$(client_dir)
  if [ -z "$d" ] || ! has_rejacked; then return 0; fi
  d=$(win_path "$d")
  if "$WINE" --bottle "$BOTTLE" -- reg query "$REJACKED_KEY" /v install_dir >/dev/null 2>&1; then
    ok "Rejacked launcher: a game folder is set already"
  elif ! spin "Telling the Rejacked launcher where the game is: $d" reg_write "$REJACKED_KEY" install_dir "$d"; then
    note "could not set it. Choose $d in the launcher's settings"
  fi
}

install_rejacked() {
  local link
  if has_rejacked; then ok "Rejacked launcher: already installed"; return 0; fi
  ask "Install the MxO Rejacked launcher (downloaded from mxo-rejacked.com)?" || return 0
  if ! link=$(page_link "$REJACKED_PAGE" 'rejacked-launcher-[0-9.]+-win64\.exe'); then
    note "no installer with a checksum found on $REJACKED_PAGE. Install the launcher by hand (docs/crossover.md)"
    return 0
  fi
  fetch_installer "$link" mxo-rejacked.com
  # NSIS installer: with /S it shows no pages and starts nothing at the end
  info "The installer runs without its window. Should one open after all, do not start the launcher on its last page."
  spin "Installing the Rejacked launcher" wine_run "$INSTALLER" /S || true
  if ! has_rejacked; then
    note "The installer did not finish by itself, so its window opens now."
    note "On its last page, do not start the launcher yet: the setup has more to do first."
    run_installer "$INSTALLER"
  fi
  wait_for_install "Rejacked launcher" has_rejacked
}

add_mxoemu() {   # CrossOver's icon for an MxOEmu launcher that came with the game
  local exe
  exe=$(mxoemu_exe)
  if [ -z "$exe" ]; then return 0; fi
  if ! has_icon "$MXOEMU_ICON"; then
    ask "Add the MxOEmu launcher to CrossOver's icons (it came with the game files)?" || return 0
  fi
  launcher_icon "MxOEmu launcher" "$MXOEMU_ICON" "$exe" make
}

install_dotnet() {   # Revived's launcher needs it
  local link
  if has_dotnet; then return 0; fi
  if ! link=$(dotnet_link); then
    note "could not read Microsoft's .NET release list. Revived's launcher will ask for the .NET $DOTNET_MAJOR Desktop Runtime"
    return 0
  fi
  fetch_installer "$link" Microsoft
  run_installer "$INSTALLER"
  wait_for_install ".NET $DOTNET_MAJOR Desktop Runtime" has_dotnet
}

install_revived() {   # its Setup copies the game in the bottle, its Installer downloads one
  local link kind=Installer d folder='C:\Games\MxO Revived'
  if [ -n "$REVIVED" ]; then ok "Revived: already installed"; return 0; fi
  ask "Install MxO Revived (downloaded from mxorevived.com)?" || return 0
  install_dotnet
  d=$(client_dir)
  [ -z "$d" ] || kind=Setup
  if ! link=$(page_link "$REVIVED_PAGE" "MxORevived-$kind\\.exe"); then
    note "no installer with a checksum found on $REVIVED_PAGE. Install Revived by hand (docs/crossover.md)"
    return 0
  fi
  fetch_installer "$link" mxorevived.com
  if [ $kind = Installer ]; then
    info "It downloads the game ($CLIENT_ARCHIVE_SIZE) into its own folder. Keep the folder it offers, $folder."
  else
    info "It makes Revived's own copy of the game that is in this bottle."
    note "Its window asks where The Matrix Online is installed. Choose $(win_path "$d") there."
    note "Keep the folder it offers for Revived itself, $folder."
  fi
  note "When it finishes, do not start the game yet: the setup has more to do first."
  run_installer "$INSTALLER"
  wait_for_install "MxO Revived" has_revived
}

step_game() {
  say "Game"
  local d
  d=$(client_dir)
  if [ -n "$d" ]; then   # the game itself: Rejacked needs it, Revived copies it
    ok "game files: $(win_path "$d")"
  else
    get_client
    find_installs
  fi
  add_mxoemu
  install_rejacked
  install_revived
  find_installs
  rejacked_folder
  show_installs
}

write_start_overrides() {   # each registry write starts Wine once, which takes a moment
  local name exe
  reg_add 'HKCU\Software\Wine\DllOverrides' d3dcompiler_43 native,builtin
  for name in "${DM_DLLS[@]}"; do
    if [ "$name" != dsound ]; then   # DirectSound only for the game, below
      reg_add 'HKCU\Software\Wine\DllOverrides' "$name" native,builtin
    fi
  done
  for exe in "${EXES[@]}"; do
    reg_add "HKCU\\Software\\Wine\\AppDefaults\\$exe\\DllOverrides" dsound native,builtin
  done
}

put_shader_compiler() {   # the game ships Microsoft's, and Wine's cannot handle the game's shaders
  local src="" d
  for d in "${INSTALLS[@]+"${INSTALLS[@]}"}"; do
    if [ -f "$d/D3DCompiler_43.dll" ]; then src="$d/D3DCompiler_43.dll"; break; fi
  done
  if [ -z "$src" ]; then
    note "shader compiler: no game yet to take it from, skipped"
  elif cmp -s "$src" "$SYS/d3dcompiler_43.dll"; then
    ok "shader compiler: already in place"
  else
    put_file "$src" "$SYS/d3dcompiler_43.dll"
    ok "shader compiler: Microsoft's, taken from the game folder"
  fi
}

dm_dlls_in_place() {   # all of them Microsoft's: a run cut short can leave some of Wine's
  local name
  for name in "${DM_DLLS[@]}"; do
    if [ ! -f "$SYS/$name.dll" ] || is_wine_builtin "$SYS/$name.dll"; then return 1; fi
  done
}

put_directmusic() {   # Wine's DirectMusic hangs on this game, and Microsoft's needs Microsoft's DirectSound
  local name
  if dm_dlls_in_place; then ok "music and sound: Microsoft's DirectMusic and DirectSound already in place"; return 0; fi
  download "$DX2010_URL" "$DX2010_SHA" directx_feb2010_redist.exe "Microsoft, via the Internet Archive"
  temp_dir
  tar -xf "$CACHE/directx_feb2010_redist.exe" -C "$TMP" dxnt.cab || die "could not unpack directx_feb2010_redist.exe"
  for name in "${DM_DLLS[@]}"; do
    tar -xf "$TMP/dxnt.cab" -C "$TMP" "$name.dll" || die "no $name.dll in Microsoft's DirectX package"
  done
  for name in "${DM_DLLS[@]}"; do put_file "$TMP/$name.dll" "$SYS/$name.dll"; done
  ok "music and sound: Microsoft's DirectMusic and DirectSound installed"
}

put_sound_bank() {   # the instruments DirectMusic plays with
  if [ -f "$SYS/drivers/gm.dls" ]; then ok "music sound bank: already in place"; return 0; fi
  download "$DX2006_URL" "$DX2006_SHA" directx_apr2006_redist.exe "Microsoft, via the Internet Archive"
  temp_dir
  tar -xf "$CACHE/directx_apr2006_redist.exe" -C "$TMP" DirectX.cab || die "could not unpack directx_apr2006_redist.exe"
  tar -xf "$TMP/DirectX.cab" -C "$TMP" gm16.dls || die "no gm16.dls in Microsoft's DirectX package"
  mkdir -p "$SYS/drivers" "$DRIVE/windows/system32/drivers" || die "could not make the drivers folders"
  put_file "$TMP/gm16.dls" "$DRIVE/windows/system32/drivers/gm.dls"
  put_file "$TMP/gm16.dls" "$SYS/drivers/gm.dls"   # last: the check above looks at this one
  ok "music sound bank installed"
}

step_bottle() {
  say "Start fixes"
  info "What the game needs to start at all."
  need_game
  need_game_closed
  put_shader_compiler
  put_directmusic
  put_sound_bank
  spin "Telling CrossOver to use them for the game (${EXES[*]})" write_start_overrides \
    || die "a registry write failed. $(job_output)"
  set_env "$LARGE_ADDRESS_ENV"
  ok "more memory for the game (without it, it crashed after about a minute)"
}

# The client.dll to build from. One DLL serves every install: each routine is checked against the client
# in memory at start. Revived's comes last: one of its routines cannot be translated.
build_client() {
  local d
  d=$(client_dir)
  echo "${d:-${INSTALLS[0]}}/client.dll"
}

needs_build() {   # no DLL yet, or the sources or the game changed since it was built
  local dll="$ROOT/build/d3d9.dll"
  [ -f "$dll" ] || return 0
  [ -n "$(find "$ROOT/dxvk" "$ROOT/translator" "$ROOT/scripts/build.sh" "$(build_client)" -newer "$dll" 2>/dev/null | head -1)" ]
}

TOOLS=""   # ready, install or missing, once looked at
choose_tools() {   # installing the build tools is a question like the others
  [ -z "$TOOLS" ] || return 0
  find_brew || true
  TOOLS=ready
  [ -n "$(missing_build_tools)" ] || return 0
  TOOLS=missing
  if can_brew_install && ask "Install the build tools with Homebrew (${BREW_PACKAGES[*]})?"; then TOOLS=install; fi
}

step_build() {
  say "Speed-up: build"
  need_game
  local client
  choose_tools
  if [ $TOOLS = install ]; then
    spin "Installing the build tools with Homebrew" brew install "${BREW_PACKAGES[@]}" \
      || die "Homebrew could not install them. $(job_output). To try by hand: $(brew_command)"
  fi
  if [ -n "$(missing_build_tools)" ]; then
    die "the build tools are missing:$(missing_build_tools). Install them from the account that installed Homebrew, then run this again: $(brew_command)"
  fi
  client=$(build_client)
  spin "Building the speed-up from your copy of the game (a few minutes)" "$ROOT/scripts/build.sh" "$client" \
    || die "the build failed. $(job_output)"
}

FPS_LIMIT=""   # yes or no, once asked
choose_fps() {   # unlimited, the game draws up to 200 fps in light scenes: only heat and fan noise
  [ -z "$FPS_LIMIT" ] || return 0
  local default=yes current now=""
  if [ $SPEEDUP_BEFORE = 1 ] && [ $FPS_GIVEN = 0 ]; then   # the bottle's own limit, or the 0 of a "no" given before
    current=$(bottle_env DXVK_FRAME_RATE)
    case "$current" in
      ''|*[!0-9]*) ;;   # never answered in this bottle: offered as in a new one
      *) if [ $((10#$current)) -gt 0 ]; then FPS=$((10#$current)); else default=no; now=" It runs without a limit now."; fi ;;
    esac
  fi
  if [ "$FPS" -gt 0 ] && ask "Limit the frame rate to $FPS fps (quieter fans)?$now" "$default"; then FPS_LIMIT=yes; else FPS_LIMIT=no; fi
}

ADDONS=""   # replace or keep, once asked
choose_addons() {   # add-on files next to the game (mx*.dll) hook some routines the speed-up replaces
  [ -z "$ADDONS" ] || return 0
  local default=yes
  if [ $SPEEDUP_BEFORE = 1 ] && [ "$(bottle_env DXVK_MXO_RESPECT_ADDONS)" != 0 ]; then default=no; fi   # as the bottle has it
  if ask "Also speed up the game code that add-ons use? It gave about 10 fps on the test machine, but an add-on such as Revived's interface scaling may stop working." "$default"; then
    ADDONS=replace
  else
    ADDONS=keep
  fi
}

write_d3d9_overrides() {
  local exe
  reg_add 'HKCU\Software\Wine\DllOverrides' d3d9 builtin   # everything else keeps Wine's Direct3D 9
  for exe in "${EXES[@]}"; do
    reg_add "HKCU\\Software\\Wine\\AppDefaults\\$exe\\DllOverrides" d3d9 native,builtin
  done
}

merge_caches() {   # each executable starts with the pipelines the others built
  local caches=() cache said newline=$'\n'
  for cache in "$DXVK_DIR"/*.dxvk-cache; do
    if [ -f "$cache" ]; then caches+=("$cache"); fi
  done
  [ ${#caches[@]} -ge 2 ] || return 0
  if said=$(python3 -I "$ROOT/scripts/merge-pipeline-caches.py" "${caches[@]}" 2>&1); then
    info "shader caches of the games combined, so each starts with what the others built (${said##*"$newline"})"
  else
    note "shader caches not combined: ${said##*"$newline"}"
  fi
}

step_install() {
  say "Speed-up: install"
  need_game
  [ -n "$DLL" ] || DLL="$ROOT/build/d3d9.dll"
  [ -f "$DLL" ] || die "no $DLL. The build step makes it: scripts/setup.sh build"
  need_game_closed
  choose_fps
  choose_addons
  put_file "$DLL" "$SYS/d3d9.dll"
  spin "Switching the game to the speed-up (${EXES[*]})" write_d3d9_overrides \
    || die "a registry write failed. $(job_output)"
  mkdir -p "$DXVK_DIR" || die "could not make $DXVK_DIR"
  set_env "${SPEEDUP_ENV[@]}" "$LARGE_ADDRESS_ENV"
  if [ "$FPS_LIMIT" = yes ]; then
    set_env "DXVK_FRAME_RATE=$FPS"
    ok "frame rate limited to $FPS fps"
  else
    set_env DXVK_FRAME_RATE=0   # no limit for DXVK, and the "no" the next run starts from
  fi
  if [ "$ADDONS" = replace ]; then   # without it the DLL leaves alone every routine an add-on file points into
    set_env DXVK_MXO_RESPECT_ADDONS=0
    ok "the game code that add-ons use is sped up too"
  else
    unset_env DXVK_MXO_RESPECT_ADDONS
  fi
  merge_caches
  ok "installed for: ${EXES[*]}"
  info "Ctrl+Shift+F in the game shows the frame rate."
  info "Leave the bottle's Graphics setting in CrossOver on Auto. The log is in $(win_path "$DXVK_DIR")."
}

# Written by the game with every Video Options control at its highest, detail and memory presets on Custom.
# Client_RenderThrottle_Override = 1 ("Scale LOD with Frame Rate" off) keeps the draw distance at low fps.
MAX_DETAIL="
DetailCfg_Detail = 0
DetailCfg_Memory = 0
Client_RenderThrottle_Override = 1
DL_SLOD_InitLoadRadius = 1000
DL_SLOD_PrefetchRadius = 250000
DL_SID_PrefetchRadius = 70000
DL_NAV_PrefetchRadius = 35000
DL_Ext_PrefetchRadius = 50000
DL_Prop_PrefetchRadius = 12500
DL_SIDI_PrefetchRadius = 5000
DL_Int_PrefetchRadius = 4000
WR_ExtFarDist = 50000
WR_ExtToIntDist = 2500
WR_ExtObjFarDist = 20000
WR_PropFarDist = 12500
WR_PropFadeDist = 3000
WR_SLODFarDist = 220000
WR_SkyBox_FogRim_FogDst = 70000
WR_FogFarDist = 70000
ExteriorCameraFarZ = 46000
CameraFarZ = 46000
InteriorCameraFarZ = 12000
WR_DrawShadows = 1
ModelShadow_Enable = 1
ModelShadow_Proj_Enable = 1
WR_PropShadow_Enable = 1
PropShadow_Load = 1
WR_WetExt_Enable = 1
WR_Water_Use_Version_2 = 1
WR_DrawWeather = 1
WR_WeatherParticle_Scale = 1
WR_DrawGrass = 1
Grass_Load_Percent = 1
Richworld_Enabled = 1
Richworld_MaxCars = 25
Richworld_CarDensityUser = 1.5
Richworld_MaxPeddies = 25
Richworld_PedDensityUser = 1.5
TrashMgr_Target_Trash = 20
MipmapOffset = 0
Mipmap_Bias = -0.4
AntiAlias_Level = 1
AntiAliasFSOverSample = 2
AntiAliasFSQuality = 2
ScreenFilter_Enable_GreenShift = 1
ScreenFilter_Enable_Overbright = 1
fx_mode = 2147483647
SubAlloc_Disable = 0
PreAlloc_SubAllocs = 3
RezMgr_Dead_Rez_Count = 500
audio_max_voices = 64
audio_high_quality = 1
"

# The lighter set: the maximum, then these. For the M1 and M2, whose processors run the game's main
# thread slower. What they are worth on the M4 is in docs/measurements.md. On an M1 they are
# not measured yet.
# A Client_RenderThrottle_Override between 0 and 1 holds the draw distance at that share.
LIGHT_DETAIL="
Client_RenderThrottle_Override = 0.7
ModelShadow_Enable = 0
ModelShadow_Proj_Enable = 0
WR_WetExt_Enable = 0
AntiAlias_Level = 0
"

# The enhanced set: the maximum, then these, which go past the top of the game's menu. Experimental:
# tried by eye with Revived on an M4, not measured. The draw distances are the menu's top times 1.4.
ENHANCED_DETAIL="
DL_Ext_PrefetchRadius = 70000
DL_Prop_PrefetchRadius = 17500
WR_ExtFarDist = 70000
WR_ExtObjFarDist = 28000
WR_PropFarDist = 17500
WR_PropFadeDist = 4200
WR_FogFarDist = 98000
WR_SkyBox_FogRim_FogDst = 98000
ExteriorCameraFarZ = 64400
CameraFarZ = 64400
Richworld_MaxCars = 35
Richworld_MaxPeddies = 35
Richworld_CarDensityUser = 2
Richworld_PedDensityUser = 2
"
# Its settings that no menu shows. They go into each game's autoexec.cfg, which the game reads and
# never writes: options.cfg wins only for the keys it holds.
# Each line: the setting, its value in the enhanced set, and after the bar its value without it. That
# is what autoexec.cfg comes with for the two fallbacks and the client's own default for the rest.
# Read from the client's defaults and not confirmed by eye: a lower fallback keeps a character's real
# shadow longer, and a lower model scale keeps the finer model longer.
HIDDEN_DETAIL="
ModelShadow_Fallback_0 = 0.2 | 0.4
ModelShadow_Fallback_1 = 0.1 | 0.25
ModelShadow_Proj_Size = 1024 | 512
WR_ShadowDistance = 20000 | 10000
Grass_Draw_Dst = 10000 | 5000
WR_Reflect_EnvMap_Size = 1024 | 256
ModelEngObj_LOD_Dst_Scale = 0.5 | 1
"

chip_generation() {   # 1 for an M1, 4 for an M4 Max, nothing when the name gives no number
  local name
  name=$(sysctl -n machdep.cpu.brand_string 2>/dev/null) || return 0
  case "$name" in
    *"Apple M"[0-9]*) name=${name#*Apple M}; printf '%s' "${name%%[!0-9]*}" ;;
  esac
}

DETAIL=""   # light, max, enhanced or keep, once chosen
# Enter takes the set for this Mac in a game that has no settings yet. Where a game has some, Enter
# leaves them, and --yes does the same.
choose_detail() {   # choose_detail [named]: named when the detail step was asked for by name
  [ -z "$DETAIL" ] || return 0
  local recommended=max fresh=yes f where=""
  case "$(chip_generation)" in 1|2) recommended=light ;; esac
  while IFS= read -r f; do
    [ ! -f "$f" ] || fresh=no
  done < <(options_files)
  screen_size
  [ -z "$SCREEN_W" ] || where=", at this display's resolution (${SCREEN_W}x$SCREEN_H)"
  if [ $YES = 1 ]; then
    if [ $fresh = yes ] || [ "${1:-}" = named ]; then DETAIL=$recommended; else DETAIL=keep; fi
    return 0
  fi
  row "$M_ASK" "$ACC" "Which graphics settings$where? They replace the detail settings a game has now."
  # one short line each, this Mac's set first
  local light="Lighter, for an M1 or M2: shorter draw distance, fewer effects"
  local max="Maximum, for an M3, M4 or newer: every option at its highest"
  local enhanced="Enhanced, experimental: past the menu's maximum, tried on an M4"
  local sets=(max light enhanced)
  if [ $recommended = light ]; then
    sets=(light max enhanced)
    light="Lighter, recommended for this Mac: shorter draw distance, fewer effects"
  else
    max="Maximum, recommended for this Mac: every option at its highest"
  fi
  CHOICE_START=3
  if [ $fresh = yes ] || [ "${1:-}" = named ]; then CHOICE_START=0; fi
  if [ $recommended = light ]; then choose "$light" "$max" "$enhanced" "Leave the settings as they are"
  else choose "$max" "$light" "$enhanced" "Leave the settings as they are"; fi
  DETAIL=${sets[CHOICE]:-keep}
  case $DETAIL in
    light) ok "graphics: the lighter settings" ;;
    max) ok "graphics: everything at maximum" ;;
    enhanced) ok "graphics: the enhanced settings (experimental)" ;;
    *) ok "graphics: left as they are" ;;
  esac
}

set_options() {   # set_options FILE "KEY = VALUE lines": changes those keys (any case), adds the missing ones
  mkdir -p "$(dirname "$1")" || die "could not make the folder of $1"
  backup_once "$1"
  edit "$(win_path "$1")" set-options "$1" "$2"
}

get_option() {   # get_option FILE KEY: the key's value in a settings file, or nothing
  helper get-option "$1" "$2" 2>/dev/null || true
}

options_files() {   # every game's options.cfg: Revived's is in its folder, the others share one
  [ -z "$(client_dir)" ] || echo "$DRIVE/users/crossover/AppData/Roaming/The Matrix Online/options.cfg"
  [ -z "$REVIVED" ] || echo "$REVIVED/options.cfg"
}

SCREEN_W="" SCREEN_H="" SCREEN_READ=0
screen_size() {   # SCREEN_W and SCREEN_H: the main display as the bottle sees it, empty when unreadable
  [ $SCREEN_READ = 0 ] || return 0
  SCREEN_READ=1
  local out width height scale
  out=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var s = $.NSScreen.screens.objectAtIndex(0);
    Math.round(s.frame.size.width) + " " + Math.round(s.frame.size.height) + " " + s.backingScaleFactor' 2>/dev/null) || return 0
  read -r width height scale <<< "$out" || true
  case "${width:-x}${height:-x}" in *[!0-9]*) return 0 ;; esac
  SCREEN_W=$width SCREEN_H=$height
  # a bottle in CrossOver's high-resolution mode counts the display's pixels, not its points
  if [ "${scale:-1}" = 2 ] && grep -qi '^"RetinaMode"="y' "$BOTTLE_DIR/user.reg" 2>/dev/null; then
    SCREEN_W=$((SCREEN_W * 2)); SCREEN_H=$((SCREEN_H * 2))
  fi
}

# hidden_lines FILE enhanced|back: the enhanced set's lines for an autoexec.cfg, or the lines that
# take it out again. Only a value that is still the enhanced set's goes back: one the player has
# changed since, or set without this setup, is theirs.
hidden_lines() {
  local f=$1 line key enhanced default
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%% = *}
    enhanced=${line#* = }
    default=${enhanced#* | }
    enhanced=${enhanced%% | *}
    if [ "$2" = enhanced ]; then
      printf '%s = %s\n' "$key" "$enhanced"
    elif [ "$(get_option "$f" "$key")" = "$enhanced" ]; then
      printf '%s = %s\n' "$key" "$default"
    fi
  done <<< "$HIDDEN_DETAIL"
}

hidden_settings() {   # the enhanced set's part of each game's autoexec.cfg, or its way back out of one
  local d f back
  for d in "${INSTALLS[@]}"; do
    f="$d/autoexec.cfg"
    if [ "$DETAIL" = enhanced ]; then
      if [ ! -f "$f" ]; then note "no $(win_path "$f"), so that game gets the enhanced set without the settings no menu shows"; continue; fi
      set_options "$f" "$(hidden_lines "$f" enhanced)"
      ok "$(win_path "$f"): the settings no menu shows"
    else
      back=$(hidden_lines "$f" back)
      [ -n "$back" ] || continue
      backup_once "$f"
      edit "$(win_path "$f")" set-options --existing "$f" "$back"
      ok "$(win_path "$f"): the enhanced set's values are the game's own again"
    fi
  done
}

step_detail() {
  say "Detail: graphics settings"
  need_game
  need_game_closed "It writes its options when it closes"
  choose_detail named
  if [ "$DETAIL" = keep ]; then note "nothing changed"; return 0; fi
  local f values=$MAX_DETAIL what="every graphics option at its maximum"
  if [ "$DETAIL" = light ]; then
    values="$values$LIGHT_DETAIL"
    what="the lighter graphics settings"
  elif [ "$DETAIL" = enhanced ]; then
    values="$values$ENHANCED_DETAIL"
    what="the enhanced graphics settings"
  fi
  screen_size
  if [ -n "$SCREEN_W" ]; then   # options.cfg wins over the size in a launcher's block of useropts.cfg
    values="$values
ScreenWidth = $SCREEN_W
ScreenHeight = $SCREEN_H"
  fi
  while IFS= read -r f; do
    set_options "$f" "$values"
    ok "$(win_path "$f"): $what"
  done < <(options_files)
  hidden_settings
  if [ "$DETAIL" = light ]; then
    info "Draw distance held at 70%, no character shadows, no wet streets, no anti-aliasing. Everything else at its highest."
  elif [ "$DETAIL" = enhanced ]; then
    info "Past the game's menu: draw distance 40% further, sharper character shadows, shadows and grass drawn twice as far, finer models at a distance, a sharper wet-street reflection, more cars and pedestrians."
    note "Experimental: tried by eye with Revived on an M4, not measured. It costs frame rate, most in busy streets. A launcher update can replace autoexec.cfg: run this step again then."
  else
    info "Draw distance, shadows, wet streets, weather, grass, traffic, anti-aliasing and both screen filters."
  fi
  if [ -n "$SCREEN_W" ]; then
    ok "resolution ${SCREEN_W}x$SCREEN_H, the main display's"
  else
    note "could not read the display's size, so the resolution stays as it is"
  fi
  # sharp ground and walls at shallow angles. DXVK reads this file when the game starts
  set_options "$DXVK_DIR/dxvk.conf" "d3d9.samplerAnisotropy = 16"
  set_env "DXVK_CONFIG_FILE=C:/$DXVK_FOLDER/dxvk.conf"
  ok "sharper textures at a distance (16x anisotropic filtering)"
  info "The window mode stays as the launchers set it."
}

useropts_files() {
  local f
  while IFS= read -r f; do echo "$(dirname "$f")/useropts.cfg"; done < <(options_files)
}

intro_off() {   # every game skips its logo movies already
  local f
  while IFS= read -r f; do
    [ "$(get_option "$f" EnableSplash)" = 0 ] || return 1
  done < <(useropts_files)
}

step_intro() {
  say "Intro: no logo movies"
  need_game
  need_game_closed
  local f
  while IFS= read -r f; do   # the game does not keep this in options.cfg, and a launcher leaves the line alone
    set_options "$f" "EnableSplash = 0"
    ok "$(win_path "$f"): the logo movies are off"
  done < <(useropts_files)
  info "The game starts without the logo movies."
}

music_guard_off() {
  [ "$(lower "$(get_option "$REVIVED/$MUSIC_GUARD" music)")" = off ]
}

step_music() {
  say "Revived: music"
  if [ -z "$REVIVED" ]; then note "MxO Revived is not in this bottle"; return 0; fi
  need_game_closed "It writes its options when it closes"
  # Revived's starter checks the music outside the game, on Wine's DirectSound, where that fails. It then
  # switches the music off, unless its guard file says "music = on". Written before the first start too.
  set_options "$REVIVED/$MUSIC_GUARD" "music = on"
  # what the starter already switched off. options.cfg wins over useropts.cfg
  if [ -f "$REVIVED/options.cfg" ]; then set_options "$REVIVED/options.cfg" "MusicSystemEnable = 1"; fi
  if [ -f "$REVIVED/useropts.cfg" ]; then   # there the line is only changed, never added
    backup_once "$REVIVED/useropts.cfg"
    edit "$(win_path "$REVIVED/useropts.cfg")" set-options --existing "$REVIVED/useropts.cfg" "MusicSystemEnable = 1"
  fi
  ok "music on: in the starter's guard file and in Revived's settings"
}

# For a full run, which does not ask. "music = off" where the setup has been before is the player's: the
# setup wrote "on" and the starter leaves "on" alone. In a bottle new to the setup it is the starter's.
keep_or_fix_music() {
  if [ $SPEEDUP_BEFORE = 1 ] && music_guard_off; then
    say "Revived: music"
    note "music stays off, as Revived's $MUSIC_GUARD says. To switch it on: scripts/setup.sh music"
  else
    step_music
  fi
}

video_off() {   # the rain animation behind Revived's launcher window is off
  grep -q -E '"BackgroundVideo"[[:space:]]*:[[:space:]]*false' "$REVIVED/launcher-settings.json" 2>/dev/null
}

step_video() {
  say "Revived: launcher video"
  if [ -z "$REVIVED" ]; then note "MxO Revived is not in this bottle"; return 0; fi
  local settings="$REVIVED/launcher-settings.json"
  # the launcher writes its settings when it closes, which would undo this
  if running MxORevived-Launcher.exe; then
    note "close the Revived launcher first, then run this step again: scripts/setup.sh video"
    return 0
  fi
  backup_once "$settings"
  edit "$(win_path "$settings")" video-off "$settings"
  ok "the rain animation behind the launcher's window is off"
}

# cxmenu.conf is CrossOver's list of the bottle's shortcuts. A launcher in it can still lack its icon after
# an installer has run: "cxmenu --sync" puts the icon there.
has_icon() { grep -qiF "/$1.lnk]" "$BOTTLE_DIR/cxmenu.conf" 2>/dev/null; }

make_shortcut() {   # make_shortcut NAME EXE: with CrossOver's own tool. Fails unless CrossOver then lists it
  local win
  win=$(win_path "$2")
  "$WINE" --bottle "$BOTTLE" -- cxmklnk --programs "$1.lnk" --target "$win" --workdir "${win%\\*}" || true
  "$CX/bin/cxmenu" --bottle "$BOTTLE" --sync --mode install >/dev/null 2>&1 || true
  has_icon "$1"
}

# launcher_icon WHAT ICON EXE [make]: says whether CrossOver lists a launcher's shortcut. With "make", a
# missing one is made first. Sets ICON_LISTED=1 when it is listed.
ICON_LISTED=0
launcher_icon() {
  local what=$1 icon=$2 exe=$3
  if has_icon "$icon"; then
    ok "$what: CrossOver has its shortcut"
  elif [ "${4:-}" = make ] && spin "$what: no shortcut in the bottle, making one" make_shortcut "$icon" "$exe"; then
    ok "$what: its icon is in CrossOver"
  else
    note "$what: CrossOver has no icon for it. It starts with the bottle's Run Command: $(win_path "$exe")"
    return 0
  fi
  ICON_LISTED=1
}

step_icons() {
  say "Icons"
  local exe
  ICON_LISTED=0
  spin "CrossOver reads the bottle's shortcuts again" "$CX/bin/cxmenu" --bottle "$BOTTLE" --sync --mode install \
    || note "CrossOver could not read the bottle's shortcuts"
  exe=$(rejacked_exe)
  if [ -n "$exe" ]; then
    launcher_icon "Rejacked launcher" "$REJACKED_ICON" "$exe" make
  elif named icons; then
    info "The Rejacked launcher is not in this bottle."
  fi
  # Revived's setup makes its shortcut to a starter of its own, so a missing one is not made here
  if [ -n "$REVIVED" ]; then launcher_icon "MxO Revived" "$REVIVED_ICON" "$REVIVED/MxORevived-Launcher.exe"; fi
  exe=$(mxoemu_exe)
  if has_icon "$MXOEMU_ICON"; then
    launcher_icon "MxOEmu launcher" "$MXOEMU_ICON" "$exe"
  elif [ -n "$exe" ] && named icons; then   # the game step asks before it makes this one, so only this step run alone says so
    info "The MxOEmu launcher has no shortcut. To get one: scripts/setup.sh game"
  fi
  if [ $ICON_LISTED = 1 ]; then info "If CrossOver does not show an icon yet, close CrossOver and open it again."; fi
}

refresh_icons() {   # only when a launcher has or should have an icon. The bottle does not say whether CrossOver shows it
  if has_rejacked || [ -n "$REVIVED" ] || has_icon "$MXOEMU_ICON"; then step_icons; fi
}

step_uninstall() {
  say "Uninstall"
  info "The game goes back to CrossOver's normal graphics."
  need_game_closed
  local exe
  for exe in "${EXES[@]}"; do
    reg_del "HKCU\\Software\\Wine\\AppDefaults\\$exe\\DllOverrides" d3d9
  done
  if [ -f "$SYS/d3d9.dll.setup-backup" ]; then copy_whole "$SYS/d3d9.dll.setup-backup" "$SYS/d3d9.dll"; fi
  unset_env "${SPEEDUP_ENV[@]%%=*}" "${SPEEDUP_ENV_BY_CHOICE[@]}"
  ok "done: the game uses CrossOver's normal graphics again, and the speed-up's settings are gone from the bottle"
  info "What the game needs to start stays: Microsoft's DirectMusic and DirectSound, the shader compiler and the larger memory limit."
  info "The game's own settings (detail, logo movies, music) stay as they are. What they were before is next to each file, with a .setup-backup suffix."
}

# The last thing on the screen, where the eye lands: a heavy frame, all of it in one colour. Its title
# and colour say how the run ended: the accent colour for done, amber where a run is still owed.
done_frame() {
  local title="Done" ink=$ACC upper
  if ! named uninstall; then
    if [ ${#INSTALLS[@]} = 0 ]; then title="No game yet"; ink=$YEL
    elif [ $SETUP_OWED = 1 ]; then title="Not ready yet"; ink=$YEL; fi
  fi
  local DIM=$ink SIDE=$SIDE ROW_INK=""
  if [ $GLYPHS = 1 ]; then
    frame_close
    echo
    SIDE="┃"
    upper=$(printf '%s' "$title" | tr '[:lower:]' '[:upper:]')
    printf '%s┏━ %s %s┓%s\n' "$ink" "$upper" "${BAR_FULL:0:WIDTH - 5 - ${#upper}}" "$OFF"
    IN_FRAME=1
  else
    say "$title"
  fi
  if named uninstall; then
    ok "Uninstalled."
  elif [ ${#INSTALLS[@]} = 0 ]; then
    note "Run the setup again once a game is in this bottle."
  elif [ $SETUP_OWED = 1 ]; then
    note "Run the setup once more, without a step: it gives the game added now its start fixes and the speed-up."
  else
    ROW_INK=$ACC
    ok "Start the game from its launcher."
    ROW_INK=""
  fi
  if ! named uninstall; then
    if [ $CROSSOVER_CLOSED = 1 ]; then info "Open CrossOver again: it shows the launchers' icons."; fi
    # a run of every step asks about it. The game step alone does not
    if named game && [ -n "$REVIVED" ] && ! video_off; then
      note "Revived's launcher plays a rain animation behind its window, also while you play, which costs frame rate. Switch it off in the launcher's settings, or with: scripts/setup.sh video"
    fi
  fi
  if [ $GLYPHS = 1 ]; then
    printf '%s┗%s┛%s\n' "$ink" "${BAR_FULL:0:WIDTH - 2}" "$OFF"
    IN_FRAME=0
  fi
}

ending() {   # however a run ends: the stats frame, how it ended, a last row of falling code
  site_frame
  done_frame
  if [ $GLYPHS = 1 ]; then printf ' %s%s%s\n' "$DIM" "$(rain $((WIDTH - 2)) 3)" "$OFF"; fi
}

# --- run ----------------------------------------------------------------------------------------

SETUP_OWED=0   # 1 when a named game step added a game that the start fixes or the speed-up have not seen

if [ ${#STEPS[@]} = 0 ]; then
  # Revived's installer needs clicks, so --yes leaves the game step out
  if [ $YES = 0 ] && [ ${#INSTALLS[@]} = 0 ]; then step_game; fi
  if [ ${#INSTALLS[@]} = 0 ]; then
    ending
    exit 0
  fi
  need_game_closed "The setup replaces files it has open"

  # Questions first, then the setup works by itself. No question about the start fixes, the speed-up and
  # Revived's music: without them the game shows a black screen, runs at about 15 fps or stays silent.
  if [ $YES = 0 ]; then say "Options"; fi
  choose_fps
  choose_addons
  if [ -z "$DLL" ] && needs_build; then
    choose_tools
    if [ $TOOLS = missing ]; then
      die "the speed-up has to be built, and the build tools are missing. Nothing was changed. Install them from the account that installed Homebrew, then run this again: $(brew_command)"
    fi
  fi
  choose_detail
  NO_INTRO=0
  if ! intro_off && ask "Skip the logo movies when the game starts?"; then NO_INTRO=1; fi
  VIDEO_OFF=0
  if [ -n "$REVIVED" ] && ! video_off \
    && ask "Switch off the rain animation behind Revived's launcher window (it costs frame rate while you play)?"; then
    VIDEO_OFF=1
  fi

  step_bottle
  if [ -z "$DLL" ]; then   # with --dll there is nothing to build
    if needs_build; then
      step_build
    else
      say "Speed-up: build"
      ok "already built for this game and this version. To build it again: scripts/setup.sh build"
    fi
  fi
  step_install
  if [ "$DETAIL" != keep ]; then step_detail; fi
  if [ $NO_INTRO = 1 ]; then step_intro; fi
  if [ -n "$REVIVED" ]; then keep_or_fix_music; fi
  if [ $VIDEO_OFF = 1 ]; then step_video; fi
  refresh_icons
else
  games_before=${#INSTALLS[@]}
  for step in "${STEPS[@]}"; do "step_$step"; done
  if named game && ! named icons; then refresh_icons; fi   # a launcher the game step installed has no icon yet
  # a game the game step added has neither its start fixes nor the speed-up: those steps write them per program
  if named game && ! { named bottle && named install; } && [ ${#INSTALLS[@]} -gt "$games_before" ]; then SETUP_OWED=1; fi
fi

ending
