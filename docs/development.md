# Development

Diagnostics built into the DLL, profiling, adding routines to the translation, the Direct3D 9
benchmark and regenerating the patch. Building and installing are in [building.md](building.md).

## Layout

| Path | Contents |
|---|---|
| `dxvk/dxvk-d3d9-mxo.patch` | all changes to CodeWeavers' DXVK 1.10.3 source |
| `translator/xlat.py` | the x87 to SSE2 translator ([translator.md](translator.md)) |
| `translator/discover.py` | maps `client.dll`: function entries, branches, x87 instructions (`build/client.map`) |
| `translator/routines.list` | the routines to translate: start, limit, weight, length, hash |
| `translator/profile2.py` | turns the profiler's `samples.bin` into a per-thread profile and a routine list |
| `translator/dis.py` | disassembles address ranges of a PE file |
| `translator/mxo_x87_apply.h` | run-time side of the translation: fixups and installation. The patch holds the same file as `src/d3d9/d3d9_mxo_x87.h`; `scripts/build.sh` stops if the two differ |
| `tests/` | differential tests: translation against original code ([README](../tests/README.md)) |
| `bench/d3d9bench.rs` | standalone Direct3D 9 benchmark |
| `scripts/build.sh` | builds `d3d9.dll` from a `client.dll` and the CodeWeavers source |
| `scripts/setup.sh` | guided setup of a CrossOver bottle |
| `scripts/merge-pipeline-caches.py` | merges DXVK pipeline caches |
| `scripts/fps-summary.py` | frame rate in the world from the DLL's frame log |

Everything generated from the game's files lands in `build/` or carries an ignored name
(`.gitignore`). Nothing derived from `client.dll` belongs in a commit.

## Diagnostics

Files in `C:\Games\dxvk` (`drive_c/Games/dxvk` in the bottle), read when the game starts. All
are off unless the file exists.

| File | Effect |
|---|---|
| `debug.flag` | empty file. Every 5 s the log gets the frame rate, the render throttle, DXVK's per-frame statistics, the game's calls per frame, memory activity and which DXVK routine interrupted render passes how often. Every frame slower than 40 ms gets a `SPIKE` line saying what happened in it (pipelines built, waits, uploads, new memory). While a frame is more than 200 ms late, a `STALL` line records where the game's main thread is, as `module+offset` call chains. |
| `shot.req` | with `debug.flag`: saves the next frame to `shot.bmp` |
| `drawlog.req` | with `debug.flag`: writes one `DRAW` line per draw call of the next frame (shaders, textures, render target, blending) |
| `sample-light.flag` | empty file. A sampling profiler records where the game's main thread and DXVK's own threads are, every 20 ms, and appends to `samples.bin` every 10 s. It also writes `modules.txt`, the list of loaded modules with their addresses. |
| `sample.flag` | empty file. The same profiler for every thread, every 5 ms. It pauses every thread each time, which makes memory writes in the game much slower than they really are; do not judge frame rates with it. |
| `x87max.txt` | a number N: install only the first N translated routines (0 = none). For finding a misbehaving routine by halving. |

The log is `matrix_d3d9.log` (or `mxorev_d3d9.log`) in the same folder.

```sh
scripts/fps-summary.py "$BOTTLE/drive_c/Games/dxvk/matrix_d3d9.log"
```

prints the average frame rate in the world, draw calls per frame and frame time per 1,000 draw
calls ([measurements.md](measurements.md#how-to-measure)).

Wine's own tracing (`--cx-log`) slows the game to a crawl; use it only briefly.

## Profiling and adding routines

1. Create `C:\Games\dxvk\sample-light.flag`, play for a few minutes, quit.
2. Build once so that `build/client.map` and the unstripped DLL exist, then:

   ```sh
   python3 translator/profile2.py "$BOTTLE/drive_c/Games/dxvk/samples.bin" build/client.map \
       build/dxvk/build.w32/src/d3d9/d3d9.dll \
       /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/i386-windows
   ```

   It prints, per thread, where the time went (game code, translated routines, graphics layer,
   Vulkan, waits and their callers) and writes `samples.bin.hot`: the game routines containing
   x87 code, by sample count.
3. Add those routines to the list and let the translator fill in length and hash:

   ```sh
   python3 translator/xlat.py pe client.dll MxoX /tmp/out.inc --map build/client.map \
       --write-list translator/routines.list @translator/routines.list @samples.bin.hot
   ```

   Routines the translator refuses are left out of the written list.
4. Run the tests on the new routines ([tests/README.md](../tests/README.md)) before building.

Keep the list cumulative. A routine that is already replaced no longer shows up in a profile of
`client.dll`, so a list rebuilt from a fresh profile loses the hottest ones.

Routines reached only through pointers do not appear as call targets in `client.map`. Find them
by walking a sampled address back to the function prologue.

For a different build of `client.dll`, the addresses in the list will not match and nothing is
translated; the hashes guard against translating the wrong code. Start from a profile, and find
the float-to-integer helper for the `ftol` line: it is the routine all float-to-int casts call
with the value on the FPU stack.

## The benchmark

`bench/d3d9bench.rs` is a single-file Direct3D 9 test program (no standard library, 32-bit
Windows). It was used to reproduce the buffer-lock and texture-upload stalls outside the game.

```sh
rustup target add i686-pc-windows-msvc
rustc --edition 2021 --target i686-pc-windows-msvc -C opt-level=2 -C panic=abort \
    -C linker=rust-lld -C link-arg=/ENTRY:mainCRTStartup -C link-arg=/SUBSYSTEM:WINDOWS \
    -C link-arg=/NODEFAULTLIB -o d3d9bench.exe bench/d3d9bench.rs
```

```
d3d9bench.exe <vp 0=hw 1=sw 2=mixed> <width> <height> <draws/frame> <seconds> <tex-fmt 0=A8R8G8B8 1=DXT1>
```

Run it in a bottle with the DLL override set for `d3d9bench.exe`.

## Regenerating the patch

`dxvk/dxvk-d3d9-mxo.patch` is a plain `diff -ruN` between the DXVK tree in CodeWeavers' source
tarball (`a`) and the edited tree (`b`, normally `build/dxvk`):

```sh
diff -ruN --exclude=build.w32 --exclude='*.orig' --exclude='*.rej' --exclude='*.log' \
    --exclude=d3d9_mxo_x87.inc --exclude='*.inc.tests' --exclude=.DS_Store a b > dxvk/dxvk-d3d9-mxo.patch
```

`d3d9_mxo_x87.inc` is the translated game code and must stay out. Give the `---`/`+++` header
lines a fixed timestamp so the patch does not change from run to run, then check that it
applies to a fresh copy of `a` and reproduces `b`.

The DLL is compiled with llvm-mingw; `MXO_COMPILER=gcc scripts/build.sh ...` uses Homebrew's GCC
instead ([graphics.md](graphics.md), problem 15).
