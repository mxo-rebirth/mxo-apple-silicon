# Building, installing and removing

Everything here was done on macOS with CrossOver 26.3 and an Apple Silicon Mac. The steps
install a custom `d3d9.dll` into one CrossOver bottle and enable it for the game executable
only. No game file is changed.

This assumes the game already starts in CrossOver. If it does not yet, see
[crossover.md](crossover.md) first.

## Quick setup

`scripts/setup.sh` does everything below, in order, asking before each step:

1. **bottle**: what the game needs to start ([crossover.md](crossover.md), section 2): the game's own shader
   compiler, Microsoft's DirectMusic and DirectSound from the February 2010 DirectX package and
   the sound bank from the April 2006 one (both downloaded from Microsoft via the Internet
   Archive and checked against the checksums `winetricks` uses), and the large address space;
2. **build**: `scripts/build.sh` with the bottle's own `client.dll`;
3. **install**: the DLL for every game executable it found (`matrix.exe`, and `mxorev.exe` if
   Revived is installed), with the bottle settings it needs;
4. **music**: Revived only, switches its starter's music guard back on.

```sh
scripts/setup.sh                          # asks which bottle and before each step
scripts/setup.sh --bottle MatrixOnline install
scripts/setup.sh --bottle MatrixOnline uninstall
scripts/setup.sh --exe otherclient.exe    # another project's executable name
```

The install step also merges the pipeline caches of the games in the bottle
(`scripts/merge-pipeline-caches.py`): Rejacked and Revived run the same engine, but DXVK keeps one
cache per executable, so each would otherwise hitch while building pipelines the other already
has. Run it again after playing both, with the games closed:

```sh
scripts/merge-pipeline-caches.py "$BOTTLE/drive_c/Games/dxvk"/*.dxvk-cache
```

It finds game folders by their `client.dll`, keeps a `.setup-backup` copy of every file it
replaces, and never reads launcher logins or passwords. `uninstall` puts the game executables
back on Wine's Direct3D 9 and leaves DirectMusic in place, since the game needs it to start.

## Build

Tools (Homebrew): `brew install mingw-w64 meson ninja glslang`

```sh
scripts/build.sh "/path/to/your/client.dll"
```

The DLL is compiled with [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) 20261104, which the
script downloads once into `build/toolchain` (about 125 MB) and checks against a fixed SHA-256.
Homebrew's 32-bit GCC handles C++ exceptions with setjmp/longjmp, and the bookkeeping that needs on
nearly every function call cost about 5% of the game's main thread. Homebrew's mingw-w64 is still
needed for `objdump`, which the translator uses. `MXO_COMPILER=gcc scripts/build.sh ...` builds with
GCC as before.

`client.dll` is the one in your game folder. The script

1. downloads CodeWeavers' source for CrossOver 26.3.0 once (about 140 MB; pass a tarball you
   already have as the second argument, or set `CROSSOVER_VERSION`),
2. applies `dxvk/dxvk-d3d9-mxo.patch` to the DXVK in it,
3. maps the functions of your `client.dll` and translates the routines named in
   `translator/routines.list` (each one only if its code matches the hash in the list),
4. builds `build/d3d9.dll`.

It takes five to ten minutes. `build/translate.log` says what was translated and what was
skipped and why. With the `client.dll` this was developed on, all 537 routines translate.
One DLL serves both games: Revived's `client.dll` has the same code at the same addresses for
all but one of them, and each routine is checked again when the game starts.

