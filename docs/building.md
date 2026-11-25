# Building, installing and removing

Everything here was done on macOS 27 with CrossOver 26.3 and an Apple Silicon Mac. The steps
install a custom `d3d9.dll` into one CrossOver bottle and enable it for the game executable
only. No program or data file of the game is changed on disk: its code is replaced in memory.
The setup's detail, intro, music and video steps edit the game's settings files, and keep a
`.setup-backup` copy of each.

The sections after the setup assume the game already starts in CrossOver. If it does not yet,
see [crossover.md](crossover.md) first.

## The setup

`scripts/setup.sh` first checks the Mac: Apple Silicon, the macOS version, CrossOver, Apple's
command line developer tools, Homebrew and the build tools (`mingw-w64 meson ninja glslang`).
It stops there when something this run needs is missing, and says what to install. Homebrew
installs only from the account that installed it, an administrator account. There the setup
offers to install the build tools. In any other account it names the command to run in that
account first.

In a bottle without a game the game step comes first. A run of every step, or one with `game`
or `icons`, then offers to quit CrossOver if it is open, because CrossOver shows new icons only
after it starts again. `--yes` leaves it open. Then the setup asks its questions and runs the
other steps in this order. [quick-start.md](quick-start.md) is the short way through it. The
setup stops if a game is running.

