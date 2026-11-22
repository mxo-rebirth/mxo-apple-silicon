#!/bin/bash
# Guided setup of The Matrix Online in a CrossOver bottle, for any MxO install (Rejacked, Revived or
# another project's client). Run it from the repository folder:
#
#   scripts/setup.sh                      everything; it asks what it needs to know first
#   scripts/setup.sh --yes                everything but the game step, no questions (first bottle found)
#   scripts/setup.sh --bottle NAME step…  only the named steps, in the named bottle
#   scripts/setup.sh --fps 120 install    another frame-rate limit (default 90, 0 for none)
#
# Steps:
#   game       the game and the launchers, when the bottle has no game: makes the bottle if it is
#              missing, gets the game from the MxOEmu project, a folder, an archive or a direct
#              link, downloads the Rejacked and Revived installers from the projects' sites, checks
#              them against the checksums on those sites and shows them for you to click through
#   bottle     what the game needs to start: Microsoft's shader compiler, DirectMusic and DirectSound
#   build      build d3d9.dll from this bottle's own client.dll (needs the tools in docs/building.md)
#   install    install that d3d9.dll for the game executables, with the bottle settings it needs
#   detail     every graphics option of the game at its maximum, the main display's resolution,
#              and 16x anisotropic filtering
#   intro      the game starts without its logo movies
#   icons      CrossOver's icon for the Rejacked launcher: makes its shortcut when the bottle has none
#   music      Revived only: keep its starter from switching the game's music off
#   video      Revived only: switch off the video behind its launcher, which keeps a processor core busy
#   uninstall  the game executables go back to Wine's Direct3D 9 (DirectMusic stays; it is needed)
#
# The script never reads passwords, launcher logins or credential stores, and never prints command
# lines of running programs. Every file it replaces is kept with a ".setup-backup" suffix.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CX=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver
WINE="$CX/bin/wine"
BOTTLES=${CX_BOTTLE_PATH:-$HOME/Library/Application Support/CrossOver/Bottles}   # CrossOver's own variable
BOTTLES=${BOTTLES%%:*}
NEW_BOTTLE=MatrixOnline
CACHE="$HOME/Library/Caches/mxo-apple-silicon"
LOG="$CACHE/setup.log"   # what the spinners hide

# Microsoft's DirectX redistributables, as used by winetricks for the same files
DX2010_URL="https://web.archive.org/web/20100205000000id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe"
DX2010_SHA=f6d191e89a963d7cca34f169d30f49eab99c1ed3bb92da73ec43617caaa1e93f
DX2006_URL="https://web.archive.org/web/20100920035904/https://download.microsoft.com/download/3/9/7/3972f80c-5711-4e14-9483-959d48a2d03b/directx_apr2006_redist.exe"
DX2006_SHA=dd8c3d401efe4561b67bd88475201b2f62f43cd23e4acc947bb34a659fa74952
DM_DLLS="dmband dmcompos dmime dmloader dmscript dmstyle dmsynth dmusic dswave dsound"

# where the projects publish their installers, each with its SHA-256, and Microsoft its .NET releases
REJACKED_PAGE=https://mxo-rejacked.com/download
REVIVED_PAGE=https://mxorevived.com/download.html
DOTNET_RELEASES=https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json
MXOEMU_PAGE=https://mxoemu.info/   # the MxOEmu project offers the full client there
# the Rejacked launcher is a Qt program: its "game/install_dir" setting is this registry value
REJACKED_KEY='HKCU\Software\Rejacked\Rejacked Launcher\game'

YES=0
BOTTLE=""
DLL=""
EXTRA_EXES=""
FPS=90
STEPS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --bottle) BOTTLE="$2"; shift ;;
    --dll) DLL="$2"; shift ;;
    --exe) EXTRA_EXES="$EXTRA_EXES $2"; shift ;;
    --fps) FPS="$2"; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    game|bottle|build|install|detail|intro|icons|music|video|uninstall) STEPS="$STEPS $1" ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

# --- look ---------------------------------------------------------------------------------------
# On a terminal: green frames with lit corners, as on whoisjackedin.com, opening words that come out of
# falling code, spinners and progress bars. Piped, or with NO_COLOR set: plain lines without control
# codes. MXO_THEME=light or dark overrides the guess about the terminal's background.

