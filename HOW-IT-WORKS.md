# The Matrix Online on Apple Silicon: why it is slow and what fixes it

This is a write-up for the **MxO Rejacked** and **MxO Revived** teams. It describes why the 2009
client runs badly on Apple Silicon Macs under CrossOver, what we found when we measured where
the time goes, and the fixes we built. The code is in this repository. It is experimental: it has been played in
short sessions by one person on one machine, with both Rejacked and Revived.

Nothing in this repository comes from the game. The fixes are generated on the player's own
machine from their own `client.dll`.

**Players:** the [README](README.md) has the short version: one script that sets everything up.

## Summary

- **The main problem is not graphics.** The client does its vector, matrix, culling and
  animation math on the x87 FPU. Rosetta 2 emulates x87 in software at roughly 25 ns per
  instruction. In the world, 80–90% of the game's main thread was x87 math.
- **The fix for that** is to replace the x87 routines the game spends most of its time in.
  They are swapped, in memory at startup, for SSE2 code that gives the same results for every
  value a `float` can hold (see [Replacing the x87 routines](#replacing-the-x87-routines)). The
  SSE2 code is produced automatically by a small translator program (`translator/xlat.py`);
  470 routines are covered. On their own, translated routines run 5 to 120 times faster.
- **Graphics needed work too.** CrossOver's own DXVK does not work with this client (black
  screen), and once it does, two stalls and a display glitch show up that are specific to this
  DXVK version on Apple GPUs. We fixed those in a custom build of DXVK's `d3d9.dll`.
- **The client's render throttle hides all of this.** It silently cuts draw distance, down to
  25%, to chase 30 fps. A slow machine therefore shows "15–20 fps" at any speed, just with less
  world drawn. Frame-rate comparisons mean little unless the throttle is held at a fixed value.
- **Result so far:** fullscreen at 3440×1440 with maximum detail, in the world: Rejacked
  44–64 fps and Revived 44–57 fps, both with music. Before this work the same machine showed
  8–18 fps in the loading area and around 15 fps in the world, with the draw distance cut. The
  GPU is now busy 93–100% of the time, so the graphics chip itself is the limit at that
  resolution. Details and caveats are under [Results](#results).
- **Two more problems were specific to this DXVK version on Apple GPUs** and cost far more than
  expected: every draw copied all 8,192 software vertex shader constants (128 KB), and memory
  that the game freed was handed back to the system and requested again, which is slow under
  Rosetta for this client. Both are fixed; see [What goes wrong](#what-goes-wrong).
- **Two settings matter outside the DLL:** the game crashed after about a minute when its 2 GB
  address space ran out (`WINE_LARGE_ADDRESS_AWARE=1` fixes that), and the Rejacked launcher's
  beta "new glow shader" option halves the frame rate at high resolution.

- **Other platforms:** untested. We expect the math fix to help wherever x86 code is translated
  and x87 is emulated, and to be of no use, or a small loss, on real x86 processors. See
  [Other platforms](#other-platforms).

## Test setup

| | |
|---|---|
| Machine | MacBook with Apple M4, macOS 26 |
| Translation layer | CrossOver 26.3 (Wine 11 based, 32-bit code in a 64-bit process, Rosetta 2) |
| Display | 3440×1440 at 120 Hz external, plus the built-in display |
| Client | Rejacked install; `client.dll` with PE timestamp `0x50E8ED23`, 10,924,032 bytes |
| Also checked | Revived's `client.dll` (11,059,200 bytes): same code at the same addresses for 469 of the 470 routines we translate |

## What goes wrong

### 1. x87 math under Rosetta

The client was built with a compiler that uses the x87 FPU for all floating point. On real x86
hardware that is fine. Rosetta 2 translates x86 code to ARM, but it emulates x87 instructions
in software. We measured about 25 ns per x87 instruction (for example, a routine with 21 x87
instructions takes 540 ns), the same in 24-, 53- and 64-bit precision mode. An SSE2 instruction
doing the same work takes well under a nanosecond.

We sampled where the game's main thread was, many times a second, standing at a spawn point in
the world:

| Where the main thread was | Share |
|---|---|
| `client.dll` | 82–86% |
| Direct3D 9 layer | 1–2% |
| everything else | rest |

Almost all of the `client.dll` time was in routines made of x87 arithmetic. The most expensive
ones, by address in `client.dll`:

| RVA | What it does |
|---|---|
| `0x45E10` | 4×4 matrix multiply |
| `0x46510` | quaternion to rotation matrix |
| `0x183250` | rotate a vector by a quaternion |
| `0x48A360`, `0x48A470`, `0x48A590` | bounding box against planes (culling) |
| `0x2F9900`–`0x2FF400` | a cluster of about a dozen routines that looks like skeletal animation |
| `0x6A92D8` | the compiler's float-to-integer helper (`_ftol2`), called from 697 places |

Below these there are many smaller ones: the top 25 routines were about 60% of the time, and it
takes several hundred to cover 90%.

### 2. The render throttle hides the problem

The client has an automatic limiter that we had not seen documented. Its settings and their
built-in defaults:

| Setting | Default |
|---|---|
| `Client_RenderThrottle_TargetMinFrameRate` | 30 |
| `Client_RenderThrottle_Step` | 0.05 |
| `Client_RenderThrottle_Min` | 0.25 |
| `Client_RenderThrottle_Hysteresis` | 0.3 |
| `Client_RenderThrottle_FramesForChange` | 15 |
| `Client_RenderThrottle_Override` | 0 (automatic) |

The routine at `client.dll+0x28E0` keeps a factor between 0.25 and 1. When the frame rate stays
below 30 × factor for 15 frames, the factor drops by 0.05; when it stays 30% above that, it
rises. The factor scales the draw distances, and the scaled values are what the client writes
back to `options.cfg` on exit (`dl_*_prefetchradius`, `wr_*dist`, `*camerafarz`). A non-zero
`Client_RenderThrottle_Override` holds the factor at that value.

So on a slow machine the game does not get much slower, it draws less. Our first measurements
looked like "14–16 fps before, 17–19 after a big improvement" because the throttle was spending
every gain on draw distance. With `Client_RenderThrottle_Override = 1` the same scene ran at
8.5 fps before the math fix.

### 3. CrossOver's graphics paths

CrossOver's default for Direct3D 9 is Wine's own implementation on OpenGL. It works, but it is
slow at passing draw calls on to the GPU: in a standalone test with 2,000 draws per frame it
reached 172 fps where DXVK reached 278, and 9–50 fps where the test updates dynamic buffers the
way games do (DXVK: about 300).

CrossOver also ships DXVK (Direct3D on Vulkan, on Metal through MoltenVK). With this client it
gives a black screen with sound. We found four separate defects:

1. **A typo in CodeWeavers' DXVK 1.10.3 source** (`info.pushConstSize = m_pushConstOffset;`,
   should be `m_pushConstSize`, in `d3d9_fixed_function.cpp` and `dxso_compiler.cpp`). Because
   of it, every Direct3D 9 pixel shader fails to compile on Metal. This is the black screen.
2. **Several texture types in one slot.** For every texture slot, DXVK puts a 2D, a 3D, a cube
   and a shadow version into the shader and chooses one when the shader is used. Metal does not
   allow more than one texture type per slot, so the in-world shaders fail to compile.
3. **Work sent to the GPU that never finishes.** With MoltenVK's default setting, DXVK froze in
   about 7 of 10 runs, waiting for a batch of work that was never reported as done.
   `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1` avoids it.
4. **One-second page faults.** `matrix.exe` is not marked NX-compatible (the flag that lets
   Windows keep data memory non-executable), so Wine makes all of its readable memory
   executable too. Under Rosetta, the first write to each new page of memory shared with the
   GPU then takes about a second. The game ran at 0.1 fps.

### 4. Stalls in the graphics layer once the math is fast

With the math fixed, the main thread spent more than half of a fullscreen session waiting for
the graphics layer. We found two causes, and one display glitch:

- **Buffer locks that wait for the GPU.** The client locks dynamic vertex buffers without
  `D3DLOCK_DISCARD` or `D3DLOCK_NOOVERWRITE`, about 40 times per frame. This DXVK version then
  sends everything queued so far to the GPU, stops drawing into the current target, and waits
  until the GPU has finished with the buffer. A standalone test that does this before every
  draw ran at 1 fps.
- **Texture uploads that break up the frame.** Direct3D 9 uploads a managed texture right before
  the first draw that uses it. This DXVK version stops drawing into the current target for
  every such upload and starts again afterwards. Apple GPUs draw a frame in small tiles, and
  each time drawing is interrupted they have to write out and read back the whole 3440×1440
  colour and depth images. While the world is loading in around the player, the client uploads
  about a dozen textures per frame.
- **Picture in the corner.** If macOS does not switch the display to 800×600 for the login
  screen, the surface stays 3440×1440 and DXVK draws the 800×600 picture unscaled in the top
  left corner.

Later sessions at 3440×1440 turned up three more:

- **All 8,192 vertex shader constants copied on every draw.** The client creates its device
  with mixed vertex processing, which gives software vertex shaders 8,192 constant registers.
  DXVK normally copies only the registers the game has set, and relies on a Vulkan feature
  (`robustness2`) to return zero for the rest. MoltenVK does not offer that feature, so this
  DXVK version copies all 8,192 registers, 128 KB, for each of the 1,000–1,500 constant updates
  per frame, each time into fresh memory. In Rejacked this froze the game at 3–8 fps for about
  50 seconds while entering the world, and the client never sets more than 248 registers.
- **Freed memory handed back to the system.** DXVK keeps at most one empty 16 MB block of
  CPU-visible memory and returns the others. Revived streams textures and geometry constantly,
  so it kept getting brand-new memory, and writing to new memory is slow for this client under
  Rosetta. Revived ran at 1–4 fps in the world.
- **Running out of address space.** `matrix.exe` is a 32-bit program without the "large address
  aware" flag, so it gets 2 GB. With DXVK, after about a minute in the world an allocation in
  `client.dll` failed and the game crashed.
- **One-second stalls when the Mac is short of memory.** With other programs open, macOS
  compresses or swaps out memory the game is not using at that moment. The next write to such
  a page of memory shared with the GPU pays the same one-second penalty as a first write. A
  stall recorder in the DLL showed the main thread stuck on single writes for about a second:
  in texture and buffer locks, in DXVK's own copies and in the game's code. The same setup was
  smooth in one session and stalled every frame in the next, depending on what else was
  running. On the test machine 9 GB of swap were in use at the time.

## What we do about it

Everything is in one file: a custom build of DXVK's `d3d9.dll`, made from CodeWeavers' own DXVK
source for CrossOver 26.3 plus `dxvk/dxvk-d3d9-mxo.patch`. It is installed into the CrossOver
bottle and enabled only for the game executable, so launchers and everything else keep Wine's
Direct3D 9. No game file is modified on disk.

### Graphics fixes

| Problem | Fix |
|---|---|
| Push-constant typo | corrected |
| Several texture types in one slot | a separate copy of the shader for each combination of texture types the game actually uses, compiled when first needed |
| First-write page faults | each block of such memory is touched once, through the system (`VirtualLock`/`VirtualUnlock`), at the moment it is allocated |
| GPU work that never finishes | `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1` in the bottle's environment |
| Buffer lock waits for the GPU | the game gets a fresh copy of the buffer to write into; draws already queued keep using the old one (standalone test: 1 fps to 22 fps, same picture) |
| Texture upload interrupts drawing | if nothing drawn so far in the frame uses the texture or buffer, the upload is moved to the start of the frame (standalone test with 250 new textures per frame: 251 interruptions to 2, 57 fps to 120, same picture) |
| Picture in the corner | the picture is scaled to the surface whenever the two sizes differ |
| 8,192 constants per draw | vertex shaders get the number of registers actually uploaded as a push constant, read index 0 instead of going past it, and return zero beyond it, as Direct3D 9 expects. Only the registers the game has set to non-zero values are uploaded (about 250 instead of 8,192) |
| Freed memory handed back | emptied CPU-visible memory blocks are kept for reuse, up to 256 MB per memory type |
| Address space | `WINE_LARGE_ADDRESS_AWARE=1` in the bottle's environment gives the 32-bit game 4 GB |
| Triangle fans | Metal has no triangle fans, so MoltenVK turns every fan draw into a small compute job first, which interrupts the drawing pass. The game draws its map as about 800 fans per frame (10 fps with the map open). Fans are now drawn as indexed triangle lists with a prepared index buffer: map 10 to 30 fps, and in the world the GPU went from fully busy to about 45% idle |
| Work sent to the GPU mid-frame | DXVK submitted work after many buffer unlocks; each submission ends the drawing pass. Those hints now submit only when the GPU has nothing queued |
| Compiler | Homebrew's 32-bit GCC uses setjmp/longjmp exceptions: registering and unregistering an unwind frame on nearly every function call, through Wine's thread-local storage. Built with llvm-mingw (DWARF unwinding, no cost until something throws), the DLL's share of the main thread fell from 14% to 7%. The translated routines assemble to the same instructions |
| `sqrt` | The game calls `MSVCR71!sqrt`, which Wine implements with the x87 `fsqrt`; Rosetta emulates it at about 500 ns per call, 3% of the main thread. The client's import of it now points at an SSE2 version (50 ns) that gives the same bits: it computes only when the thread runs at 24-bit or 53-bit precision with rounding to nearest, the input is positive and finite, and (at 24 bits) the result is a normal float that does not sit exactly halfway between two floats; anything else goes to Wine's `sqrt`. `DXVK_MXO_SQRT=0` turns it off |
| Stalls under memory pressure | memory shared with the GPU stays locked in RAM (`VirtualLock`), so macOS cannot compress or swap it out; it is released when the memory is freed |

### Replacing the x87 routines

`translator/xlat.py` reads a routine of `client.dll` and writes equivalent SSE2 assembly:

- Each x87 register becomes an SSE register holding a double. The x87 registers form a stack,
  and the depth of that stack at each instruction can be worked out in advance, so every stack
  slot gets a fixed SSE register.
- **Results are identical for every value a `float` can hold.** Direct3D 9 puts the FPU in
  24-bit precision mode. In that mode every add, subtract, multiply, divide and square root is
  rounded to 24 significant bits (the precision of a `float`) but can still hold far larger and
  smaller numbers than a `float` can. The translation computes in double precision and then
  rounds each result by converting it to `float` and back (two instructions). That is exact
  as long as the intermediate result fits in a `float`. Outside that range it differs: a value
  above `FLT_MAX` becomes infinity where the FPU would keep it, and a value below the smallest
  normal `float` loses precision. Bounding-box code uses values like `FLT_MAX` to mean "no
  limit", so this is a real trade-off. `xlat.py --exact-range` produces the older form, which
  also reproduces the extended range bit for bit, at 13 instructions per rounding instead of
  2. The game has been played with the faster form without visible problems; if something
  looks wrong, build with `--exact-range` first.
- **Single precision where possible.** In the faster form, every value loaded from a `float`
  and every result of two such values stays a `float` in the low lane of its SSE register and is
  computed with single-precision instructions (`addps`, `mulps`, `divss`, `sqrtss`, `ucomiss`,
  `cvttss2si`). A double is made only when a value meets a double operand, and at branches,
  labels and returns, where every register holds a double again. Because a 24-bit result
  rounded once more to 24 bits does not change, this gives the same bits as computing in double
  and rounding: 527 routines now need 55,500 instructions instead of 78,600, and conversions
  between float and double fell from 27,600 to 6,100.
- **Compares branch directly.** The original reads the FPU status word (`fnstsw ax`), tests bits of `ah`
  and jumps. Rebuilding that status word from an SSE compare takes `lahf` and parity flags, which Rosetta
  computes in software. Where the code only tests `ah` and jumps, and flow analysis shows that neither the
  flags nor the bytes of `ax` holding the status word are read again before being overwritten, the
  translation branches on the SSE compare itself (1,316 of 1,607 places in the current list). A routine
  that returns a `bool` in `al` may then return a different, unused `ah`.
- **`floor` and `ceil`** called through the client's import table are computed in place with SSE4.1
  `roundsd`, which gives the same bits as msvcr71's functions. The installer keeps such a routine original
  if the import slot does not hold msvcr71's own function.
- **Float results between translated routines** stay in an SSE register: a translated routine whose
  every return leaves one value on the FPU stack gets a second entry that returns it in `xmm0`, and
  translated callers call that entry. The installer installs a caller only together with its callees.
- Integer instructions are copied unchanged. Translated code never changes the CPU flags,
  because x87 code does not either and the surrounding integer code relies on that.
- Compares followed by `fnstsw ax` produce the same condition bits in `AH`.
- Calls into other client routines, absolute addresses and switch tables are adjusted at load
  time to wherever `client.dll` actually sits in memory.
- The translator refuses anything it cannot prove safe, and the routine then simply stays as it
  is: code that reads or changes the FPU control word, FPU stacks deeper than six, routines
  that take arguments on the FPU stack, routines that other code jumps into the middle of.

`translator/routines.list` names the routines to translate (address, length and a hash, no
code). It was built from sampling profiles of the game. `_ftol2` is replaced by a short routine
that handles the 32-bit range with SSE2 and falls back to the original otherwise.

At run time, when the game creates its Direct3D device, the DLL:

1. checks each routine in the loaded `client.dll` byte for byte against the code its replacement
   was generated from, and skips any that differ (for example because a wrapper has hooked it);
2. pauses all other threads, writes a 5-byte jump at the start of each matching routine, and
   resumes them;
3. on every frame checks that the FPU control word is still what the translation assumes
   (24-bit precision, round to nearest) and switches the replacements off if it is not.

The replacements run only on the thread that owns the Direct3D device. Other threads have a
different FPU precision, so for them the jump leads to a few instructions that do what the
jump overwrote and then continue in the original routine.

### How it was checked

- **Synthetic routines** covering every instruction form the translator handles, compared with
  the original x87 code on random inputs including huge, tiny, zero, infinite and NaN values:
  6.6 million comparisons, all identical.
- **The game's routines**, each called as original and as translation on random memory: 278 of
  the 468 translated at the time could be run this way, 20,504 comparisons. 262 were identical in every run. The other
  16 differed only in situations that random input creates and the game does not: doubles too
  small or too large to occur in practice, two NaNs meeting in one operation, and a called
  routine that fails to return a value it should have.
- **The faster rounding**: 200,000 random cases per synthetic test with ordinary values, no
  differences. The game routines, run again with it: the only new differences involve
  denormal numbers, which only random input produces.
- **The float-to-integer replacement**: 400,000 values over the whole range, identical.
- **Single precision**: 3.3 million synthetic cases identical to the double form; the game's
  routines, run against the double form, matched except `0x3B9A10`, which was taken out of the
  list. With ordinary values only (`MXO_PLAIN=1`), the one remaining difference is `0x2FE670`,
  where an intermediate product exceeds the `float` range (the trade-off described above).
- **In the game**: short sessions on Rejacked and Revived, in fullscreen at 3440×1440.
- **The generated shaders** (288 in total, both games) pass the Vulkan validator `spirv-val`.

The test programs are in `tests/`.

## Results

Loading area (windowed 800×600):

| | Frame rate |
|---|---|
| Stock CrossOver | 8–18 fps |
| With this DLL | 85–89 fps |

In the world, same spot, windowed 1280×720, throttle pinned at full detail
(`Client_RenderThrottle_Override = 1`):

| | Frame rate |
|---|---|
| Fixed DXVK, original math | 8.5 fps |
| Fixed DXVK, first translated build | 23–29 fps |

Two caveats on that pair. The second number was taken while the external monitor was being
reconfigured and the game was drawing an 800×600 view, so it is not a strictly fair comparison. And
that build was later found to lack 12 of the most expensive routines; the current build has not been
measured this way.

In the world, fullscreen 3440×1440, throttle on automatic, from the player's own sessions
(short, right after entering the world, while it was still streaming in):

| Build | Frame rate | Draw distance chosen by the throttle |
|---|---|---|
| Translated math only | 17–25 fps | 60–90% |
| + buffer lock fix, the 12 missing routines | 22–25 fps | 70–80% |
| + texture upload fix | about 23 fps | 100% (first seconds in the world) |

We have no measured fullscreen number for stock CrossOver. Windowed with the throttle on
automatic it was 14–16 fps at an unknown, reduced draw distance. The player describes the
difference as large.

What a frame in the world looks like now: about 2,700 draw calls, 40 buffer locks handled by
copy, and 12 texture uploads, none of which interrupts drawing any more. Drawing is still split
into 19 separate passes per frame, for the reasons under Open problems.

With all fixes (current build), fullscreen 3440×1440, maximum detail, anti-aliasing on, throttle
on automatic, music on, from the player's own sessions of one to two minutes:

| | In the world | Entering the world |
|---|---|---|
| Rejacked | 44–64 fps | no stall (was about 50 s at 3–8 fps) |
| Revived | 44–57 fps (was 1–4 fps) | no stall |

The GPU was busy 93–100% of the time in both, so at this resolution the graphics chip is now
the limit. What is left are single slow frames: mostly frames with 4,000–6,000 draw calls,
plus a few hundred-millisecond pauses while signing in or loading, and one 0.6-second pause in
the world with no graphics activity at all (so it comes from the game itself).

With single precision in 527 routines (v26), same settings, about 3,000–4,500 draw calls per
frame:

| | In the world |
|---|---|
| Rejacked | 42–74 fps, 62 on average |
| Revived | 42–65 fps, 58 on average |

With the map's grid lookup translated (v27) and the llvm-mingw build (v28), Rejacked averaged 67
fps in the world, against 61–62 before, at about 3,300 draw calls per frame. Opening the map now
costs about 5 fps (it was 15–20): one routine, at `0x47DDB0`, had taken 18% of the main thread
with the map open.

With the `sqrt` replacement (v30) and the translator changes above (v33), translated routines went from
43% to 38.5% of the main thread, and Rejacked's average in the world went from 67 to 69–78 fps
depending on the scene.

Settings that changed the numbers:

| Setting | Effect at 3440×1440 |
|---|---|
| Rejacked launcher, "new glow shader for Screen Filter: Over-Bright (BETA)" | halves the frame rate (18–29 fps instead of 36–52) |
| Anti-aliasing | costs a few fps |
| The green "Matrix" tint | costs nothing measurable |

## Open problems

- **Revived with music was slow in several sessions and fast in others,** with the same files
  and settings. The stall recorder later showed the memory-pressure stalls described above,
  which fit that pattern; with memory kept locked, Rejacked's stalls disappeared. Revived with
  music has not been played with that fix yet.
- **Pipeline builds.** The first time a new combination of shader and render state appears,
  this DXVK version builds the pipeline on the spot: one 0.2-second hitch in the world in the
  last session. The pipeline is then cached on disk, so it does not happen again.
- **Measuring changes the result.** The DLL's sampling profiler pauses every thread every 5 ms.
  That made memory writes in the game look extremely slow (tens of milliseconds for a few
  kilobytes) and sent us after a problem that only existed while profiling. A lighter mode
  samples only the main thread every 20 ms (BUILD.md).
- **The graphics side is the limit in fullscreen now.** Drawing is split into about 19 passes
  per frame: about 11 because the game itself switches render targets, the rest from clears,
  one copy between targets and DXVK sending work mid-frame. Each return to the main target reads
  back 3440×1440 of colour and depth on a tile-based GPU. That is the next thing to look at.
- **Revived's sign-in takes 4–5 seconds of typing.** The Revived launcher hands the account and
  password to the 2009 login console, which types them out at about four characters a second
  with the processor idle. That pace is set in the launcher, not by the Mac.
- **One unexplained freeze** at the loading screen with an early build. It has not recurred.
- **The 800×600 login screen** sometimes comes up without a display mode switch. The picture is
  scaled to fit, but mouse coordinates in that state are unverified.
- **Not tested:** long sessions, combat, interiors, other districts, anything but one M4 Mac.

## Other platforms

We tested one setup: an Apple M4 Mac with CrossOver. Everything in this section is what we
expect from how the fixes work. None of it has been measured.

**The math replacement should help wherever x86 code is translated and x87 is emulated in
software.** The cost it removes comes from the translator, not from macOS or CrossOver.

| Platform | What we expect |
|---|---|
| Any Apple Silicon Mac running the client through Rosetta 2: CrossOver, other Wine builds, Whisky, Apple's Game Porting Toolkit | The same gain. It is the same translator with the same x87 cost. |
| Linux on ARM with FEX-Emu | Probably a gain. As far as we know FEX emulates x87 in software too, unless it is told to reduce precision. |
| Windows on ARM | Unknown. Windows translates x86 itself there, and we have not looked at how it handles x87. |
| Real x86 processors: Windows PCs, Linux and Proton on x86, Steam Deck, Intel Macs | No gain, probably a small loss. x87 runs natively and fast there, and the translated code does extra work for every operation to reproduce the FPU's rounding. |

Two consequences if you ship the math replacement more widely:

- It should be switched on only where x87 is emulated. Our DLL does not check this today; it
  assumes it is running on Apple Silicon. A simple check is to time a few thousand x87
  multiplications against the same in SSE2 at startup.
- It does not need our graphics DLL (see question 2 below), so it can reach players on any
  graphics path.

**The graphics fixes are narrower.**

- The typo, the texture-type variants, the memory pre-touch and the MoltenVK setting are
  specific to CodeWeavers' DXVK 1.10.3 on macOS.
- The vertex shader constant fix matters on any Vulkan driver without `robustness2` (MoltenVK
  among them). Keeping freed memory helps wherever writing to new memory is slow.
- The buffer-lock and texture-upload changes address how DXVK 1.10 behaves on any system. They
  matter most on tile-based GPUs such as Apple's, where interrupting drawing is expensive; on
  desktop GPUs it is cheap. Newer DXVK versions have reworked this code, so check what your
  version does before porting them.

## What is in this repository

| Path | Contents |
|---|---|
| `dxvk/dxvk-d3d9-mxo.patch` | all changes to CodeWeavers' DXVK 1.10.3 source |
| `translator/xlat.py` | the x87 to SSE2 translator |
| `translator/discover.py` | finds function boundaries in `client.dll` |
| `translator/routines.list` | the routines to translate: address, length, hash |
| `translator/profile2.py` | turns the DLL's sampling output into a per-thread profile and a routine list |
| `tests/` | differential tests: translation against original code |
| `bench/d3d9bench.rs` | standalone Direct3D 9 benchmark used for the graphics fixes |
| `scripts/build.sh` | builds `d3d9.dll` from a `client.dll` and the CodeWeavers source |
| `scripts/setup.sh` | guided setup of a CrossOver bottle: start fixes, build, install, Revived music, uninstall |
| [`CROSSOVER.md`](CROSSOVER.md) | getting the game to run in CrossOver in the first place: bottle, launcher, the three fixes it needs to start |
| [`BUILD.md`](BUILD.md) | building the DLL, installing it into a bottle, switches, going back |

## Licence and credits

DXVK is by Philip Rebohle, Joshua Ashton and contributors, under the zlib/libpng licence; the
patch here is a derivative of it and carries the same licence, as does the rest of this
repository (see `LICENSE`). The DXVK source it applies to is the one CodeWeavers publish for
CrossOver. The Matrix Online is the property of its owners; this repository contains none of it.
