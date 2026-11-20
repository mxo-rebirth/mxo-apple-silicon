#!/bin/bash
# Guided setup of The Matrix Online in a CrossOver bottle, for any MxO install (Rejacked, Revived or
# another project's client). Run it from the repository folder:
#
#   scripts/setup.sh                      everything, asking before each step
#   scripts/setup.sh --yes                everything, no questions (first bottle found)
#   scripts/setup.sh --bottle NAME step…  only the named steps, in the named bottle
#
# Steps:
#   bottle     what the game needs to start: Microsoft's shader compiler, DirectMusic and DirectSound
#   build      build d3d9.dll from this bottle's own client.dll (needs the tools in BUILD.md)
#   install    install that d3d9.dll for the game executables, with the bottle settings it needs
#   music      Revived only: undo the starter's "music = off" guard
#   uninstall  the game executables go back to Wine's Direct3D 9 (DirectMusic stays; it is needed)
#
# The script never reads passwords, launcher logins or credential stores, and never prints command
# lines of running programs. Every file it replaces is kept with a ".setup-backup" suffix.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CX=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver
WINE="$CX/bin/wine"
BOTTLES="$HOME/Library/Application Support/CrossOver/Bottles"
CACHE="$HOME/Library/Caches/mxo-apple-silicon"

# Microsoft's DirectX redistributables, as used by winetricks for the same files
DX2010_URL="https://web.archive.org/web/20100205000000id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe"
DX2010_SHA=f6d191e89a963d7cca34f169d30f49eab99c1ed3bb92da73ec43617caaa1e93f
DX2006_URL="https://web.archive.org/web/20100920035904/https://download.microsoft.com/download/3/9/7/3972f80c-5711-4e14-9483-959d48a2d03b/directx_apr2006_redist.exe"
DX2006_SHA=dd8c3d401efe4561b67bd88475201b2f62f43cd23e4acc947bb34a659fa74952
DM_DLLS="dmband dmcompos dmime dmloader dmscript dmstyle dmsynth dmusic dswave dsound"

YES=0
BOTTLE=""
DLL=""
EXTRA_EXES=""
STEPS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --bottle) BOTTLE="$2"; shift ;;
    --dll) DLL="$2"; shift ;;
    --exe) EXTRA_EXES="$EXTRA_EXES $2"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    bottle|build|install|music|uninstall) STEPS="$STEPS $1" ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

say()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }

ask() {   # ask "question" -> 0 for yes
  [ $YES = 1 ] && return 0
  local answer
  read -r -p "   $1 [Y/n] " answer || die "no answer"   # end of input is not a yes
  case "$answer" in n|N|no|No) return 1 ;; *) return 0 ;; esac
}

[ -x "$WINE" ] || die "CrossOver not found in /Applications"

# --- bottle -------------------------------------------------------------------------------------