FANCY=0; GLYPHS=0; WIDTH=76; IN_FRAME=0
ACC="" GRN="" DIM="" RED="" YEL="" OFF=""
SITE="" SITE_DIM=""   # the stats site's frame has the site's second colour
M_OK=" " M_NOTE=" " M_ASK=" " M_BAD=" " M_PICK=">" M_DOWN=" "
SPIN=('|' '/' '-' '\')
RULE="" BAR_FULL="" BAR_EMPTY=""
WRAPPED=()
ROW_INK=""   # the colour of a row's text; a note sets it for its own row
CHOICE=0
ANSWER=""

light_background() {   # asks the terminal for its background colour; no answer counts as dark
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
  # the terminal's own green on a light background; the site's greens on a dark one
  ACC=$'\033[1;32m' GRN=$'\033[32m' DIM=$'\033[2;32m' RED=$'\033[1;31m' YEL=$'\033[1;33m' OFF=$'\033[0m'
  SITE=$'\033[1;34m' SITE_DIM=$'\033[34m'
  if [ "${MXO_THEME:-}" != light ] && [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ] \
    && { [ "${MXO_THEME:-}" = dark ] || ! light_background; }; then
    ACC=$'\033[1;38;5;84m' GRN=$'\033[38;5;41m' DIM=$'\033[38;5;29m'
    SITE=$'\033[1;38;5;75m' SITE_DIM=$'\033[38;5;32m'
    YEL=$'\033[1;38;5;214m'   # amber, apart from all the green
  fi
  M_OK="+" M_NOTE="!" M_ASK="?" M_BAD="x"
  probe="─"   # glyphs only where the shell counts characters, not bytes
  case "${#probe}${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in 1*[Uu][Tt][Ff]-8*|1*[Uu][Tt][Ff]8*)
    GLYPHS=1
    M_OK="✓" M_BAD="✗" M_PICK="❯" M_DOWN="↓"
    SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    while [ ${#RULE} -lt 160 ]; do RULE="${RULE}─"; BAR_FULL="${BAR_FULL}━"; BAR_EMPTY="${BAR_EMPTY}─"; done ;;
  esac
  trap 'frame_close; printf "\033[?25h"' EXIT   # a spinner or a menu hides the cursor
  trap 'printf "\r\033[K"; exit 130' INT
fi

frame_open() {   # the top edge with the title in it
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

row() {   # row MARK COLOUR TEXT [TAIL]: a line in the frame; long text wraps, TAIL sits at the right
  local mark=$1 colour=$2 text=$3 tail=${4:-} inner line first=1
  if [ $GLYPHS = 0 ]; then
    printf ' %s%s%s %s%s\n' "$colour" "$mark" "$OFF" "$ROW_INK$text${ROW_INK:+$OFF}" "${tail:+  $DIM$tail$OFF}"
    return 0
  fi
  inner=$((WIDTH - 6))
  [ -z "$tail" ] || inner=$((inner - ${#tail} - 1))
  wrap "$inner" "$text"
  for line in "${WRAPPED[@]}"; do
    if [ $first = 1 ]; then
      printf '%s│%s %s%s%s %s%*s%s %s│%s\n' "$DIM" "$OFF" "$colour" "$mark" "$OFF" "$ROW_INK$line${ROW_INK:+$OFF}" $((inner - ${#line})) "" \
        "${tail:+ $DIM$tail$OFF}" "$DIM" "$OFF"
      first=0
    else
      printf '%s│%s   %s%*s%s %s│%s\n' "$DIM" "$OFF" "$ROW_INK$line${ROW_INK:+$OFF}" $((inner - ${#line})) "" "${tail:+ ${tail//?/ }}" "$DIM" "$OFF"
    fi
  done
}

say() {   # say TITLE: a new frame; plain, a heading
  if [ $GLYPHS = 1 ]; then
    frame_close
    echo
    frame_open "$1"
  else
    printf '\n%s==%s %s%s%s\n' "$GRN" "$OFF" "$ACC" "$1" "$OFF"
  fi
}

info() { row " " "" "$1" "${2:-}"; }
ok()   { row "$M_OK" "$ACC" "$1" "${2:-}"; }
note() { local ROW_INK=$YEL; row "$M_NOTE" "$YEL" "$1"; }   # the whole line in amber, not only its mark
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

die() {
  if [ $IN_FRAME = 1 ]; then bad "error: $*"; else printf '\n%serror:%s %s\n' "$RED" "$OFF" "$*" >&2; fi
  exit 1
}

CODE=(ｦ ｱ ｳ ｴ ｵ ｶ ｷ ｹ ｺ ｻ ｼ ｽ ｾ ｿ ﾀ ﾂ ﾃ ﾅ ﾆ ﾇ ﾈ ﾊ ﾋ ﾎ ﾏ ﾐ ﾑ ﾒ ﾓ ﾔ ﾕ ﾗ ﾘ ﾜ 0 1 2 3 4 5 6 7 8 9)   # the game's falling code

rain() {   # rain WIDTH DENSITY: one row of falling code, DENSITY cells in ten filled
  local row="" i
  for ((i = 0; i < $1; i++)); do
    if [ $((RANDOM % 10)) -lt "$2" ]; then row="$row${CODE[RANDOM % ${#CODE[@]}]}"; else row="$row "; fi
  done
  printf '%s' "$row"
}

# The big letters are in the shapes of Miltown, a free typeface by Apostrophic Labs, traced into
# block characters: blocks for the strokes, thin lines for the streaks.
reveal() {   # reveal ROW…: rows of block letters, 72 columns, that come out of falling code a few columns at a time
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

banner() {   # the opening words: one of them in big letters, as a title would be, over the name of what this is
  [ $FANCY = 1 ] || return 0
  echo
  if [ $GLYPHS = 1 ] && [ $WIDTH -ge 76 ]; then
    printf ' %s%s%s\n %s%s%s\n' "$DIM" "$(rain $((WIDTH - 2)) 2)" "$OFF" "$DIM" "$(rain $((WIDTH - 2)) 4)" "$OFF"
    printf '  %sW I T N E S S%s\n' "$GRN" "$OFF"
    reveal \
      '   ▄▄▄▄▖  ▔▔▔▜███▙▄   ▔▔▔▝▙▄▄▄▄    ─▄▞▘▔  ▗▄▄▄▖   ▄▄▄▄▖─▗▖▔▔▐█▘   ▄     ' \
      '   █  ▝▌     ▐█   ▝      ▗▌  ▗▟     █▌    ▐   █   ▘  █▌     ▐█    █     ' \
      '   █▄▄▛▘     ▐█▄▄▄▖      ▝▜█▀▀█     █▌    ▐▄▄▟▀      █▌     ▝█▛▀▀▀█     ' \
      '▔▔▔█ ▝█▄     ▐█          ▗█  ▗▟▘▔▔  █▌  ▔▔▜ ▝▜▙      █▌▔▔▔   █    █▔▔▔  ' \
      '   ▀─  ▀▀────▀▀▀▀▀▀▔▔▔▀───▛▀▀▀▘   ─▀▀▀─   ▝─  ▀▀────▐▛▀─    ▝▀▘  ▁█     ' \
      '                                               Y O U R S E L F  ▝▀▀     '
    echo
  else
    printf '  %sWitness rebirth yourself.%s\n' "$ACC" "$OFF"
  fi
  printf '  %sThe Matrix Online%s  %ssetup for CrossOver on Apple Silicon%s\n' "$GRN" "$OFF" "$DIM" "$OFF"
}

SITE_SHOWN=0
site_frame() {   # the stats site under its own logo and in its blue; its first line is typed the first time
  local blink=$'\033[5m' knock="Knock, knock." i ch
  [ -z "${MXO_NO_ANIMATION:-}" ] || blink=""
  if [ $GLYPHS = 1 ]; then frame_close; fi
  local ACC=$SITE DIM=$SITE_DIM   # for this frame only: everything called from here draws in them
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
      # the empty row with its right edge first, then back to where the text starts
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

spin() {   # spin TITLE COMMAND…: a spinner while the command works; what it prints goes to the log
  local title=$1 start=$SECONDS rc=0 pid i=0 from stage="" line
  shift
  if [ $FANCY = 0 ]; then
    info "$title"
    ( "$@" ) </dev/null || rc=$?
    return $rc
  fi
  mkdir -p "$CACHE"
  printf '\n-- %s\n' "$title" >> "$LOG"
  from=$(( $(wc -c < "$LOG") + 1 ))
  ( "$@" ) >> "$LOG" 2>&1 </dev/null &
  pid=$!
  printf '\033[?25l'
  while kill -0 "$pid" 2>/dev/null; do
    # a long job names its stages on lines that start with "=="
    if [ $((i % 12)) = 0 ]; then
      stage=$(tail -c +"$from" "$LOG" 2>/dev/null | grep '^== ' | tail -1 | cut -c4- || true)
    fi
    moving "$i" "$title${stage:+ · $stage}" "$(clock "$start")"
    i=$((i + 1))
    sleep 0.08
  done
  wait "$pid" || rc=$?
  printf '\r\033[K\033[?25h'
  if [ $rc = 0 ]; then
    ok "$title" "$(clock "$start")"
  else
    bad "$title"
    tail -n 12 "$LOG" | while IFS= read -r line; do info "$line"; done
  fi
  return $rc
}

fetch_file() {   # fetch_file URL OUT TITLE [resume]: a download with a progress bar; curl's status
  local url=$1 out=$2 title=$3 resume=${4:-} rc=0 total pid have pct fill width tail i=0 rows=0
  if [ $FANCY = 0 ]; then
    info "$title"
    curl -L --fail -sS ${resume:+-C -} -o "$out" "$url" || rc=$?
    return $rc
  fi
  mkdir -p "$CACHE"
  total=$(curl -sIL --max-time 20 "$url" 2>/dev/null | tr -d '\r' \
    | awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }') || total=0
  if [ $GLYPHS = 1 ]; then
    row "$M_DOWN" "$GRN" "$title"
    rows=${#WRAPPED[@]}
  fi
  curl -L --fail -sS ${resume:+-C -} -o "$out" "$url" 2>> "$LOG" &
  pid=$!
  printf '\033[?25l'
  while kill -0 "$pid" 2>/dev/null; do
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
  wait "$pid" || rc=$?
  printf '\r\033[K\033[?25h'
  if [ $rows -gt 0 ]; then printf '\033[%dA\033[J' "$rows"; fi   # the title line goes; the result takes its place
  if [ $rc = 0 ]; then ok "$title" "$(mb "$(stat -f %z "$out")") MB"; else bad "$title"; fi
  return $rc
}

choose() {   # choose ITEM…: sets CHOICE to the index of the picked item
  local n=$# i key rest
  local items=("$@")
  CHOICE=0
  if [ $FANCY = 0 ]; then
    for ((i = 0; i < n; i++)); do printf '  %d) %s\n' $((i + 1)) "${items[i]}"; done
    read -r -p "   Number: " key || die "no answer"
    case "$key" in ''|*[!0-9]*) die "nothing chosen" ;; esac
    [ "$key" -ge 1 ] && [ "$key" -le "$n" ] || die "nothing chosen"
    CHOICE=$((key - 1))
    return 0
  fi
  printf '\033[?25l'
  while :; do
    for ((i = 0; i < n; i++)); do
      if [ $i = $CHOICE ]; then row "$M_PICK" "$ACC" "${items[i]}"; else row " " "" "${items[i]}"; fi
    done
    row " " "" "" "arrow keys, then Enter"
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
    printf '\033[%dA' $((n + 1))
  done
  printf '\033[%dA\033[J\033[?25h' $((n + 1))   # the list goes; the caller says what was picked
}

ask() {   # ask "question" [no] -> 0 for yes; Enter and --yes take the default, which is yes unless "no" is given
  local default=${2:-yes} hint="[Y/n]" answer i n last
  [ "$default" = yes ] || hint="[y/N]"
  if [ $YES = 1 ]; then
    if [ "$default" = yes ]; then return 0; else return 1; fi
  fi
  if [ $GLYPHS = 1 ]; then
    wrap $((WIDTH - 18)) "$1"
    n=${#WRAPPED[@]}
    last=${WRAPPED[n - 1]}
    for ((i = 0; i < n - 1; i++)); do
      printf '%s│%s %s%s%s %s%*s %s│%s\n' "$DIM" "$OFF" "$ACC" "$([ $i = 0 ] && echo "$M_ASK" || echo " ")" "$OFF" \
        "${WRAPPED[i]}" $((WIDTH - 6 - ${#WRAPPED[i]})) "" "$DIM" "$OFF"
    done
    # the frame's edge first, then back to where the answer goes
    printf '%s│%s %s%s%s %s %s%s%s%*s%s│%s\r\033[%dC' "$DIM" "$OFF" "$ACC" "$([ $n = 1 ] && echo "$M_ASK" || echo " ")" "$OFF" \
      "$last" "$DIM" "$hint" "$OFF" $((WIDTH - 11 - ${#last})) "" "$DIM" "$OFF" $((${#last} + 11))
    read -r answer || die "no answer"   # end of input is not a yes
  else
    read -r -p " $ACC$M_ASK$OFF $1 $DIM$hint$OFF " answer || die "no answer"
  fi
  case "$answer" in
    n|N|no|No) return 1 ;;
    y|Y|yes|Yes) return 0 ;;
  esac
  [ "$default" = yes ]
}

ask_text() {   # ask_text QUESTION: sets ANSWER to the line typed
  if [ $GLYPHS = 1 ]; then
    row "$M_ASK" "$ACC" "$1"
    printf '%s│%s %s%s%s ' "$DIM" "$OFF" "$ACC" "$M_PICK" "$OFF"
    read -r ANSWER || die "no answer"
  else
    read -r -p " $ACC$M_ASK$OFF $1 " ANSWER || die "no answer"
  fi
}

case "$FPS" in ''|*[!0-9]*) die "--fps takes a number, 0 for no limit" ;; esac
banner
site_frame

# --- the Mac ------------------------------------------------------------------------------------
# An Apple Silicon Mac with CrossOver. Everything here was made and tried on macOS 27.

MIN_MACOS=26
say "System"
[ "$(uname -s)" = Darwin ] || die "this is for macOS"
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] \
  || die "this is for Apple Silicon Macs; an Intel Mac gains nothing from it"
ok "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")"
MACOS=$(sw_vers -productVersion 2>/dev/null || true)
case "${MACOS%%.*}" in ''|*[!0-9]*) die "cannot read the macOS version" ;; esac
[ "${MACOS%%.*}" -ge $MIN_MACOS ] || die "macOS $MIN_MACOS or newer is needed; this Mac has macOS $MACOS"
ok "macOS $MACOS"
[ "${MACOS%%.*}" -ge 27 ] || note "tried on macOS 27 only"
[ -x "$WINE" ] || die "CrossOver not found in /Applications. Install it first: https://www.codeweavers.com/crossover"
ok "CrossOver $(defaults read "${CX%/SharedSupport/*}/Info" CFBundleShortVersionString 2>/dev/null || true)"

# Said before anything is installed: with the whole setup and with the game step. The one-command
# installer says it itself, before its own question.
case " ${STEPS:-all} " in
  *" all "*|*" game "*)
    if [ -z "${MXO_ADVISED:-}" ]; then
      say "Advice"
      note "Our advice: install and play under a separate, standard (non-admin) user account on your computer, with your main account behind its own password."
      info "A game client then cannot reach your everyday files and logins."
      if id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin; then
        info "You are in the account $(id -un), an administrator account."
      else
        ok "You are in the account $(id -un), a standard account."
      fi
    fi
    ;;
esac
if [ $FANCY = 1 ]; then mkdir -p "$CACHE"; : > "$LOG"; fi

# --- bottle -------------------------------------------------------------------------------------

wants_game() {   # only the game step may make a bottle; --yes leaves that step out unless it is named
  case " $STEPS " in *" game "*) return 0 ;; esac
  [ -z "$STEPS" ] && [ $YES = 0 ]
}

has_game() { [ -n "$(find "$1/drive_c" -maxdepth 4 -iname client.dll -size +5000k 2>/dev/null | head -1)" ]; }

create_bottle() {
  # as the CrossOver app makes one: MSync on, and installed programs get their icons in CrossOver
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
    wants_game && ask "No bottle called $BOTTLE yet. Create it?" || die "no bottle called $BOTTLE"
    create_bottle "$BOTTLE"
    return
  fi
  local list=() d
  for d in "$BOTTLES"/*/; do
    [ -f "$d/cxbottle.conf" ] && list+=("$(basename "$d")")
  done
  if [ ${#list[@]} = 0 ]; then
    wants_game || die "no CrossOver bottles found; the game step makes one (scripts/setup.sh game)"
    ask "No CrossOver bottle yet. Create one called $NEW_BOTTLE for the game?" || die "no bottle to work in"
    create_bottle "$NEW_BOTTLE"
    return
  fi
  if [ $YES = 1 ]; then
    BOTTLE=${list[0]}
  elif [ ${#list[@]} = 1 ] && { ! wants_game || has_game "$BOTTLES/${list[0]}"; }; then
    BOTTLE=${list[0]}
  else
    local items=("${list[@]}") new=0
    if wants_game && [ ! -e "$BOTTLES/$NEW_BOTTLE" ]; then
      new=1
      items+=("a new bottle called $NEW_BOTTLE")
    fi
    choose "${items[@]}"
    if [ $new = 1 ] && [ "$CHOICE" = ${#list[@]} ]; then
      create_bottle "$NEW_BOTTLE"
      return
    fi
    BOTTLE=${list[CHOICE]}
  fi
}

say "Bottle"
pick_bottle
B="$BOTTLES/$BOTTLE"
DRIVE="$B/drive_c"
SYS="$DRIVE/windows/syswow64"
field bottle "$BOTTLE"

reg_add() { "$WINE" --bottle "$BOTTLE" -- reg add "$1" /v "$2" /d "$3" /f >/dev/null 2>&1 || die "registry write failed: $1 $2"; }
reg_del() { "$WINE" --bottle "$BOTTLE" -- reg delete "$1" /v "$2" /f >/dev/null 2>&1 || true; }

game_running() { ps -axo comm= | grep -qiE '\\(matrix|mxorev)\.exe$'; }

is_wine_builtin() {   # Wine marks its own DLLs with this text in the DOS header
  [ -f "$1" ] && [ "$(dd if="$1" bs=1 skip=64 count=16 2>/dev/null)" = "Wine builtin DLL" ]
}

backup_once() { [ -f "$1" ] && [ ! -f "$1.setup-backup" ] && cp "$1" "$1.setup-backup" || true; }

# --- the game installs in this bottle ----------------------------------------------------------

INSTALLS=()      # folders that hold a client.dll
EXES=""
REVIVED=""

find_installs() {
  INSTALLS=(); EXES="matrix.exe"; REVIVED=""
  local f d
  while IFS= read -r f; do
    d=$(dirname "$f")
    case "$d" in */Temp/*|*/temp/*) continue ;; esac
    INSTALLS+=("$d")
    if [ -f "$d/MxORevived-Launcher.exe" ]; then
      REVIVED="$d"
      EXES="$EXES mxorev.exe"
    fi
  done < <(find "$DRIVE" -maxdepth 4 -iname client.dll -size +5000k 2>/dev/null | sort)
  EXES="$EXES$EXTRA_EXES"
}

show_installs() {
  local d
  if [ ${#INSTALLS[@]} = 0 ]; then
    field game "none in this bottle yet (no folder with client.dll)"
  else
    for d in "${INSTALLS[@]}"; do d=${d#"$DRIVE"}; field game "C:${d//\//\\}"; done
  fi
  field programs "$EXES"
}

client_dir() {   # the first game folder that is not Revived's own copy
  local d
  for d in "${INSTALLS[@]+"${INSTALLS[@]}"}"; do
    if [ "$d" != "$REVIVED" ]; then echo "$d"; return; fi
  done
}

find_installs
show_installs

# --- steps --------------------------------------------------------------------------------------

checksum() {   # checksum FILE EXPECTED: SHA-512 when the expected one has 128 digits, else SHA-256
  local bits=256
  [ ${#2} = 128 ] && bits=512
  shasum -a $bits "$1" | cut -d' ' -f1
}

download() {   # download URL CHECKSUM FILE FROM: into the cache, unless it is there already
  mkdir -p "$CACHE"
  local out="$CACHE/$3"
  if [ -f "$out" ] && [ "$(checksum "$out" "$2")" = "$2" ]; then return; fi
  fetch_file "$1" "$out.part" "Downloading $3 from $4" || die "$3: download failed"
  [ "$(checksum "$out.part" "$2")" = "$2" ] || { rm -f "$out.part"; die "$3: checksum does not match"; }
  mv "$out.part" "$out"
  ok "$3: checksum matches the published one"
}

page_link() {   # page_link PAGE NAME-PATTERN: "URL SHA256" of the installer a project's download page offers
  local page rc=0
  page=$(mktemp)
  curl -fsSL --max-time 60 -o "$page" "$1" || { rm -f "$page"; return 1; }
  python3 -I - "$page" "$1" "$2" <<'EOF' || rc=$?
import html, re, sys
from urllib.parse import urljoin
path, base, pattern = sys.argv[1:4]
page = open(path, encoding='utf-8', errors='replace').read()
link = re.search(r'href="([^"]*/)?(%s)"' % pattern, page)
if not link:
    sys.exit(1)
name = link.group(2)
url = urljoin(base, (link.group(1) or '') + name)
# the checksum the page prints after the file's name, before it names another file
text = html.unescape(re.sub(r'<[^>]*>', ' ', re.sub(r'(?s)<(script|style)\b.*?</\1>', ' ', page)))
found = re.search(re.escape(name) + r'(?:(?!\.exe|\.AppImage)[\s\S]){0,200}?\b([0-9A-Fa-f]{64})\b', text)
if not found or not url.startswith('https://'):
    sys.exit(1)
print(url, found.group(1).lower())
EOF
  rm -f "$page"
  return $rc
}

dotnet_link() {   # "URL SHA512" of the newest .NET 10 Desktop Runtime installer (x64), from Microsoft's release list
  local list rc=0
  list=$(mktemp)
  curl -fsSL --max-time 120 -o "$list" "$DOTNET_RELEASES" || { rm -f "$list"; return 1; }
  python3 -I - "$list" <<'EOF' || rc=$?
import json, sys
for release in json.load(open(sys.argv[1]))['releases']:   # newest first
    for f in (release.get('windowsdesktop') or {}).get('files') or []:
        if f.get('name') == 'windowsdesktop-runtime-win-x64.exe' and f.get('url', '').startswith('https://'):
            print(f['url'], f['hash'].lower())
            sys.exit(0)
sys.exit(1)
EOF
  rm -f "$list"
  return $rc
}

fetch() {   # fetch "URL CHECKSUM" FROM: downloads the installer into the cache and sets INSTALLER
  local url=${1%% *}
  INSTALLER=${url##*/}
  case "$INSTALLER" in ''|*[!A-Za-z0-9._-]*) die "unexpected file name in $url" ;; esac
  download "$url" "${1##* }" "$INSTALLER" "$2"
  INSTALLER="$CACHE/$INSTALLER"
}

wine_run() { "$WINE" --bottle "$BOTTLE" -- "$1" >/dev/null 2>&1 || true; }

run_installer() {   # the installer's own window: nothing is answered for the user
  spin "$(basename "$1") is open: click through its window" wine_run "$1" || true
}

installed() {   # installed WHAT TEST: after an installer, until its result is there or the user moves on
  local what=$1
  shift
  until "$@"; do
    if [ $YES = 1 ]; then note "$what: not found after its installer closed"; return 0; fi
    ask_text "$what: not found yet. Enter to look again once its installer has finished, s to skip:"
    case "$ANSWER" in s|S) note "$what: skipped"; return 0 ;; esac
  done
  ok "$what: installed"
}

rejacked_exe() { find "$DRIVE" -path "$DRIVE/windows" -prune -o -iname rejacked-launcher.exe -print 2>/dev/null | head -1; }
has_rejacked() { [ -n "$(rejacked_exe)" ]; }
has_dotnet() { ls -d "$DRIVE/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App"/10.* >/dev/null 2>&1; }
has_revived() { find_installs; [ -n "$REVIVED" ]; }

mxoemu_link() {   # the "Full Client" link on the MxOEmu project's page
  local link
  link=$(curl -fsSL --max-time 60 "$MXOEMU_PAGE" 2>/dev/null \
    | grep -oE 'https://[A-Za-z0-9./_-]*mxoemu\.info/[A-Za-z0-9./_-]*7\.6005[A-Za-z0-9._-]*\.7z' | head -1) || true
  [ -n "$link" ] && printf '%s\n' "$link"
}

get_client() {   # the game itself, into C:\Games\MxO: from MxOEmu, a folder, an archive or a direct link
  local target="$DRIVE/Games/MxO" unpack="$DRIVE/Games/.setup-unpack" from src downloaded="" part=0 rc=0
  info "The game itself: version 7.6005, about 6 GB, for C:\\Games\\MxO. Where does it come from?"
  [ $YES = 1 ] && return 0
  choose "Download it from the MxOEmu project (1.3 GB, mxoemu.info)" \
    "I have it: a folder, an archive file or a direct link" \
    "Skip: only Revived, whose installer downloads the game itself"
  case $CHOICE in
    0)
      from=$(mxoemu_link) || die "no client link found on $MXOEMU_PAGE; download it there and give the file instead" ;;
    1)
      ask_text "Where is it? (a folder or a file can be dragged in from Finder)"
      from=$ANSWER
      from=${from%"${from##*[![:space:]]}"}   # a path dragged in from Finder ends with a space
      case "$from" in \'*\'|\"*\") from=${from:1:${#from}-2} ;; esac
      case "$from" in "~/"*) from="$HOME/${from#\~/}" ;; esac
      [ -n "$from" ] || { note "nothing given, skipped"; return 0; } ;;
    *)
      note "skipped; Revived can still be installed"
      return 0 ;;
  esac
  case "$from" in
    http://*|https://*)
      mkdir -p "$CACHE"
      downloaded="$CACHE/client-$(printf %s "$from" | shasum | cut -c1-12).part"
      [ -s "$downloaded" ] && part=1
      fetch_file "$from" "$downloaded" "Downloading the game from ${from#*://}" resume || rc=$?
      case "$part$rc" in 122|133|136)   # the server would not continue an earlier download: from the start
        rm -f "$downloaded"
        rc=0
        fetch_file "$from" "$downloaded" "Downloading the game from ${from#*://}" || rc=$? ;;
      esac
      [ $rc = 0 ] || die "download failed"
      from="$downloaded" ;;
    *)
      [ -e "$from" ] || from=${from//\\/}   # and has its spaces escaped
      [ -e "$from" ] || die "not found: $from" ;;
  esac
  if [ -d "$from" ]; then
    src=$(find "$from" -maxdepth 3 -iname client.dll -size +5000k 2>/dev/null | head -1)
    [ -n "$src" ] || die "no client.dll in $from"
  else
    rm -rf "${unpack:?}"   # in the bottle, so the copy below is a clone and takes no second 6 GB
    mkdir -p "$unpack"
    if ! spin "Unpacking the game (some minutes)" tar -xf "$from" -C "$unpack"; then
      rm -rf "${unpack:?}"
      [ -n "$downloaded" ] && rm -f "$downloaded"
      die "could not unpack it (zip, 7z and tar archives work; a link has to lead to the file itself, not to a web page)"
    fi
    src=$(find "$unpack" -maxdepth 4 -iname client.dll -size +5000k 2>/dev/null | head -1)
    [ -n "$src" ] || { rm -rf "${unpack:?}"; die "no client.dll in that archive"; }
  fi
  mkdir -p "$target"
  spin "Copying the game into the bottle" cp -Rc "$(dirname "$src")/." "$target/" || die "copying failed"
  rm -rf "${unpack:?}"
  [ -n "$downloaded" ] && rm -f "$downloaded"
  # the client has no matrix.exe of its own: its launcher.exe runs under that name
  [ -f "$target/launcher.exe" ] || note "no launcher.exe next to client.dll; is that the whole game folder?"
  ok "game files in place: C:\\Games\\MxO"
}

rejacked_folder() {   # so that the launcher does not have to be told where the game is
  local d
  d=$(client_dir)
  [ -n "$d" ] && has_rejacked || return 0
  d=${d#"$DRIVE"}
  d="C:${d//\//\\}"
  if "$WINE" --bottle "$BOTTLE" -- reg query "$REJACKED_KEY" /v install_dir >/dev/null 2>&1; then
    ok "Rejacked launcher: a game folder is set already"
  elif ! spin "Telling the Rejacked launcher where the game is: $d" \
    "$WINE" --bottle "$BOTTLE" -- reg add "$REJACKED_KEY" /v install_dir /d "$d" /f; then
    note "could not set it; choose $d in the launcher's settings"
  fi
}

step_game() {
  say "Game"
  local link kind d

  # 1. the game itself: Rejacked needs it, Revived copies it
  d=$(client_dir)
  if [ -n "$d" ]; then
    d=${d#"$DRIVE"}
    ok "game files: C:${d//\//\\}"
  else
    get_client
    find_installs
  fi

  # 2. MxO Rejacked: the launcher from its site
  if has_rejacked; then
    ok "Rejacked launcher: already installed"
  elif ask "Install the MxO Rejacked launcher (downloaded from mxo-rejacked.com)?"; then
    if link=$(page_link "$REJACKED_PAGE" 'rejacked-launcher-[0-9.]+-win64\.exe'); then
      fetch "$link" mxo-rejacked.com
      note "On the installer's last page, do not start the launcher yet: the setup has more to do first."
      run_installer "$INSTALLER"
      installed "Rejacked launcher" has_rejacked
    else
      note "no installer with a checksum found on $REJACKED_PAGE; install the launcher by hand (docs/crossover.md)"
    fi
  fi

  # 3. MxO Revived: its setup copies the game that is in the bottle, or its installer downloads one
  if [ -n "$REVIVED" ]; then
    ok "Revived: already installed"
  elif ask "Install MxO Revived (downloaded from mxorevived.com)?"; then
    if ! has_dotnet; then   # Revived's launcher needs it
      if link=$(dotnet_link); then
        fetch "$link" Microsoft
        run_installer "$INSTALLER"
        installed ".NET 10 Desktop Runtime" has_dotnet
      else
        note "could not read Microsoft's .NET release list; Revived's launcher will ask for the .NET 10 Desktop Runtime"
      fi
    fi
    kind=Installer
    [ -n "$(client_dir)" ] && kind=Setup
    if link=$(page_link "$REVIVED_PAGE" "MxORevived-$kind\\.exe"); then
      fetch "$link" mxorevived.com
      if [ $kind = Installer ]; then
        info "It downloads the game (1.3 GB) into its own folder. Keep the folder it offers, C:\\Games\\MxO Revived."
      else
        d=$(client_dir)
        d=${d#"$DRIVE"}
        info "It makes Revived's own copy of the game that is in this bottle."
        note "Its window asks where The Matrix Online is installed. Choose C:${d//\//\\} there."
        note "Keep the folder it offers for Revived itself, C:\\Games\\MxO Revived."
      fi
      note "When it finishes, do not start the game yet: the setup has more to do first."
      run_installer "$INSTALLER"
      installed "MxO Revived" has_revived
    else
      note "no installer with a checksum found on $REVIVED_PAGE; install Revived by hand (docs/crossover.md)"
    fi
  fi

  find_installs
  rejacked_folder
  show_installs
}

write_start_overrides() {   # each registry write starts Wine once, which takes a moment
  local f exe
  reg_add 'HKCU\Software\Wine\DllOverrides' d3dcompiler_43 native,builtin
  for f in $DM_DLLS; do
    [ "$f" = dsound ] && continue   # DirectSound only for the game, below
    reg_add 'HKCU\Software\Wine\DllOverrides' "$f" native,builtin
  done
  for exe in $EXES; do
    reg_add "HKCU\\Software\\Wine\\AppDefaults\\$exe\\DllOverrides" dsound native,builtin
  done
}

step_bottle() {
  say "Start fixes"
  info "What the game needs to start at all."
  local src="" d f tmp

  # 1. shader compiler: the game ships Microsoft's; Wine's cannot handle the game's shaders
  for d in "${INSTALLS[@]+"${INSTALLS[@]}"}"; do
    [ -f "$d/D3DCompiler_43.dll" ] && { src="$d/D3DCompiler_43.dll"; break; }
  done
  if [ -n "$src" ] && ! cmp -s "$src" "$SYS/d3dcompiler_43.dll"; then
    backup_once "$SYS/d3dcompiler_43.dll"
    cp "$src" "$SYS/d3dcompiler_43.dll"
    ok "shader compiler: copied the game's d3dcompiler_43.dll"
  elif [ -n "$src" ]; then
    ok "shader compiler: already in place"
  else
    note "shader compiler: no game folder yet, skipped"
  fi

  # 2. DirectMusic and DirectSound: Wine's DirectMusic hangs on this game; Microsoft's needs Microsoft's DirectSound
  if is_wine_builtin "$SYS/dmime.dll" || [ ! -f "$SYS/dmime.dll" ]; then
    download "$DX2010_URL" "$DX2010_SHA" directx_feb2010_redist.exe "Microsoft, via the Internet Archive"
    tmp=$(mktemp -d)
    tar -xf "$CACHE/directx_feb2010_redist.exe" -C "$tmp" dxnt.cab
    for f in $DM_DLLS; do tar -xf "$tmp/dxnt.cab" -C "$tmp" "$f.dll"; done
    for f in $DM_DLLS; do backup_once "$SYS/$f.dll"; cp "$tmp/$f.dll" "$SYS/$f.dll"; done
    rm -rf "$tmp"
    ok "DirectMusic and DirectSound: Microsoft's DLLs installed"
  else
    ok "DirectMusic and DirectSound: Microsoft's DLLs already in place"
  fi

  if [ ! -f "$SYS/drivers/gm.dls" ]; then
    download "$DX2006_URL" "$DX2006_SHA" directx_apr2006_redist.exe "Microsoft, via the Internet Archive"
    tmp=$(mktemp -d)
    tar -xf "$CACHE/directx_apr2006_redist.exe" -C "$tmp" DirectX.cab
    tar -xf "$tmp/DirectX.cab" -C "$tmp" gm16.dls
    mkdir -p "$SYS/drivers" "$DRIVE/windows/system32/drivers"
    cp "$tmp/gm16.dls" "$SYS/drivers/gm.dls"
    cp "$tmp/gm16.dls" "$DRIVE/windows/system32/drivers/gm.dls"
    rm -rf "$tmp"
    ok "music sound bank: gm.dls installed"
  else
    ok "music sound bank: already in place"
  fi

  spin "Telling Wine to use them for $EXES (registry)" write_start_overrides \
    || die "a registry write failed; see $LOG"

  set_env WINE_LARGE_ADDRESS_AWARE 1
  ok "large address space for 32-bit programs (the game crashed after a minute without it)"
}

set_env() {   # set_env NAME VALUE: in cxbottle.conf, [EnvironmentVariables]
  backup_once "$B/cxbottle.conf"
  python3 -I - "$B/cxbottle.conf" "$1" "$2" <<'EOF'
import re, sys
path, name, value = sys.argv[1:4]
text = open(path, encoding='utf-8', errors='surrogateescape').read()
line = '"%s" = "%s"' % (name, value)
pattern = re.compile(r'^"%s"\s*=.*$' % re.escape(name), re.M)
if pattern.search(text):
    text = pattern.sub(line, text, count=1)
elif '[EnvironmentVariables]' in text:
    text = text.replace('[EnvironmentVariables]\n', '[EnvironmentVariables]\n' + line + '\n', 1)
else:
    text = text.rstrip('\n') + '\n\n[EnvironmentVariables]\n' + line + '\n'
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(text)
EOF
}

unset_env() {
  python3 -I - "$B/cxbottle.conf" "$1" <<'EOF'
import re, sys
path, name = sys.argv[1:3]
text = open(path, encoding='utf-8', errors='surrogateescape').read()
text = re.sub(r'^"%s"\s*=.*\n' % re.escape(name), '', text, flags=re.M)
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(text)
EOF
}

build_client() {   # one DLL serves every install: each routine is checked against the client in memory at
  local d            # start. Prefer a client that is not Revived's: in Revived's one routine cannot be translated.
  d=$(client_dir)
  echo "${d:-${INSTALLS[0]}}/client.dll"
}

needs_build() {   # no DLL yet, or the sources or the game changed since it was built
  local dll="$ROOT/build/d3d9.dll"
  [ -f "$dll" ] || return 0
  [ -n "$(find "$ROOT/dxvk" "$ROOT/translator" "$ROOT/scripts/build.sh" "$(build_client)" -newer "$dll" 2>/dev/null | head -1)" ]
}

step_build() {
  say "Speed-up: build"
  [ ${#INSTALLS[@]} -gt 0 ] || die "no client.dll in this bottle; install a game first"
  local missing="" tool client shown
  # Homebrew is not on every account's PATH
  if ! command -v meson >/dev/null && [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
  for tool in i686-w64-mingw32-g++ meson ninja glslangValidator python3 patch; do
    command -v "$tool" >/dev/null || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    note "missing tools:$missing"
    note "install them with:  brew install mingw-w64 meson ninja glslang"
    exit 1
  fi
  client=$(build_client)
  shown=${client#"$DRIVE"}
  spin "Building d3d9.dll from C:${shown//\//\\} (5 to 10 minutes)" "$ROOT/scripts/build.sh" "$client" \
    || die "the build failed; its output is in $LOG"
  DLL="$ROOT/build/d3d9.dll"
}

FPS_LIMIT=""   # yes or no, once asked
choose_fps() {   # without a limit the game draws up to 200 fps in light scenes, which only makes heat and fan noise
  [ -z "$FPS_LIMIT" ] || return 0
  if [ "$FPS" -gt 0 ] && ask "Limit the frame rate to $FPS fps (quieter fans)?"; then FPS_LIMIT=yes; else FPS_LIMIT=no; fi
}

ADDONS=""   # replace or keep, once asked
choose_addons() {   # add-on files next to the game (mx*.dll) hook some of the routines the speed-up replaces
  [ -z "$ADDONS" ] || return 0
  if ask "Speed up the routines that game add-ons hook, too? An add-on such as Revived's interface scaling can then stop working."; then
    ADDONS=replace
  else
    ADDONS=keep
  fi
}

write_d3d9_overrides() {
  local exe
  reg_add 'HKCU\Software\Wine\DllOverrides' d3d9 builtin   # everything else keeps Wine's Direct3D 9
  for exe in $EXES; do
    reg_add "HKCU\\Software\\Wine\\AppDefaults\\$exe\\DllOverrides" d3d9 native,builtin
  done
}

step_install() {
  say "Speed-up: install"
  [ -n "$DLL" ] || DLL="$ROOT/build/d3d9.dll"
  [ -f "$DLL" ] || die "no $DLL; run the build step first"
  game_running && die "close the game first"
  choose_fps
  choose_addons
  backup_once "$SYS/d3d9.dll"
  cp "$DLL" "$SYS/d3d9.dll.new" && mv "$SYS/d3d9.dll.new" "$SYS/d3d9.dll"
  spin "Switching $EXES to the new Direct3D 9 (registry)" write_d3d9_overrides \
    || die "a registry write failed; see $LOG"
  mkdir -p "$DRIVE/Games/dxvk"
  set_env MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS 1
  set_env WINE_LARGE_ADDRESS_AWARE 1
  set_env DXVK_LOG_PATH C:/Games/dxvk
  set_env DXVK_STATE_CACHE_PATH C:/Games/dxvk
  set_env DXVK_HUD fps,frametimes,gpuload   # the overlay stays hidden until Ctrl+Shift+F
  if [ "$FPS_LIMIT" = yes ]; then
    set_env DXVK_FRAME_RATE "$FPS"
    ok "frame rate limited to $FPS fps"
  else
    unset_env DXVK_FRAME_RATE
  fi
  if [ "$ADDONS" = replace ]; then   # without it the DLL leaves alone every routine an add-on file points into
    set_env DXVK_MXO_RESPECT_ADDONS 0
    ok "routines that game add-ons hook are replaced too"
  else
    unset_env DXVK_MXO_RESPECT_ADDONS
  fi
  # every executable starts with the pipelines the others have already built
  local caches=() c
  for c in "$DRIVE/Games/dxvk"/*.dxvk-cache; do [ -f "$c" ] && caches+=("$c"); done
  if [ ${#caches[@]} -ge 2 ]; then
    info "pipeline caches $(python3 -I "$ROOT/scripts/merge-pipeline-caches.py" "${caches[@]}" | tail -1)"
  fi
  ok "installed for: $EXES"
  info "Ctrl+Shift+F in the game shows the frame rate."
  info "Leave the bottle's Graphics setting in CrossOver on Auto; the log is in C:\\Games\\dxvk."
}

# What the game writes into options.cfg with every Video Options control at its highest, the detail and
# memory presets on Custom, and "Scale LOD with Frame Rate" off (Client_RenderThrottle_Override = 1:
# the draw distance no longer shrinks when the frame rate drops).
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

set_options() {   # set_options FILE "KEY = VALUE lines": changes those keys (any case), adds the missing ones
  mkdir -p "$(dirname "$1")"
  backup_once "$1"
  python3 -I - "$1" "$2" <<'EOF'
import os, re, sys
path, wanted = sys.argv[1:3]
raw = open(path, 'rb').read().decode('latin-1') if os.path.exists(path) else ''
nl = '\n' if raw and '\r\n' not in raw else '\r\n'
lines = raw.split(nl) if raw else []
while lines and lines[-1] == '':
    lines.pop()
for item in wanted.split('\n'):
    if '=' not in item:
        continue
    key, value = [p.strip() for p in item.split('=', 1)]
    pattern = re.compile(r'^\s*%s\s*=' % re.escape(key), re.I)
    for i, line in enumerate(lines):
        if pattern.match(line):
            lines[i] = '%s = %s' % (line.split('=', 1)[0].strip(), value)
            break
    else:
        lines.append('%s = %s' % (key, value))
open(path, 'wb').write((nl.join(lines) + nl).encode('latin-1'))
EOF
}

options_files() {   # the options.cfg of every game in the bottle: Revived's is in its folder, the others share one
  [ -z "$(client_dir)" ] || echo "$DRIVE/users/crossover/AppData/Roaming/The Matrix Online/options.cfg"
  [ -z "$REVIVED" ] || echo "$REVIVED/options.cfg"
}

SCREEN_W="" SCREEN_H="" SCREEN_ASKED=0
screen_size() {   # SCREEN_W and SCREEN_H: the main display as the bottle sees it; empty when it cannot be read
  [ $SCREEN_ASKED = 0 ] || return 0
  SCREEN_ASKED=1
  local out
  out=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var s = $.NSScreen.screens.objectAtIndex(0);
    Math.round(s.frame.size.width) + " " + Math.round(s.frame.size.height) + " " + s.backingScaleFactor' 2>/dev/null) || return 0
  set -- $out
  case "${1:-x}${2:-x}" in *[!0-9]*) return 0 ;; esac
  SCREEN_W=$1 SCREEN_H=$2
  # a bottle in CrossOver's high-resolution mode counts the display's pixels, not its points
  if [ "${3:-1}" = 2 ] && grep -qi '^"RetinaMode"="y' "$B/user.reg" 2>/dev/null; then
    SCREEN_W=$((SCREEN_W * 2)); SCREEN_H=$((SCREEN_H * 2))
  fi
}

step_detail() {
  say "Detail: everything at maximum"
  game_running && die "close the game first; it writes its options when it closes"
  local f conf="$DRIVE/Games/dxvk/dxvk.conf" values=$MAX_DETAIL
  screen_size
  if [ -n "$SCREEN_W" ]; then   # options.cfg wins over the size in a launcher's block of useropts.cfg
    values="$values
ScreenWidth = $SCREEN_W
ScreenHeight = $SCREEN_H"
  fi
  while IFS= read -r f; do
    set_options "$f" "$values"
    f=${f#"$DRIVE"}
    ok "C:${f//\//\\}"
  done < <(options_files)
  info "Draw distance, shadows, wet streets, weather, grass, traffic, anti-aliasing and both screen filters."
  if [ -n "$SCREEN_W" ]; then
    ok "resolution ${SCREEN_W}x$SCREEN_H, the main display's"
  else
    note "could not read the display's size; the resolution stays as it is"
  fi
  # sharp ground and walls at shallow angles; DXVK reads this file when the game starts
  set_options "$conf" "d3d9.samplerAnisotropy = 16"
  set_env DXVK_CONFIG_FILE C:/Games/dxvk/dxvk.conf
  ok "16x anisotropic filtering"
  info "The window mode stays as the launchers set it."
}

useropts_files() {   # the useropts.cfg next to each of those
  local f
  while IFS= read -r f; do echo "$(dirname "$f")/useropts.cfg"; done < <(options_files)
}

intro_off() {   # every game skips its logo movies already
  local f
  while IFS= read -r f; do
    grep -qiE '^[[:space:]]*EnableSplash[[:space:]]*=[[:space:]]*0' "$f" 2>/dev/null || return 1
  done < <(useropts_files)
}

step_intro() {
  say "Intro: no logo movies"
  local f
  while IFS= read -r f; do   # the game does not keep this one in options.cfg; a launcher leaves the line alone
    set_options "$f" "EnableSplash = 0"
    f=${f#"$DRIVE"}
    ok "C:${f//\//\\}"
  done < <(useropts_files)
  info "The game starts without the logo movies."
}

step_music() {
  say "Revived: music"
  if [ -z "$REVIVED" ]; then note "MxO Revived is not in this bottle"; return 0; fi
  # Revived's starter checks the music system outside the game, on Wine's DirectSound, where the check
  # fails. It then switches the music off, unless its guard file says "music = on". Written before the
  # first start too, so that it never gets that far.
  local guard="$REVIVED/MxORevived-audio.txt" f
  backup_once "$guard"
  python3 -I - "$guard" <<'EOF'
import os, re, sys
p = sys.argv[1]
t = open(p, 'rb').read().decode('utf-8-sig') if os.path.exists(p) else ''
if re.search(r'(?m)^music\s*=', t):
    t = re.sub(r'(?m)^music\s*=[^\r\n]*', 'music = on', t)
else:
    t += ('' if not t or t.endswith('\n') else '\r\n') + 'music = on\r\n'
open(p, 'wb').write(t.encode('utf-8'))
EOF
  # what the starter already switched off; options.cfg wins over useropts.cfg
  for f in "$REVIVED/options.cfg" "$REVIVED/useropts.cfg"; do
    [ -f "$f" ] || continue
    backup_once "$f"
    python3 -I - "$f" <<'EOF'
import os, re, sys
p = sys.argv[1]; s = open(p, 'rb').read().decode('latin-1')
nl = '\r\n' if '\r\n' in s else '\n'
if re.search(r'(?m)^MusicSystemEnable\s*=', s):
    s = re.sub(r'(?m)^MusicSystemEnable\s*=[^\r\n]*', 'MusicSystemEnable = 1', s)
elif os.path.basename(p).lower() == 'options.cfg':
    s = s.rstrip('\r\n') + nl + 'MusicSystemEnable = 1' + nl
open(p, 'wb').write(s.encode('latin-1'))
EOF
  done
  ok "music on: in the starter's guard file and in Revived's settings"
}

step_video() {
  say "Revived: launcher video"
  if [ -z "$REVIVED" ]; then note "MxO Revived is not in this bottle"; return 0; fi
  local settings="$REVIVED/launcher-settings.json"
  if [ ! -f "$settings" ]; then
    note "the launcher has no settings file yet; start it once, close it and run this step again (setup.sh video)"
    return 0
  fi
  # the launcher writes its settings when it closes, which would undo this
  if ps -xo comm= | grep -qi 'MxORevived-Launcher\.exe$'; then
    note "close the Revived launcher first, then run this step again (setup.sh video)"
    return 0
  fi
  backup_once "$settings"
  python3 -I - "$settings" <<'EOF'
import json, re, sys
p = sys.argv[1]; raw = open(p, 'rb').read()
bom = raw.startswith(b'\xef\xbb\xbf')
s = raw.decode('utf-8-sig')
new, n = re.subn(r'("BackgroundVideo"\s*:\s*)true', r'\1false', s)
if n == 0 and '"BackgroundVideo"' not in s:
    data = json.loads(s)
    data['BackgroundVideo'] = False
    new = json.dumps(data, indent=2).replace('\n', '\r\n')
open(p, 'wb').write((b'\xef\xbb\xbf' if bom else b'') + new.encode('utf-8'))
EOF
  ok "the video behind the launcher's window is off"
}

# CrossOver shows an icon for each shortcut in the bottle's Start Menu and on its Desktop. It keeps its
# own list of them (cxmenu.conf), which "cxmenu --sync" brings up to date.
has_icon() { grep -qiF "/$1.lnk]" "$B/cxmenu.conf" 2>/dev/null; }

step_icons() {
  say "Icons"
  local exe win
  spin "CrossOver reads the bottle's shortcuts again" "$CX/bin/cxmenu" --bottle "$BOTTLE" --sync --mode install \
    || note "CrossOver could not read the bottle's shortcuts"
  exe=$(rejacked_exe)
  if [ -z "$exe" ]; then info "The Rejacked launcher is not in this bottle."; return 0; fi
  if has_icon "Rejacked Launcher"; then ok "Rejacked launcher: CrossOver has its shortcut"; return 0; fi
  # the launcher is installed, but no shortcut to it is in the bottle: one made with CrossOver's own tool
  win=${exe#"$DRIVE"}
  win="C:${win//\//\\}"
  spin "Rejacked launcher: no shortcut in the bottle, making one" \
    "$WINE" --bottle "$BOTTLE" -- cxmklnk --programs "Rejacked Launcher.lnk" --target "$win" --workdir "${win%\\*}" || true
  "$CX/bin/cxmenu" --bottle "$BOTTLE" --sync --mode install >/dev/null 2>&1 || true
  if has_icon "Rejacked Launcher"; then
    ok "Rejacked launcher: its icon is back in CrossOver"
  else
    note "CrossOver has no icon for the Rejacked launcher. It starts with the bottle's Run Command: $win"
  fi
}

step_uninstall() {
  say "Uninstall"
  info "The game executables go back to Wine's Direct3D 9."
  game_running && die "close the game first"
  for exe in $EXES; do
    reg_del "HKCU\\Software\\Wine\\AppDefaults\\$exe\\DllOverrides" d3d9
  done
  if [ -f "$SYS/d3d9.dll.setup-backup" ]; then
    cp "$SYS/d3d9.dll.setup-backup" "$SYS/d3d9.dll"
  fi
  for v in DXVK_LOG_PATH DXVK_STATE_CACHE_PATH DXVK_HUD DXVK_FRAME_RATE DXVK_CONFIG_FILE DXVK_MXO_RESPECT_ADDONS; do
    unset_env "$v"
  done
  ok "done; DirectMusic, DirectSound and the large address space stay, the game needs them"
}

# --- run ----------------------------------------------------------------------------------------

game_running && note "a game is running; steps that replace files will refuse until it is closed"

if [ -z "$STEPS" ]; then
  # the installers need clicks, so --yes leaves the game step out
  if [ $YES = 0 ] && [ ${#INSTALLS[@]} = 0 ]; then step_game; fi
  if [ ${#INSTALLS[@]} = 0 ]; then
    say "No game in this bottle yet"
    info "Run the setup again once it is there."
    exit 0
  fi

  # The questions come first; after them the setup works by itself. The start fixes and the speed-up
  # are not asked about: without them the game shows a black screen or runs at about 15 fps.
  if [ $YES = 0 ]; then say "Options"; fi
  choose_fps
  choose_addons
  # Maximum detail replaces the detail settings a game has: once a game has settings, the answer
  # defaults to no, and --yes leaves them alone.
  screen_size
  q="Set every graphics option to its maximum"
  [ -z "$SCREEN_W" ] || q="$q, at this display's resolution (${SCREEN_W}x$SCREEN_H)"
  q="$q?"
  fresh=yes
  while IFS= read -r f; do
    [ ! -f "$f" ] || fresh=no
  done < <(options_files)
  MAX_OUT=0
  if [ $fresh = yes ]; then
    if ask "$q"; then MAX_OUT=1; fi
  elif ask "$q It replaces the detail settings the games have now." no; then
    MAX_OUT=1
  fi
  NO_INTRO=0
  if ! intro_off && ask "Skip the logo movies when the game starts?"; then NO_INTRO=1; fi
  VIDEO_OFF=0   # the launcher writes its settings file at its first start; before that there is nothing to change
  if [ -n "$REVIVED" ] && [ -f "$REVIVED/launcher-settings.json" ] \
    && ask "Switch off the video behind Revived's launcher (it keeps a processor core busy)?"; then
    VIDEO_OFF=1
  fi

  step_bottle
  if needs_build; then
    step_build
  else
    say "Speed-up: build"
    ok "already built from these sources and this game (setup.sh build builds it again)"
  fi
  step_install
  if [ $MAX_OUT = 1 ]; then step_detail; fi
  if [ $NO_INTRO = 1 ]; then step_intro; fi
  if [ -n "$REVIVED" ]; then step_music; fi
  if [ $VIDEO_OFF = 1 ]; then step_video; fi
else
  for s in $STEPS; do "step_$s"; done
fi

case " $STEPS " in   # every run but these ends with a look at the Rejacked launcher's icon
  *" uninstall "*|*" icons "*) ;;
  *) if has_rejacked && ! has_icon "Rejacked Launcher"; then step_icons; fi ;;
esac

say "Done"
case " $STEPS " in
  *" uninstall "*) ;;
  *)
    ok "Start the game from its launcher."
    if [ -n "$REVIVED" ] && [ ! -f "$REVIVED/launcher-settings.json" ]; then
      info "Revived's launcher plays a video that keeps a processor core busy. After its first start, \"setup.sh video\" switches it off."
    fi
    ;;
esac
site_frame
frame_close
if [ $GLYPHS = 1 ]; then printf ' %s%s%s\n' "$DIM" "$(rain $((WIDTH - 2)) 3)" "$OFF"; fi
