# Graphics: what fails in CrossOver and the fixes

The DLL is a custom build of DXVK's `d3d9.dll`. DXVK runs Direct3D 9 on Vulkan, and MoltenVK runs
Vulkan on Apple's Metal. The build is the DXVK 1.10.3 source that CodeWeavers publish for
CrossOver 26.3, plus `dxvk/dxvk-d3d9-mxo.patch`. Only the game uses it: launchers and other
programs keep Wine's Direct3D 9. No game file is changed on disk.

| Fixes | How to turn them off |
|---|---|
| 2 and 4 to 11 | a switch each, in [building.md](building.md#switches) |
| 1, 13 and 14 | always on |
| 3 and 12 | settings of the bottle |
| 15 | the choice of compiler |

What each fix gave is in [measurements.md](measurements.md#what-each-fix-gave).

## CrossOver's two stock paths

- **Wine's Direct3D 9 on OpenGL** is the default. It works but is slow at passing draw calls
  on: a test program with 2,000 draws per frame reached 172 fps, against 278 with DXVK.
  Fullscreen gives a black screen.
- **CrossOver's DXVK** gives a black screen with sound, for the reasons in problems 1 to 4.

## Problems and fixes

### 1. Every pixel shader fails to compile

CodeWeavers' DXVK source has a typo in `d3d9_fixed_function.cpp` and `dxso_compiler.cpp`:
`info.pushConstSize = m_pushConstOffset;` where it should be `m_pushConstSize`. Every pixel
shader then fails to compile on Metal. This is the black screen.

**Fix:** the typo is corrected.

### 2. Several texture types in one slot

For every texture slot, DXVK puts a 2D, a 3D, a cube and a shadow version into the shader and
picks one when it runs. Metal allows one texture type per slot, so the world's shaders fail to
compile.

**Fix:** a copy of the shader for each combination of texture types the game uses, compiled when
first needed. All 288 shaders of the two games pass the Vulkan validator `spirv-val`.

### 3. Work sent to the GPU that never finishes

With MoltenVK's default setting, DXVK froze in about 7 of 10 runs, waiting for GPU work that was
never reported as done.

**Fix:** `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1` in the bottle's environment.

### 4. One-second page faults

`matrix.exe` is not marked NX-compatible, so Wine makes all of its readable memory executable
too. Under Rosetta, the first write to each new page of memory shared with the GPU then takes
about a second. The game ran at 0.1 fps.

**Fix:** each new block of such memory is touched once through the system, with `VirtualLock`,
as soon as it is allocated.

### 5. One-second stalls when the Mac is short of memory

When memory runs short, macOS compresses or swaps out memory the game is not using at that
moment. The next write to such a page of GPU-shared memory again takes about a second. The same
setup could be smooth in one session and stall every frame in the next.

**Fix:** memory shared with the GPU stays locked in RAM until it is freed.

### 6. Buffer locks that wait for the GPU

A game locks a buffer to write into it. This game locks its dynamic vertex buffers about 40 times
per frame without `D3DLOCK_DISCARD` or `D3DLOCK_NOOVERWRITE`, the flags that make waiting
unnecessary. This DXVK version then sends all queued work to the GPU, stops drawing and waits
until the GPU is done with the buffer.

**Fix:** the game gets a fresh copy of the buffer to write into, and draws already queued keep
the old one. A buffer still locked from an earlier call waits as before. A test program that
locks before every draw went from 1 to 22 fps, with the same picture.

### 7. Texture uploads that break up the frame

Direct3D 9 uploads a managed texture right before the first draw that uses it. This DXVK version
stops drawing for each upload and starts again afterwards. Apple GPUs draw in small tiles, and
each interruption makes them write out and read back the whole colour and depth images. While the
world loads around the player, the game uploads about a dozen textures per frame.

**Fix:** if no draw queued so far uses the texture or buffer, its upload goes into a batch the
GPU runs before the drawing. A test program with 250 new textures per frame went from 251
interruptions to 2, and from 57 to 120 fps, with the same picture.

### 8. All 8,192 vertex shader constants copied on every draw

Constants are the values a game hands to its vertex shaders. The game asks for mixed vertex
processing, which gives software vertex shaders 8,192 constant registers. DXVK normally copies
only the registers the game has set, and relies on a Vulkan feature, `robustness2`, to return
zero for the rest. MoltenVK lacks that feature, so this DXVK version copies all 8,192 registers,
128 KB, into fresh memory for each of the 1,000–1,500 constant updates per frame. The game never
sets more than 248.

**Fix:** each vertex shader is told how many registers were copied, as a push constant (a small
value sent with each draw), and returns zero beyond that, as Direct3D 9 expects. The copy ends
at the highest register set to a value other than zero: about 250 instead of 8,192.

### 9. Freed memory handed back to the system

DXVK keeps at most one empty block of CPU-visible memory and returns the others to the system.
Revived streams textures and geometry all the time, so it kept getting new memory, and writing to
new memory is slow for this game under Rosetta. Revived ran at 1–4 fps in the world.

**Fix:** emptied blocks are kept for reuse, up to 256 MB per memory type.

### 10. Triangle fans

A triangle fan is a shape of triangles that all share one corner. Metal has no fans, so MoltenVK
turns each fan draw into a small compute job first, which interrupts drawing. The game draws its
map as about 830 fans per frame: 10 fps with the map open.

**Fix:** fans are drawn as indexed triangle lists from a prepared index buffer. That covers the
fans drawn without an index buffer (`DrawPrimitive` and `DrawPrimitiveUP`), which are the ones
the game draws. A fan with its own index buffer still goes to MoltenVK as a fan.

### 11. Work sent to the GPU mid-frame

DXVK sent queued work to the GPU after many buffer unlocks and similar hints, and each submission
ends the drawing pass.

**Fix:** those hints send work only when the GPU has nothing queued.

### 12. Running out of address space

`matrix.exe` is a 32-bit program without the "large address aware" flag, so it can use only
2 GB of memory. With DXVK it crashed after about a minute in the world.

**Fix:** `WINE_LARGE_ADDRESS_AWARE=1` in the bottle's environment gives it 4 GB.

### 13. Picture in the corner

If macOS does not switch the display to 800×600 for the login screen, the drawing surface keeps
the display's size and DXVK draws the 800×600 picture unscaled in the top left corner.

**Fix:** the picture is scaled to the surface whenever the two sizes differ.

### 14. Window sized before the display mode switch finished

Under Wine, the switch to another display mode completes after DXVK has sized the fullscreen
window. A 3440×1440 window on the 800×600 login screen showed only its top left part.

**Fix:** the window is sized to the monitor again when Windows reports the change
(`WM_DISPLAYCHANGE`). In case that never comes, a check every 60 frames does the same, at most
three times per display mode. Neither path touches a device created with
`D3DCREATE_NOWINDOWCHANGES` or acts on a failed or empty monitor query.

### 15. Exception bookkeeping in the DLL itself

Homebrew's 32-bit GCC handles C++ exceptions with setjmp/longjmp, which registers and
unregisters an unwind frame on nearly every function call, through Wine's thread-local storage.

**Fix:** the DLL is built with llvm-mingw, whose exceptions cost nothing until one is thrown.
That halved the DLL's share of the main thread. The translated routines assemble to the same
instructions.

## What a frame looks like now

About 3,600 draw calls, 40 buffer locks handled by copying and, while the world streams in, a
dozen texture uploads. None of them interrupts drawing.

Drawing is still split into passes. A count taken before fix 11 gave about 19 per frame: about
11 from the game switching render targets, the rest from clears, one copy between targets and
mid-frame submissions. The frame log of the current build shows 60 to 100 per frame in the
world. Why the two counts differ is not known. Each return to the main target reads back its
colour and depth images.

A new combination of shader and render state makes this DXVK version build a pipeline (the GPU's
compiled form of it) on the spot, a short hitch. Pipelines are cached on disk, and
`scripts/merge-pipeline-caches.py` lets the games in a bottle share their caches.

## Which fixes matter elsewhere

| Fixes | Where they matter |
|---|---|
| 1 typo, 2 texture types, 3 MoltenVK setting, 4 touching new memory | only CodeWeavers' DXVK 1.10.3 on macOS |
| 8 vertex shader constants | any Vulkan driver without `robustness2` |
| 9 keeping freed memory | wherever writing to new memory is slow |
| 6 buffer locks, 7 texture uploads | DXVK 1.10 on any system, most on tile-based GPUs such as Apple's, where interrupting drawing is expensive. Newer DXVK versions have reworked this code. |
