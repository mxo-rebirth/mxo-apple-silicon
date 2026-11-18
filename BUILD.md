# Building, installing and removing

Everything here was done on macOS with CrossOver 26.3 and an Apple Silicon Mac. The steps
install a custom `d3d9.dll` into one CrossOver bottle and enable it for the game executable
only. No game file is changed.

This assumes the game already starts in CrossOver. If it does not yet, see
[CROSSOVER.md](CROSSOVER.md) first.

## Quick setup

`scripts/setup.sh` does everything below, in order, asking before each step:

1. **bottle**: what the game needs to start (CROSSOVER.md, section 2): the game's own shader
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

`client.dll` is the one in your game folder. The script

1. downloads CodeWeavers' source for CrossOver 26.3.0 once (about 200 MB; pass a tarball you
   already have as the second argument, or set `CROSSOVER_VERSION`),
2. applies `dxvk/dxvk-d3d9-mxo.patch` to the DXVK in it,
3. maps the functions of your `client.dll` and translates the routines named in
   `translator/routines.list` (each one only if its code matches the hash in the list),
4. builds `build/d3d9.dll`.

It takes five to ten minutes. `build/translate.log` says what was translated and what was
skipped and why. With the `client.dll` this was developed on, all 470 routines translate.
One DLL serves both games: Revived's `client.dll` has the same code at the same addresses for
all but one of them, and each routine is checked again when the game starts.

The translator rounds with two instructions by default (see HOW-IT-WORKS.md). For the slower form
that also matches the FPU outside the range of a `float`, add `--exact-range` to the `xlat.py`
line in `scripts/build.sh`.

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
   puts a frame-rate overlay in the corner.

4. Leave the bottle's Graphics setting in CrossOver on **Auto**, not DXVK.

After the next start, `drive_c/Games/dxvk/matrix_d3d9.log` should contain a line like

```
MxO fast math: 466 of 469 translated x87 routines installed (466 match this client.dll)
```

Routines that are not installed are listed with their address; that happens when something
else has already modified them in memory.

A CrossOver update can overwrite `syswow64/d3d9.dll`. The game then falls back to Wine's
Direct3D 9 on its own; copy the DLL back to restore.

## Switches

Environment variables, in `cxbottle.conf` under `[EnvironmentVariables]`:

| Variable | Effect |
|---|---|
| `DXVK_MXO_X87=0` | keep the graphics fixes, do not install the translated routines. First thing to try if the game misbehaves in the world. |
| `DXVK_MXO_FASTMATH=0` | no math replacement at all, including the two hand-written routines |
| `DXVK_LOCK_RENAME_COPY=0` | buffer locks wait for the GPU again |
| `DXVK_HOIST_UPLOADS=0` | texture and buffer uploads interrupt the render pass again |
| `DXVK_PREFAULT_MAPPED_MEMORY=0` | no pre-touching of mapped memory |
| `DXVK_LOCK_MAPPED_MEMORY=0` | pre-touched memory is unlocked right away instead of staying locked in RAM (it can then be compressed or swapped out, and stall again) |
| `DXVK_STATIC_SAMPLERS=0` | no per-texture-type shader variants |
| `DXVK_MXO_SWVP_COUNT=0` | vertex shaders no longer read the uploaded constant count; all 8,192 constants are copied per draw again |
| `DXVK_MXO_ZERO_CONSTS=0` | registers set to zero count towards the uploaded range again |
| `DXVK_KEEP_EMPTY_CHUNKS_MB=N` | keep up to N MB of emptied CPU-visible memory per memory type for reuse (default 256; 0 = DXVK's behaviour) |
| `DXVK_WARM_MEMORY_MB=N` | a background thread prepares N MB of already-touched memory per memory type (default 0 = off; it was never needed once freed memory is kept) |

Files in `C:\Games\dxvk` (`drive_c/Games/dxvk`), read when the game starts:

| File | Effect |
|---|---|
| `x87max.txt` | a number N: install only the first N translated routines (0 = none). For finding a misbehaving routine by halving. |
| `debug.flag` | empty file. Every 5 s the log gets the frame rate, the render throttle, DXVK's per-frame statistics, the game's calls per frame, memory activity and which DXVK routine interrupted render passes how often. Every frame slower than 40 ms gets a `SPIKE` line saying what happened in it (pipelines built, waits, uploads, new memory). While a frame is more than 200 ms late, a `STALL` line records where the game's main thread is, as `module+offset` call chains. Creating `shot.req` saves the next frame to `shot.bmp`. |
| `sample.flag` | empty file. A sampling profiler records where every thread is and who called it, and appends it to `samples.bin` every 10 s. It pauses every thread every 5 ms, which makes memory writes in the game much slower than they really are; do not judge frame rates with it. |
| `sample-light.flag` | empty file. The same profiler, but only for the game's main thread and DXVK's own threads, every 20 ms. Distorts far less. |

In the game, **Ctrl+Shift+F** shows or hides the `DXVK_HUD` overlay.

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

## Finding more routines to translate

1. Create `C:\Games\dxvk\sample.flag`, play for a few minutes, quit.
2. Build once so that `build/client.map` and the unstripped DLL exist, then:

   ```sh
   python3 translator/profile2.py "$BOTTLE/drive_c/Games/dxvk/samples.bin" build/client.map \
       build/dxvk/build.w32/src/d3d9/d3d9.dll \
       /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/i386-windows
   ```

   It prints, per thread, where the time went (game code, translated routines, graphics
   layer, Vulkan, waits and their callers) and writes `samples.bin.hot`: the game routines
   containing x87 code, by sample count.
3. Add those routines to the list and let the translator fill in length and hash:

   ```sh
   python3 translator/xlat.py pe client.dll MxoX /tmp/out.inc --map build/client.map \
       --write-list translator/routines.list @translator/routines.list @samples.bin.hot
   ```

   Routines the translator refuses are left out of the written list. Keep the list cumulative:
   a routine that is already replaced no longer shows up in a profile of `client.dll`.

For a different build of `client.dll`, the addresses in the list will not match and nothing is
translated (the hashes guard against translating the wrong code). Start from a profile, and
find the float-to-integer helper for the `ftol` line: it is the routine all float-to-int casts
call with the value on the FPU stack.

## Tests

See [`tests/README.md`](tests/README.md).