pick_bottle() {
  if [ -n "$BOTTLE" ]; then
    [ -f "$BOTTLES/$BOTTLE/cxbottle.conf" ] || die "no bottle called $BOTTLE"
    return
  fi
  local list=() d
  for d in "$BOTTLES"/*/; do
    [ -f "$d/cxbottle.conf" ] && list+=("$(basename "$d")")
  done
  [ ${#list[@]} -gt 0 ] || die "no CrossOver bottles found; create one first (CROSSOVER.md, step 1)"
  if [ ${#list[@]} = 1 ] || [ $YES = 1 ]; then
    BOTTLE=${list[0]}
  else
    echo "Bottles:"
    local i=1
    for d in "${list[@]}"; do echo "  $i) $d"; i=$((i + 1)); done
    read -r -p "Which one? " i
    BOTTLE=${list[$((i - 1))]:-}
    [ -n "$BOTTLE" ] || die "no bottle chosen"
  fi
}

pick_bottle
B="$BOTTLES/$BOTTLE"
DRIVE="$B/drive_c"
SYS="$DRIVE/windows/syswow64"
echo "Bottle: $BOTTLE"

reg_add() { "$WINE" --bottle "$BOTTLE" -- reg add "$1" /v "$2" /d "$3" /f >/dev/null 2>&1 || die "registry write failed: $1 $2"; }
reg_del() { "$WINE" --bottle "$BOTTLE" -- reg delete "$1" /v "$2" /f >/dev/null 2>&1 || true; }

game_running() { ps -axo comm= | grep -qiE '\\(matrix|mxorev)\.exe$'; }

is_wine_builtin() {   # Wine marks its own DLLs with this text in the DOS header
  [ -f "$1" ] && [ "$(dd if="$1" bs=1 skip=64 count=16 2>/dev/null)" = "Wine builtin DLL" ]
}

backup_once() { [ -f "$1" ] && [ ! -f "$1.setup-backup" ] && cp "$1" "$1.setup-backup" || true; }

# --- the game installs in this bottle ----------------------------------------------------------

INSTALLS=()      # folders that hold a client.dll
EXES="matrix.exe"
REVIVED=""
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

if [ ${#INSTALLS[@]} = 0 ]; then
  info "no MxO install (a folder with client.dll) found in this bottle yet"
else
  for d in "${INSTALLS[@]}"; do info "game folder: C:${d#"$DRIVE"}"; done
fi
info "game executables: $EXES"

# --- steps --------------------------------------------------------------------------------------

download() {   # download URL SHA256 FILE
  mkdir -p "$CACHE"
  local out="$CACHE/$3"
  if [ -f "$out" ] && [ "$(shasum -a 256 "$out" | cut -c1-64)" = "$2" ]; then return; fi
  info "downloading $3 (Microsoft, via the Internet Archive)"
  curl -L --fail --progress-bar -o "$out.part" "$1"
  [ "$(shasum -a 256 "$out.part" | cut -c1-64)" = "$2" ] || { rm -f "$out.part"; die "$3: checksum does not match"; }
  mv "$out.part" "$out"
}

step_bottle() {
  say "Bottle: what the game needs to start"

  # 1. shader compiler: the game ships Microsoft's; Wine's cannot handle the game's shaders
  local src=""
  for d in "${INSTALLS[@]+"${INSTALLS[@]}"}"; do
    [ -f "$d/D3DCompiler_43.dll" ] && { src="$d/D3DCompiler_43.dll"; break; }
  done
  if [ -n "$src" ] && ! cmp -s "$src" "$SYS/d3dcompiler_43.dll"; then
    backup_once "$SYS/d3dcompiler_43.dll"
    cp "$src" "$SYS/d3dcompiler_43.dll"
    info "shader compiler: copied the game's d3dcompiler_43.dll"
  else
    info "shader compiler: ${src:+already in place}${src:-no game folder yet, skipped}"
  fi
  reg_add 'HKCU\Software\Wine\DllOverrides' d3dcompiler_43 native,builtin

  # 2. DirectMusic and DirectSound: Wine's DirectMusic hangs on this game; Microsoft's needs Microsoft's DirectSound
  if is_wine_builtin "$SYS/dmime.dll" || [ ! -f "$SYS/dmime.dll" ]; then
    download "$DX2010_URL" "$DX2010_SHA" directx_feb2010_redist.exe
    local tmp; tmp=$(mktemp -d)
    tar -xf "$CACHE/directx_feb2010_redist.exe" -C "$tmp" dxnt.cab
    for f in $DM_DLLS; do tar -xf "$tmp/dxnt.cab" -C "$tmp" "$f.dll"; done
    for f in $DM_DLLS; do backup_once "$SYS/$f.dll"; cp "$tmp/$f.dll" "$SYS/$f.dll"; done
    rm -rf "$tmp"
    info "DirectMusic and DirectSound: Microsoft's DLLs installed"
  else
    info "DirectMusic and DirectSound: Microsoft's DLLs already in place"
  fi
  for f in $DM_DLLS; do
    [ "$f" = dsound ] && continue   # DirectSound only for the game, below
    reg_add 'HKCU\Software\Wine\DllOverrides' "$f" native,builtin
  done

  if [ ! -f "$SYS/drivers/gm.dls" ]; then
    download "$DX2006_URL" "$DX2006_SHA" directx_apr2006_redist.exe
    local tmp; tmp=$(mktemp -d)
    tar -xf "$CACHE/directx_apr2006_redist.exe" -C "$tmp" DirectX.cab
    tar -xf "$tmp/DirectX.cab" -C "$tmp" gm16.dls
    mkdir -p "$SYS/drivers" "$DRIVE/windows/system32/drivers"
    cp "$tmp/gm16.dls" "$SYS/drivers/gm.dls"
    cp "$tmp/gm16.dls" "$DRIVE/windows/system32/drivers/gm.dls"
    rm -rf "$tmp"
    info "music sound bank: gm.dls installed"
  else
    info "music sound bank: already in place"
  fi

  for exe in $EXES; do
    reg_add "HKCU\\Software\\Wine\\AppDefaults\\$exe\\DllOverrides" dsound native,builtin
  done
  info "Microsoft's DirectSound for: $EXES"

  set_env WINE_LARGE_ADDRESS_AWARE 1
  info "large address space for 32-bit programs (the game crashed after a minute without it)"
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

step_build() {
  say "Build d3d9.dll from this bottle's client.dll"
  [ ${#INSTALLS[@]} -gt 0 ] || die "no client.dll in this bottle; install a game first"
  local missing=""
  for tool in i686-w64-mingw32-g++ meson ninja glslangValidator python3 patch; do
    command -v "$tool" >/dev/null || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    info "missing tools:$missing"
    info "install them with:  brew install mingw-w64 meson ninja glslang"
    exit 1
  fi
  # one DLL serves every install: each routine is checked against the client in memory at start.
  # Prefer a client that is not Revived's: in Revived's one routine cannot be translated.
  local client="${INSTALLS[0]}/client.dll" d
  for d in "${INSTALLS[@]}"; do
    [ "$d" != "$REVIVED" ] && { client="$d/client.dll"; break; }
  done
  info "using C:${client#"$DRIVE"} (5 to 10 minutes)"
  "$ROOT/scripts/build.sh" "$client"
  DLL="$ROOT/build/d3d9.dll"
}

step_install() {
  say "Install d3d9.dll"
  [ -n "$DLL" ] || DLL="$ROOT/build/d3d9.dll"
  [ -f "$DLL" ] || die "no $DLL; run the build step first"
  game_running && die "close the game first"
  backup_once "$SYS/d3d9.dll"
  cp "$DLL" "$SYS/d3d9.dll.new" && mv "$SYS/d3d9.dll.new" "$SYS/d3d9.dll"
  reg_add 'HKCU\Software\Wine\DllOverrides' d3d9 builtin   # everything else keeps Wine's Direct3D 9
  for exe in $EXES; do
    reg_add "HKCU\\Software\\Wine\\AppDefaults\\$exe\\DllOverrides" d3d9 native,builtin
  done
  mkdir -p "$DRIVE/Games/dxvk"
  set_env MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS 1
  set_env WINE_LARGE_ADDRESS_AWARE 1
  set_env DXVK_LOG_PATH C:/Games/dxvk
  set_env DXVK_STATE_CACHE_PATH C:/Games/dxvk
  if ask "Provide a frame-rate overlay in the game (hidden until Ctrl+Shift+F)?"; then set_env DXVK_HUD fps,frametimes,gpuload; fi
  # every executable starts with the pipelines the others have already built
  local caches=() c
  for c in "$DRIVE/Games/dxvk"/*.dxvk-cache; do [ -f "$c" ] && caches+=("$c"); done
  if [ ${#caches[@]} -ge 2 ]; then
    python3 -I "$ROOT/scripts/merge-pipeline-caches.py" "${caches[@]}" | tail -1 | sed 's/^/   pipeline caches /'
  fi
  info "installed for: $EXES"
  info "leave the bottle's Graphics setting in CrossOver on Auto; the log is in C:\\Games\\dxvk"
}

step_music() {
  [ -n "$REVIVED" ] || return 0
  say "Revived: music"
  local guard="$REVIVED/MxORevived-audio.txt" options="$REVIVED/options.cfg"
  if [ -f "$guard" ]; then
    backup_once "$guard"
    python3 -I - "$guard" <<'EOF'
import re, sys
p = sys.argv[1]; t = open(p, 'rb').read().decode('utf-8-sig')
open(p, 'wb').write(re.sub(r'(?m)^music = off(\r?)$', r'music = on\1', t).encode('utf-8'))
EOF
  fi
  if [ -f "$options" ]; then
    backup_once "$options"
    python3 -I - "$options" <<'EOF'
import re, sys
p = sys.argv[1]; raw = open(p, 'rb').read(); s = raw.decode('latin-1')
nl = '\r\n' if '\r\n' in s else '\n'
if re.search(r'(?m)^MusicSystemEnable\s*=', s):
    s = re.sub(r'(?m)^MusicSystemEnable\s*=.*?(\r?)$', r'MusicSystemEnable = 1\1', s)
else:
    s = s.rstrip('\r\n') + nl + 'MusicSystemEnable = 1' + nl
open(p, 'wb').write(s.encode('latin-1'))
EOF
  fi
  info "music switched on in Revived's starter and options"
}

step_uninstall() {
  say "Uninstall: game executables back to Wine's Direct3D 9"
  game_running && die "close the game first"
  for exe in $EXES; do
    reg_del "HKCU\\Software\\Wine\\AppDefaults\\$exe\\DllOverrides" d3d9
  done
  if [ -f "$SYS/d3d9.dll.setup-backup" ]; then
    cp "$SYS/d3d9.dll.setup-backup" "$SYS/d3d9.dll"
  fi
  for v in DXVK_LOG_PATH DXVK_STATE_CACHE_PATH DXVK_HUD; do unset_env "$v"; done
  info "done; DirectMusic, DirectSound and the large address space stay, the game needs them"
}

# --- run ----------------------------------------------------------------------------------------

game_running && info "note: a game is running; steps that replace files will refuse until it is closed"

if [ -z "$STEPS" ]; then
  ask "Set up what the game needs to start (shader compiler, DirectMusic, DirectSound)?" && step_bottle
  ask "Build the speed-up DLL from this bottle's client.dll?" && step_build
  ask "Install the DLL for $EXES?" && step_install
  [ -n "$REVIVED" ] && ask "Switch Revived's music on?" && step_music
else
  for s in $STEPS; do "step_$s"; done
fi

say "Done"
