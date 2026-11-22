# How it works

The 2009 client of The Matrix Online runs badly on Apple Silicon Macs under CrossOver. This is
the overview of why, what this repository does about it and what came out. The details are in
the documents listed at the end.

It is experimental: played in short sessions by one person on one machine, with MxO Rejacked
and MxO Revived. No game file is in the repository. The replacement code is generated on the
player's machine from their own `client.dll`.

## Why the game is slow

1. **x87 math under Rosetta.** The client does its vector, matrix, culling and animation math
   on the x87 FPU. Rosetta 2 emulates x87 in software at about 25 ns per instruction. In the
   world, 80–90% of the game's main thread was x87 math.
2. **CrossOver's graphics paths.** Wine's own Direct3D 9 is slow at passing draw calls on.
   CrossOver's DXVK shows a black screen with this client, and once that is fixed it stalls in
   several ways that are specific to this DXVK version on Apple GPUs.
3. **The render throttle hides all of it.** The client silently cuts draw distance, down to
   25%, to hold 30 fps. A slow machine shows "15–20 fps" at any speed, just with less world
   drawn.
4. **Two flags missing from `matrix.exe`.** It is not large-address-aware, so it ran out of
   its 2 GB of address space after a minute in the world. It is not NX-compatible, which under
   Wine and Rosetta makes first writes to GPU-shared memory take about a second each.

## What the fix is

One file: a custom build of DXVK's `d3d9.dll`, installed into the CrossOver bottle and enabled
for the game executable only. No game file is modified on disk.

- **Math.** `translator/xlat.py` turns 535 x87 routines of `client.dll` into SSE2 code that gives
  the same results for every value a `float` can hold. At startup the DLL checks each routine
  in memory against the code its replacement was generated from and redirects the matching
  ones. Four more routines, among them `sqrt` and the float-to-integer helper, have
  replacements written for them. [translator.md](translator.md)
- **Graphics.** Fifteen fixes to DXVK 1.10.3 on MoltenVK: shaders that failed to compile,
  one-second page faults, buffer locks and texture uploads that interrupted drawing, 128 KB of
  shader constants copied per draw, triangle fans, and more. [graphics.md](graphics.md)
- **Two settings in the bottle:** `WINE_LARGE_ADDRESS_AWARE=1` and
  `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1`.

## Result

Fullscreen 3440×1440, maximum detail, full draw distance, music on, Apple M4:

| | Before | Now |
|---|---|---|
| Rejacked, in the world | about 15 fps windowed with the draw distance cut. 8.5 fps at full distance | 55–89 fps, 74 on average |
| Revived, in the world | 1–4 fps on DXVK | 42–65 fps, 58 on average (an earlier build) |
| Loading area | 8–18 fps | 85–89 fps |
| Entering the world | about 50 s at 3–8 fps | no stall |
| Map open | 10 fps | about 5 fps below the world |

Two "before" figures are stock CrossOver: the 15 fps in the world and the loading area. The
others are from early builds of this DLL, before the fix for each problem.

The game's main thread is now the limit. The GPU is idle a third to half of the time. Method,
numbers per build and open problems: [measurements.md](measurements.md).

## Limits

- Not tested: long sessions, interiors, other districts, any other Mac.
- The translation trades the FPU's extended exponent range for speed. Results match for every
  value a `float` can hold. `xlat.py --exact-range` reproduces the full range at a cost.
- It patches `client.dll` in memory. That is also what cheats do. See the questions below.
- The DLL does not check that it runs on Apple Silicon. On real x86 hardware the translated
  code is expected to be slightly slower than the original.

## Other platforms

We tested one setup. Everything in this section is what we expect from how the fixes work.
none of it has been measured.

The math replacement should help wherever x86 code is translated and x87 is emulated in
software. The cost it removes comes from the translator, not from macOS or CrossOver.

| Platform | What we expect |
|---|---|
| Any Apple Silicon Mac running the client through Rosetta 2: CrossOver, other Wine builds, Apple's Game Porting Toolkit | The same gain. It is the same translator with the same x87 cost. |
| Linux on ARM with FEX-Emu | Probably a gain. As far as we know FEX emulates x87 in software too, unless it is told to reduce precision. |
| Windows on ARM | Unknown. Windows translates x86 itself there, and we have not looked at how it handles x87. |
| Real x86 processors: Windows PCs, Linux and Proton on x86, Steam Deck, Intel Macs | No gain, probably a small loss. x87 runs natively there, and the translated code does extra work for every operation to reproduce the FPU's rounding. |

If the math replacement is shipped more widely, it should be switched on only where x87 is
emulated. A simple check is to time a few thousand x87 multiplications against the same in SSE2
at startup.

Which graphics fixes apply outside CodeWeavers' DXVK on macOS is in
[graphics.md](graphics.md#which-fixes-matter-elsewhere).

## Documents

| Document | Contents |
|---|---|
| [client-notes.md](client-notes.md) | reverse-engineering notes on the client: files, imports, routines, render throttle, Direct3D 9 usage, launchers and add-ons |
| [translator.md](translator.md) | the x87 to SSE2 translator: rules, installation at run time, how it was checked |
| [graphics.md](graphics.md) | what fails in CrossOver's graphics and the fix for each problem |
| [measurements.md](measurements.md) | method, results per build, where the time goes now, open problems |
| [crossover.md](crossover.md) | getting the game to start in CrossOver by hand |
| [building.md](building.md) | building and installing by hand, switches, going back |
| [development.md](development.md) | repository layout, diagnostics, profiling, adding routines, the benchmark |
| [tests/README.md](../tests/README.md) | the differential tests |

## Licence and credits

DXVK is by Philip Rebohle, Joshua Ashton and contributors, under the zlib/libpng licence
([dxvk/LICENSE](../dxvk/LICENSE)). The patch here is a derivative of it and carries the same
licence, as does the rest of this repository ([LICENSE](../LICENSE)). The DXVK source it applies
to is the one CodeWeavers publish for CrossOver. The Matrix Online is the property of its
owners. This repository contains no game files.