1. **game**, in a bottle without a game: makes the bottle, puts the client in `C:\Games\MxO`
   (from the MxOEmu project's page, a folder, an archive or an `https` link) and installs the
   launchers you choose. Each installer is checked against the checksum its publisher gives:
   that it is the publisher's file, not that it is safe.
   Rejacked's runs without its window. Revived's and Microsoft's .NET 10 runtime need your
   clicks. An MxOEmu launcher that came with the game gets a shortcut on request.
2. **bottle**: what the game needs to start ([crossover.md](crossover.md), section 2): the
   game's shader compiler, Microsoft's DirectMusic and DirectSound, and more memory for the
   game (4 GB instead of 2). The two DirectX packages come from Microsoft via the Internet Archive and are checked
   against the checksums `winetricks` uses.
3. **build**: `scripts/build.sh` with the bottle's `client.dll`, after `brew install` of the
   missing build tools if you agreed (administrator accounts only).
4. **install**: the DLL for every game executable found (`matrix.exe`, `mxorev.exe`), with the
   bottle settings it needs. Unless you answer `n`, also `DXVK_MXO_RESPECT_ADDONS=0`
   ([Switches](#switches)): faster, but an add-on such as Revived's interface scaling may stop
   working. The frame-rate limit is `DXVK_FRAME_RATE`: 90, or the number after `--fps`. An `n`
   to the limit writes `0`, no limit, and the next run starts from that answer.
5. **detail**, on request: graphics settings and the main display's size in each game's
   `options.cfg`, and 16× anisotropic filtering in `C:\Games\dxvk\dxvk.conf`. There are three
   sets, and the question lists the one for the Mac it runs on first. Return takes that one in a
   game without settings. Where a game has settings, Return and `--yes` leave them. The step named
   by itself (`detail`) starts on this Mac's set, and `--yes detail` writes it. `--yes` never
   takes the enhanced set.
   - maximum, for an M3, M4 or newer: the highest Video Options values, with
     `Client_RenderThrottle_Override = 1`
   - lighter, for an M1 or M2: the same with the draw distance held at 70%
     (`Client_RenderThrottle_Override = 0.7`), no character shadows, no wet streets and no
     anti-aliasing. It is a first version. On the M4, anti-aliasing cost a few fps and
     character shadows 12 to 13% in a crowd ([measurements.md](measurements.md#in-a-crowd)).
     The 70% draw distance and the wet streets are not measured.
   - enhanced, experimental: the maximum, then values past the top of the game's menu. In
     `options.cfg` the draw distances times 1.4 and more cars and pedestrians (35 of each,
     density 2). In each game's `autoexec.cfg`, which the game reads and never writes, settings
     no menu shows: character shadows at 1024 instead of 512 and kept real for longer, shadows
     and grass drawn twice as far, finer models at a distance and a 1024 wet-street reflection
     map instead of 256. Which way the shadow fallback and the model scale work is read from
     the client's defaults, not confirmed by eye. Tried by eye with Revived on an M4, not
     measured: it costs frame rate, most in busy streets. A launcher update can replace
     `autoexec.cfg`: run the step again then. Choosing another set puts the `autoexec.cfg`
     values that are still the enhanced set's back to the game's own, and leaves a value you
     changed since.
6. **intro**, on request: `EnableSplash = 0` in each game's `useropts.cfg`.
7. **music**, Revived only: `music = on` in its starter's music guard, and the music setting in
   its `options.cfg` and `useropts.cfg` back to 1. A later run of every step leaves
   `music = off` alone.
8. **video**, Revived only, on request: `"BackgroundVideo": false` in its
   `launcher-settings.json`, with the launcher closed. Before the launcher's first start that
   file is made with this key alone, and the launcher takes its defaults for the rest.
9. **icons**: has CrossOver read the bottle's shortcuts again (`cxmenu --sync`), says for each
   launcher whether it is listed, and makes a missing shortcut for the Rejacked launcher.

A step named on the command line runs alone. After `game` has added a game, run the setup once
more without a step: the other steps give that game its start fixes and the speed-up.

```sh
scripts/setup.sh                              # every step, after its questions
scripts/setup.sh --bottle MatrixOnline game   # the named steps only, in the named bottle
scripts/setup.sh --exe otherclient.exe        # another project's executable name
scripts/setup.sh --dll /path/to/d3d9.dll      # install a DLL that is built already
scripts/setup.sh --yes                        # no questions: every default, without the game step
```

`--yes game` installs the launchers and does not download the game.

The install step combines the shader caches of the games in the bottle, so one game does not
stutter on what the other has built. To combine them again after playing both, with the games
closed:

```sh
scripts/merge-pipeline-caches.py "$BOTTLE/drive_c/Games/dxvk"/*.dxvk-cache
```

The setup keeps a `.setup-backup` copy of every file it replaces. Registry values and
CrossOver's list of shortcuts get none. It never looks for, prints or sends launcher logins or
passwords.

`uninstall` puts the games back on Wine's Direct3D 9 and takes the speed-up's variables out of
the bottle's settings. It leaves:

- what the game needs to start: DirectMusic, the sound bank, the shader compiler and
  `WINE_LARGE_ADDRESS_AWARE`
- the settings the detail, intro, music and video steps changed, with their `.setup-backup`
  copies next to them
- `C:\Games\dxvk` with the log, the shader caches and `dxvk.conf`
- the game, the launchers and .NET
- the registry value that keeps every other program in the bottle on Wine's Direct3D 9
- outside the bottle: `~/mxo-apple-silicon`, `~/Library/Caches/mxo-apple-silicon` and the
  Homebrew packages

Deleting the bottle in CrossOver removes everything inside it.

## Build

The setup does this for you. By hand:

```sh
brew install mingw-w64 meson ninja glslang
scripts/build.sh "/path/to/your/client.dll"
```

`brew install` works only in the account that installed Homebrew. The build itself runs in any
account once the tools are there.

`client.dll` is the one in your game folder. After a few minutes the result is
`build/d3d9.dll`. The script

1. downloads the compiler ([llvm-mingw](https://github.com/mstorsjo/llvm-mingw) 20261104,
   about 125 MB) and CodeWeavers' source for CrossOver 26.3.0 (about 140 MB), once, and checks
   each against a fixed SHA-256,
2. applies `dxvk/dxvk-d3d9-mxo.patch` to the DXVK in that source,
3. translates the game's math routines named in `translator/routines.list`, each one only if
   its code in your `client.dll` matches the hash in the list,
4. builds the DLL.

`build/translate.log` says what was translated and what was skipped. With the 7.6005 client
all 535 routines translate. The same DLL serves every launcher: each routine is checked again
when the game starts, and one that does not match is left alone.

| To | Do this |
|---|---|
| use a CrossOver source archive you already have | give it as the second argument (not checked) |
| build against another CrossOver version | set `CROSSOVER_VERSION` (not checked) |
| compile with Homebrew's GCC | set `MXO_COMPILER=gcc`. Its exception handling cost about 5% of the game's main thread |
| round exactly as the FPU does outside the range of a `float` | add `--exact-range` to the `xlat.py` line in `scripts/build.sh`. It is slower ([translator.md](translator.md#rounding)) |

## Install into a bottle

Below, `BOTTLE` is the bottle folder, for example
`~/Library/Application Support/CrossOver/Bottles/MatrixOnline`, `WINE` is
`/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine`, and the bottle is
called `MatrixOnline`. Close the game and its launcher first.

1. Put the DLL in place, keeping Wine's original:

   ```sh
   cd "$BOTTLE/drive_c/windows/syswow64"
   [ -f d3d9.dll.wine-builtin-backup ] || cp d3d9.dll d3d9.dll.wine-builtin-backup
   cp /path/to/build/d3d9.dll d3d9.dll
   mkdir -p "$BOTTLE/drive_c/Games/dxvk"
   ```

2. Tell Wine to use it for the game executable only:

   ```sh
   "$WINE" --bottle MatrixOnline -- reg add 'HKCU\Software\Wine\DllOverrides' /v d3d9 /d builtin /f
   "$WINE" --bottle MatrixOnline -- reg add 'HKCU\Software\Wine\AppDefaults\matrix.exe\DllOverrides' /v d3d9 /d native,builtin /f
   ```

   For Revived, add the same line with `mxorev.exe`:

   ```sh
   "$WINE" --bottle MatrixOnline -- reg add 'HKCU\Software\Wine\AppDefaults\mxorev.exe\DllOverrides' /v d3d9 /d native,builtin /f
   ```

   The first line keeps every other program in the bottle, launchers included, on Wine's own
   Direct3D 9. `matrix.exe` is the Rejacked executable, `mxorev.exe` Revived's.

3. Add to `$BOTTLE/cxbottle.conf` under `[EnvironmentVariables]`:

   ```
   "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS" = "1"
   "WINE_LARGE_ADDRESS_AWARE" = "1"
   "DXVK_LOG_PATH" = "C:/Games/dxvk"
   "DXVK_STATE_CACHE_PATH" = "C:/Games/dxvk"
   ```

   | Line | What it is for |
   |---|---|
   | `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS` | required: without it DXVK froze in most runs |
   | `WINE_LARGE_ADDRESS_AWARE` | required: without it the game ran out of its 2 GB of address space and crashed after about a minute in the world |
   | `DXVK_LOG_PATH`, `DXVK_STATE_CACHE_PATH` | where the log and the pipeline caches go |

   Optional lines:

   | Line | What it does |
   |---|---|
   | `"DXVK_FRAME_RATE" = "90"` | limits the frame rate, `0` for no limit. Without a limit the game reaches up to 200 fps in light scenes, which only makes heat and fan noise |
   | `"DXVK_HUD" = "fps,frametimes,gpuload"` | the frame-rate overlay, hidden until Ctrl+Shift+F |
   | `"DXVK_MXO_RESPECT_ADDONS" = "0"` | also replaces the routines that add-on files next to the game point into. About 10 fps less without it in a bottle with Revived's add-on files ([measurements.md](measurements.md#settings-that-change-the-numbers)) |
   | `"WINEMSYNC" = "1"` | set on the test machine |

4. Leave the bottle's Graphics setting in CrossOver on **Auto**, not DXVK.

After the next start, `drive_c/Games/dxvk/matrix_d3d9.log` should contain a line like

```
MxO fast math: 535 of 536 translated x87 routines installed (535 match this client.dll)
```

The 536 are the 535 routines and the float-to-integer helper. Routines that are not installed are listed with their address and the reason, usually that
something else has already changed them in memory
([client-notes.md](client-notes.md#routines-something-else-has-changed)).

A CrossOver update can overwrite `syswow64/d3d9.dll`. The game then falls back to Wine's
Direct3D 9 on its own. Copy the DLL back to restore.

## Switches

Environment variables, in `cxbottle.conf` under `[EnvironmentVariables]`:

| Variable | Effect |
|---|---|
| `DXVK_MXO_X87=0` | keep the graphics fixes, do not install the translated routines. First thing to try if the game misbehaves in the world. |
| `DXVK_MXO_FASTMATH=0` | no math replacement at all, including the hand-written routines |
| `DXVK_MXO_SQRT=0` | the game's `sqrt` import stays Wine's |
| `DXVK_MXO_LIGHT_FILTER=0` | the game's light loop is handed every projector light again, not only those that can reach the object |
| `DXVK_LOCK_RENAME_COPY=0` | buffer locks wait for the GPU again. `d3d9.lockRenameCopy = False` in `dxvk.conf` does the same |
| `DXVK_HOIST_UPLOADS=0` | texture and buffer uploads interrupt the render pass again |
| `DXVK_PREFAULT_MAPPED_MEMORY=0` | no pre-touching of mapped memory |
| `DXVK_MXO_RESPECT_ADDONS=0` | also replace game routines that add-ons such as Revived's `mxrdisp` check or hook, the two hand-written matrix routines included (by default those are left alone so the add-on keeps working) |
| `DXVK_MXO_FAN_TO_LIST=0` | triangle fans are passed to MoltenVK as fans again (it emulates each one with a compute pass that interrupts drawing) |
| `DXVK_MXO_WEAK_FLUSH=1` | buffer unlocks and similar hints submit work to the GPU mid-frame again, as upstream DXVK does |
| `DXVK_LOCK_MAPPED_MEMORY=0` | pre-touched memory is unlocked right away instead of staying locked in RAM (it can then be compressed or swapped out, and stall again) |
| `DXVK_STATIC_SAMPLERS=0` | no per-texture-type shader variants. Unset, they are on only with MoltenVK. `1` switches them on with any driver |
| `DXVK_MXO_SWVP_COUNT=0` | vertex shaders no longer read the uploaded constant count. All 8,192 constants are copied per draw again |
| `DXVK_MXO_ZERO_CONSTS=0` | registers set to zero count towards the uploaded range again |
| `DXVK_KEEP_EMPTY_CHUNKS_MB=N` | keep up to N MB of emptied CPU-visible memory per memory type for reuse (default 256, at most 1024, 0 = DXVK's behaviour). A value that is not a number is ignored with a warning |

The switches understand `0` and `1` only. The log has one line for each switch that is not at its
default, and a warning for a value it does not understand.

`x87max.txt` and the diagnostic files (`debug.flag`, the profiler) are described in
[development.md](development.md#diagnostics).

The `DXVK_HUD` overlay starts hidden. **Ctrl+Shift+F** in the game shows or hides it.

The game's own setting, in `options.cfg`:

| Setting | Effect |
|---|---|
| `Client_RenderThrottle_Override = 0` | automatic: draw distance shrinks below 30 fps and grows again above |
| `Client_RenderThrottle_Override = 1` | always full draw distance. Use this when measuring |
| `Client_RenderThrottle_Override = 0.7` | draw distance held at 70%. Any value between 0.25 and 1 holds that share |

## Going back

Stock graphics for the game, one command:

```sh
"$WINE" --bottle MatrixOnline -- reg delete 'HKCU\Software\Wine\AppDefaults\matrix.exe\DllOverrides' /v d3d9 /f
```

(and the same with `mxorev.exe` for Revived). That is enough. To remove everything: copy `d3d9.dll.wine-builtin-backup` (after the setup: `d3d9.dll.setup-backup`) back over `d3d9.dll`,
delete the lines added to `cxbottle.conf`, and delete the `d3d9` value under
`HKCU\Software\Wine\DllOverrides`.

## Tests and development

[tests/README.md](../tests/README.md) and [development.md](development.md).