The translator rounds with two instructions by default ([translator.md](translator.md#rounding)).
For the slower form that also matches the FPU outside the range of a `float`, add `--exact-range`
to the `xlat.py` line in `scripts/build.sh`.

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

   The first two are required: without the first, DXVK froze in most runs; without the second,
   the game ran out of its 2 GB of address space and crashed after about a minute in the world.
   The test machine also has `"WINEMSYNC" = "1"`, and `"DXVK_HUD" = "fps,frametimes,gpuload"`
   provides a frame-rate overlay (hidden until Ctrl+Shift+F). `"DXVK_FRAME_RATE" = "90"` limits
   the frame rate: without a limit the game reaches up to 200 fps in light scenes, which only
   makes heat and fan noise.

4. Leave the bottle's Graphics setting in CrossOver on **Auto**, not DXVK.

After the next start, `drive_c/Games/dxvk/matrix_d3d9.log` should contain a line like

```
MxO fast math: 535 of 538 translated x87 routines installed (535 match this client.dll)
```

Routines that are not installed are listed with their address and the reason, usually that
something else has already changed them in memory
([client-notes.md](client-notes.md#routines-something-else-has-changed)).

A CrossOver update can overwrite `syswow64/d3d9.dll`. The game then falls back to Wine's
Direct3D 9 on its own; copy the DLL back to restore.

## Switches

Environment variables, in `cxbottle.conf` under `[EnvironmentVariables]`:

| Variable | Effect |
|---|---|
| `DXVK_MXO_X87=0` | keep the graphics fixes, do not install the translated routines. First thing to try if the game misbehaves in the world. |
| `DXVK_MXO_FASTMATH=0` | no math replacement at all, including the hand-written routines |
| `DXVK_MXO_SQRT=0` | the game's `sqrt` import stays Wine's |
| `DXVK_LOCK_RENAME_COPY=0` | buffer locks wait for the GPU again |
| `DXVK_HOIST_UPLOADS=0` | texture and buffer uploads interrupt the render pass again |
| `DXVK_PREFAULT_MAPPED_MEMORY=0` | no pre-touching of mapped memory |
| `DXVK_MXO_RESPECT_ADDONS=0` | also replace game routines that add-ons such as Revived's `mxrdisp` check or hook (by default those are left alone so the add-on keeps working) |
| `DXVK_MXO_FAN_TO_LIST=0` | triangle fans are passed to MoltenVK as fans again (it emulates each one with a compute pass that interrupts drawing) |
| `DXVK_MXO_WEAK_FLUSH=1` | buffer unlocks and similar hints submit work to the GPU mid-frame again, as upstream DXVK does |
| `DXVK_LOCK_MAPPED_MEMORY=0` | pre-touched memory is unlocked right away instead of staying locked in RAM (it can then be compressed or swapped out, and stall again) |
| `DXVK_STATIC_SAMPLERS=0` | no per-texture-type shader variants |
| `DXVK_MXO_SWVP_COUNT=0` | vertex shaders no longer read the uploaded constant count; all 8,192 constants are copied per draw again |
| `DXVK_MXO_ZERO_CONSTS=0` | registers set to zero count towards the uploaded range again |
| `DXVK_KEEP_EMPTY_CHUNKS_MB=N` | keep up to N MB of emptied CPU-visible memory per memory type for reuse (default 256; 0 = DXVK's behaviour) |
| `DXVK_WARM_MEMORY_MB=N` | a background thread prepares N MB of already-touched memory per memory type (default 0 = off; it was never needed once freed memory is kept) |

`x87max.txt` and the diagnostic files (`debug.flag`, the profiler) are described in
[development.md](development.md#diagnostics).

The `DXVK_HUD` overlay starts hidden; **Ctrl+Shift+F** in the game shows or hides it.

The game's own setting, in `options.cfg`:

| Setting | Effect |
|---|---|
| `Client_RenderThrottle_Override = 0` | automatic: draw distance shrinks below 30 fps and grows again above |
| `Client_RenderThrottle_Override = 1` | always full draw distance; use this when measuring |

## Going back

Stock graphics for the game, one command:

```sh
"$WINE" --bottle MatrixOnline -- reg delete 'HKCU\Software\Wine\AppDefaults\matrix.exe\DllOverrides' /v d3d9 /f
```

(and the same with `mxorev.exe` for Revived). That is enough. To remove everything: copy `d3d9.dll.wine-builtin-backup` back over `d3d9.dll`,
delete the lines added to `cxbottle.conf`, and delete the `d3d9` value under
`HKCU\Software\Wine\DllOverrides`.

## Tests and development

[tests/README.md](../tests/README.md) and [development.md](development.md).
