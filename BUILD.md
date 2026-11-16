# Building, installing and removing

Everything here was done on macOS with CrossOver 26.3 and an Apple Silicon Mac. The steps
install a custom `d3d9.dll` into one CrossOver bottle and enable it for the game executable
only. No game file is changed.

This assumes the game already starts in CrossOver. If it does not yet, see
[CROSSOVER.md](CROSSOVER.md) first.

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
skipped and why. With the `client.dll` this was developed on, 468 of 468 routines translate;
with Revived's, 467.

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

   The first line keeps every other program in the bottle, launchers included, on Wine's own
   Direct3D 9. `matrix.exe` is the Rejacked executable; Revived's is `mxorev.exe` (see the
   open problem in the README before enabling it there).

3. Add to `$BOTTLE/cxbottle.conf` under `[EnvironmentVariables]`:

   ```
   "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS" = "1"
   "DXVK_LOG_PATH" = "C:/Games/dxvk"
   "DXVK_STATE_CACHE_PATH" = "C:/Games/dxvk"
   ```

   The first one is required: without it DXVK froze in most runs. The test machine also has
   `"WINEMSYNC" = "1"`.

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
| `DXVK_STATIC_SAMPLERS=0` | no per-texture-type shader variants |

Files in `C:\Games\dxvk` (`drive_c/Games/dxvk`), read when the game starts:

| File | Effect |
|---|---|
| `x87max.txt` | a number N: install only the first N translated routines (0 = none). For finding a misbehaving routine by halving. |
| `debug.flag` | empty file. Every 5 s the log gets the frame rate, the render throttle, DXVK's per-frame statistics, the game's calls per frame, and which DXVK routine interrupted render passes how often. Creating `shot.req` saves the next frame to `shot.bmp`. |
| `sample.flag` | empty file. A sampling profiler records where every thread is and who called it, and appends it to `samples.bin` every 10 s. Costs a few percent. |

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

That is enough. To remove everything: copy `d3d9.dll.wine-builtin-backup` back over `d3d9.dll`,
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
