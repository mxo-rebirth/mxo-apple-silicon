# Graphics: what fails in CrossOver and the fixes

The DLL is a custom build of DXVK's `d3d9.dll` (Direct3D 9 on Vulkan, on Metal through
MoltenVK), made from the DXVK 1.10.3 source CodeWeavers publish for CrossOver 26.3 plus
`dxvk/dxvk-d3d9-mxo.patch`. It is installed into the bottle and enabled for the game executable
only, so launchers and everything else keep Wine's Direct3D 9. No game file is modified on disk.

Each fix has a switch that turns it off; they are listed in [building.md](building.md#switches).

## CrossOver's two stock paths

**Wine's Direct3D 9 on OpenGL** is the default. It works but is slow at passing draw calls on.
In a standalone test with 2,000 draws per frame it reached 172 fps where DXVK reached 278, and
9–50 fps where the test updates dynamic buffers the way games do (DXVK: about 300). Fullscreen
gives a black screen.

**CrossOver's DXVK** gives a black screen with sound. Problems 1 to 4 below are the reasons.

## Problems and fixes

### 1. Every pixel shader fails to compile

CodeWeavers' DXVK 1.10.3 source has a typo: `info.pushConstSize = m_pushConstOffset;` where it
should be `m_pushConstSize`, in `d3d9_fixed_function.cpp` and `dxso_compiler.cpp`. Every
Direct3D 9 pixel shader then fails to compile on Metal. This is the black screen.

Fix: corrected.

### 2. Several texture types in one slot

For every texture slot, DXVK puts a 2D, a 3D, a cube and a shadow version into the shader and
chooses one when the shader is used. Metal does not allow more than one texture type per slot,
so the in-world shaders fail to compile.

Fix: a separate copy of the shader for each combination of texture types the game actually
uses, compiled when first needed. The 288 shaders generated for both games pass the Vulkan
validator `spirv-val`.

### 3. Work sent to the GPU that never finishes

With MoltenVK's default setting, DXVK froze in about 7 of 10 runs, waiting for a batch of work
that was never reported as done.

Fix: `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1` in the bottle's environment.

### 4. One-second page faults

`matrix.exe` is not marked NX-compatible, so Wine makes all of its readable memory executable
too. Under Rosetta, the first write to each new page of memory shared with the GPU then takes
about a second. The game ran at 0.1 fps.

Fix: each block of such memory is touched once, through the system
(`VirtualLock`/`VirtualUnlock`), at the moment it is allocated.

### 5. One-second stalls when the Mac is short of memory

With other programs open, macOS compresses or swaps out memory the game is not using at that
moment. The next write to such a page of GPU-shared memory pays the same one-second penalty as
a first write. A stall recorder in the DLL showed the main thread stuck on single writes for
about a second: in texture and buffer locks, in DXVK's own copies and in the game's code. The
same setup was smooth in one session and stalled every frame in the next. On the test machine
9 GB of swap were in use at the time.

Fix: memory shared with the GPU stays locked in RAM, so macOS cannot compress or swap it out.
It is released when the memory is freed.

### 6. Buffer locks that wait for the GPU

The client locks dynamic vertex buffers without `D3DLOCK_DISCARD` or `D3DLOCK_NOOVERWRITE`,
about 40 times per frame. This DXVK version then sends everything queued so far to the GPU,
stops drawing into the current target, and waits until the GPU has finished with the buffer.

Fix: the game gets a fresh copy of the buffer to write into; draws already queued keep using
the old one. Standalone test that locks before every draw: 1 fps to 22 fps, same picture.

### 7. Texture uploads that break up the frame

Direct3D 9 uploads a managed texture right before the first draw that uses it. This DXVK
version stops drawing into the current target for every such upload and starts again
afterwards. Apple GPUs draw a frame in small tiles, and each time drawing is interrupted they
write out and read back the whole 3440×1440 colour and depth images. While the world loads in
around the player, the client uploads about a dozen textures per frame.

Fix: if nothing drawn so far in the frame uses the texture or buffer, the upload is moved to
the start of the frame. Standalone test with 250 new textures per frame: 251 interruptions to
2, 57 fps to 120, same picture.

### 8. All 8,192 vertex shader constants copied on every draw

The client creates its device with mixed vertex processing, which gives software vertex shaders
8,192 constant registers. DXVK normally copies only the registers the game has set and relies
on a Vulkan feature (`robustness2`) to return zero for the rest. MoltenVK does not offer that
feature, so this DXVK version copies all 8,192 registers, 128 KB, for each of the 1,000–1,500
constant updates per frame, each time into fresh memory. In Rejacked this froze the game at 3–8
fps for about 50 seconds while entering the world. The client never sets more than 248
registers.

Fix: vertex shaders get the number of registers actually uploaded as a push constant, read
index 0 instead of going past it, and return zero beyond it, as Direct3D 9 expects. Only the
registers the game has set to non-zero values are uploaded: about 250 instead of 8,192.

### 9. Freed memory handed back to the system

DXVK keeps at most one empty 16 MB block of CPU-visible memory and returns the others. Revived
streams textures and geometry constantly, so it kept getting brand-new memory, and writing to
new memory is slow for this client under Rosetta. Revived ran at 1–4 fps in the world.

Fix: emptied blocks are kept for reuse, up to 256 MB per memory type.

### 10. Triangle fans

Metal has no triangle fans, so MoltenVK turns every fan draw into a small compute job first,
which interrupts the drawing pass. DXVK's counters do not show it. The game draws its map as
about 830 fans per frame: 10 fps with the map open.

Fix: fans are drawn as indexed triangle lists with a prepared index buffer. Map 10 to 30 fps;
in the world the GPU went from fully busy to about 45% idle.

### 11. Work sent to the GPU mid-frame

DXVK submitted work after many buffer unlocks, and each submission ends the drawing pass.

Fix: those hints submit only when the GPU has nothing queued.

### 12. Running out of address space

`matrix.exe` is a 32-bit program without the "large address aware" flag, so it gets 2 GB. With
DXVK, after about a minute in the world an allocation in `client.dll` failed and the game
crashed.

Fix: `WINE_LARGE_ADDRESS_AWARE=1` in the bottle's environment gives it 4 GB.

### 13. Picture in the corner

If macOS does not switch the display to 800×600 for the login screen, the surface stays
3440×1440 and DXVK draws the 800×600 picture unscaled in the top left corner.

Fix: the picture is scaled to the surface whenever the two sizes differ.

### 14. Window sized before the display mode switch finished

Under Wine the switch to another display mode completes after DXVK has sized the fullscreen
window, so a 3440×1440 window on the 800×600 login screen showed only its top left part.

Fix: the window is sized to the monitor again when `WM_DISPLAYCHANGE` arrives. A check every 60
frames does the same in case that message never comes, at most three times per display mode, so
a window that cannot take the monitor's size is not fought over. Neither path touches a device
created with `D3DCREATE_NOWINDOWCHANGES`, and neither acts on a failed or empty monitor query.

### 15. Exception bookkeeping in the DLL itself

Homebrew's 32-bit GCC uses setjmp/longjmp exceptions: it registers and unregisters an unwind
frame on nearly every function call, through Wine's thread-local storage.

Fix: the DLL is built with llvm-mingw (DWARF unwinding, no cost until something throws). Its
share of the main thread fell from 12% to 6%. The translated routines assemble to the same
instructions.

## What a frame looks like now

About 3,600 draw calls, 40 buffer locks handled by copy and, while the world streams in, a dozen
texture uploads, none of which interrupts drawing. Drawing is still split into passes. The last
count, taken before fix 11, was about 19 per frame: about 11 because the game itself switches
render targets, the rest from clears, one copy between targets and mid-frame submissions. Each
return to the main target reads back 3440×1440 of colour and depth on a tile-based GPU.

The first time a new combination of shader and render state appears, this DXVK version builds
the pipeline on the spot, which can take 0.2 seconds. The pipeline is then cached on disk.
`scripts/merge-pipeline-caches.py` lets the games in a bottle share their caches.

## Which fixes matter elsewhere

- The typo, the texture-type variants, the memory pre-touch and the MoltenVK setting are
  specific to CodeWeavers' DXVK 1.10.3 on macOS.
- The vertex shader constant fix matters on any Vulkan driver without `robustness2`. Keeping
  freed memory helps wherever writing to new memory is slow.
- The buffer-lock and texture-upload changes address how DXVK 1.10 behaves on any system. They
  matter most on tile-based GPUs such as Apple's, where interrupting drawing is expensive. Newer
  DXVK versions have reworked this code.
