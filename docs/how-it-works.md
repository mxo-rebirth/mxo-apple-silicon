# How it works

The 2009 client of The Matrix Online runs badly in CrossOver on Apple Silicon Macs. This page
says why, what this repository changes and what it gains. The documents listed at the end have
the details.

In short: the game does its math with x87, an old kind of processor instruction. Apple's chips
are ARM and have nothing like it, so Rosetta, which runs Intel programs on these Macs, has to
imitate x87 in software, slowly. The newer kind, SSE2, maps almost directly onto the chip. This
project rewrites 535 of the game's x87 math routines as SSE2 and swaps them in when the game
starts. The results stay the same. It also fixes fifteen graphics problems between the game and
the Mac's graphics chip.

It is experimental, and stable in our tests on two Macs, an M4 and an M1, with MxO Rejacked,
MxO Revived and the MxOEmu launcher. It is independent of the server projects. No game file is
in the repository. The replacement code is generated on the player's Mac from their
own `client.dll`.

## Why the game is slow

1. **Old-style math under Rosetta.** The game does its vector, matrix, culling and animation
   math with x87 instructions, the floating-point unit of older Intel processors. Rosetta 2,
   which runs Intel code on Apple Silicon, emulates x87 in software at about 25 ns per
   instruction: ARM has nothing like x87's 80-bit register stack. SSE2, the newer instructions
   for the same math, maps almost directly onto ARM's own. In the world, 80–90% of the game's
   main thread was x87 math.
2. **CrossOver's graphics.** Wine's own Direct3D 9 is slow at passing draw calls to the GPU.
   CrossOver's DXVK, which runs Direct3D 9 on Vulkan, shows a black screen with this game, and
   once that is fixed it stalls in several ways on Apple GPUs.
3. **The render throttle hides it.** Below 30 fps the game quietly cuts its draw distance, down
   to 25%. So a slow Mac still shows 15–20 fps, just with less of the world drawn.
4. **Two flags missing from `matrix.exe`.** It is not large-address-aware, so it can use only
   2 GB of memory and ran out after a minute in the world. It is not NX-compatible, which under
   Wine and Rosetta makes the first write to each page of memory shared with the GPU take about
   a second.

## What the fix is

One file: a custom build of DXVK's `d3d9.dll`. It goes into the CrossOver bottle (CrossOver's
name for one self-contained Windows setup) and is switched on for the game's executable only.
No game file is changed on disk.

- **Math.** `translator/xlat.py` turns 535 x87 routines of `client.dll` into SSE2 code, the
  newer instruction set for the same math. The results are the same for every value a `float`
  can hold. At startup the DLL compares each routine in memory with the code its replacement was
  made from, and swaps in the ones that match. Four more routines, among them `sqrt` and the
  float-to-integer helper, have replacements of their own. [translator.md](translator.md)
- **Graphics.** Fixes for fifteen problems of DXVK 1.10.3 on MoltenVK (Vulkan on Apple's
  Metal): shaders that failed to compile, one-second stalls on memory writes, buffer locks and
  texture uploads that interrupted drawing, 128 KB of shader constants copied per draw, triangle
  fans and more. Two of the fixes are settings of the bottle: `WINE_LARGE_ADDRESS_AWARE=1` and
  `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1`. [graphics.md](graphics.md)

## Result

Rejacked in the world, on an Apple M4:

| | Frame rate |
|---|---|
| Stock CrossOver, in a window, draw distance cut by the game | about 15 fps |
| With the DLL, fullscreen 3440×1440, maximum detail, full draw distance | 74 fps on average |

The game's main thread is now the limit, not the GPU. Every number, how it was taken and the
open problems: [measurements.md](measurements.md).

## Limits

- Not tested: long sessions, interiors, other districts. The numbers on this page are the M4's.
  An M1 has run it too, with its frame rate read from the counter only
  ([measurements.md](measurements.md)).
- The translated math gives up the x87 unit's wider exponent range for speed. Results match
  for every value a `float` can hold. `xlat.py --exact-range` keeps the full range, at a cost.
- The DLL changes `client.dll` in memory. That is also what cheats do.
- The DLL does not check that it runs on Apple Silicon. On a real x86 processor the translated
  code is expected to be slightly slower than the original.

## Other platforms

Only Apple Silicon Macs with CrossOver were tested. This section is what we expect from how the fixes work. None of it
has been measured.

The math replacement helps where x86 code is translated and x87 is emulated in software. The
cost it removes comes from the translator, not from macOS or CrossOver.

| Platform | What we expect |
|---|---|
| Any Apple Silicon Mac running the game through Rosetta 2: CrossOver, other Wine builds, Apple's Game Porting Toolkit | The same gain: the same translator with the same x87 cost |
| Linux on ARM with FEX-Emu | Probably a gain. As far as we know FEX emulates x87 in software too, unless told to reduce precision. |
| Windows on ARM | Unknown. Windows translates x86 itself there, and we have not looked at how it handles x87. |
| Real x86 processors: Windows PCs, Linux and Proton on x86, Steam Deck, Intel Macs | No gain, probably a small loss. x87 runs natively there, and the translated code does extra work on every operation to reproduce the x87 rounding. |

If the math replacement is shipped more widely, it should be switched on only where x87 is
emulated. A simple test at startup: time a few thousand x87 multiplications against the same in
SSE2.

Which graphics fixes matter outside CodeWeavers' DXVK on macOS is in
[graphics.md](graphics.md#which-fixes-matter-elsewhere).

## Documents

| Document | Contents |
|---|---|
| [client-notes.md](client-notes.md) | reverse-engineering notes on the client: files, imports, routines, render throttle, Direct3D 9 usage, launchers and add-ons |
| [translator.md](translator.md) | the x87 to SSE2 translator: rules, installation at run time, how it was checked |
| [graphics.md](graphics.md) | what fails in CrossOver's graphics and the fix for each problem |
| [measurements.md](measurements.md) | method, what each fix gave, where the time goes now, open problems |
| [crossover.md](crossover.md) | getting the game to start in CrossOver by hand |
| [building.md](building.md) | building and installing by hand, switches, going back |
| [development.md](development.md) | repository layout, diagnostics, profiling, adding routines, the benchmark |
| [tests/README.md](../tests/README.md) | the differential tests |

## Licence and credits

DXVK is by its authors and contributors, under the zlib/libpng licence
([dxvk/LICENSE](../dxvk/LICENSE)). The patch here is derived from it and has the same licence,
as does the rest of this repository ([LICENSE](../LICENSE)). The DXVK source it applies to is
the one CodeWeavers publish for CrossOver. The Matrix Online is the property of its owners.
This repository contains no game files.
