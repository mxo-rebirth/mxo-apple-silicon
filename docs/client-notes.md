# The client: reverse-engineering notes

How the game client works, as far as it matters for speed. Sources: the files themselves
(headers, imports, disassembly), sampling profiles of the running game, and the frame log of the
DLL in this repository. A conclusion that was not observed directly is marked "assumed".

Addresses are RVAs (offsets from the start of `client.dll` in memory) unless a module is named.
Add the image base `0x62000000` to get the address a disassembler shows.

## The files

| | Rejacked | Revived |
|---|---|---|
| `client.dll` size | 10,924,032 bytes | 11,059,200 bytes |
| PE timestamp | `0x50E8ED23` (2013-01-06) | the same |
| Linker version | 7.10 (Visual C++ .NET 2003) | the same |
| Image base | `0x62000000` | the same |
| DLL characteristics | 0: no ASLR, not NX-compatible | the same |
| Game executable | `matrix.exe` | `mxorev.exe` |

The timestamp is later than the game's shutdown in 2009, so something rewrote the header after
the original build. Assumed: that happened when the import table was edited ([Imports](#imports)).

Sections, the same in both files:

| Section | RVA | Size |
|---|---|---|
| `.text` | `0x001000` | `0x867000` (8.4 MB of code) |
| `.rdata` | `0x868000` | `0x112000` |
| `.data` | `0x97A000` | `0x1AD000` |
| `STLPORT_` | `0xB27000` | `0x1000` |
| `.rsrc` | `0xB28000` | `0x1000` |
| `.reloc` | `0xB29000` | `0x8AE44` |

Revived's file has three more: `.mxrtip` (`0xBB4000`, `0x30000`), `.mxrtv` (`0xBE4000`, `0x4000`)
and `.mxrrsi` (`0xBE8000`, `0x4000`).

`matrix.exe` is a 32-bit program with neither the "large address aware" flag (so it gets 2 GB of
address space) nor the NX-compatible flag. Both matter under Wine ([graphics.md](graphics.md)).

### Rejacked against Revived

The two `client.dll` files are the same build. Where they differ:

| Section | Difference |
|---|---|
| `.text` | 73 bytes at 11 places |
| `.rdata` | 3 places: the cinematics URL, one code pointer, one 256-byte table |
| `.data`, `STLPORT_` | identical |
| `.rsrc` | 12 bytes |
| `.reloc` | 1,923 bytes added at the end |

The 11 code changes in Revived's file:

| Place | Change |
|---|---|
| `0x12C3` | call to `0x29D2A0` goes through new code at `0x706800` first |
| `0x6970D`, `0x25ACCD` | call to `0x25A640` redirected into `.mxrrsi` |
| `0x1704F4` | compare replaced by a call into `.mxrrsi` |
| `0x172E90` | jump into `.mxrrsi` |
| `0x174758` | jump into `.mxrrsi` (inside the routine at `0x1736F0`) |
| `0x1EF347` | call to `0x1EDCB0` redirected into `.mxrtip` |
| `0x24C6AF`, `0x25E8C5` | call to `0x25E080` redirected into `.mxrrsi` |
| `0x706800` | 25 bytes of padding replaced by code |
| `0x813DEA` | one constant argument changed from 1 to 0 |

534 of the 535 routines in `translator/routines.list` are byte-identical in both files. The
exception is `0x1736F0`, because of the jump at `0x174758`.

### Imports

Both files have the same import table:

| DLL | Functions | Notes |
|---|---|---|
| `msvcr71.dll` | 193 | the C runtime of Visual C++ .NET 2003 |
| `kernel32.dll` | 114 | |
| `pythonmxo.dll` | 76 | the Python C API (`Py_InitModule4`, `PyArg_ParseTuple`, …): the client embeds Python |
| `user32.dll` | 37 | |
| `mxowrap.dll` | 16 | the debug-help API (`SymInitialize`, `StackWalk64`, `MiniDumpWriteDump`, …) under another DLL name |
| `binkw32.dll` | 12 | Bink video |
| `gdi32.dll` | 12 | |
| `msacm32.dll` | 9 | |
| `advapi32.dll` | 6 | |
| `wininet.dll` | 5 | |
| `ole32.dll` | 4 | |
| `version.dll` | 3 | |
| `dllmediaplayer.dll` | 2 | `CreateMediaPlayer`, `GetMediaPlayerLastError` |
| `r3d9.dll` | 1 | a Direct3D 9 wrapper, below |
| `dllwebbrowser.dll` | 1 | `CreateBrowser` |
| `dinput8.dll` | 1 | `DirectInput8Create` |
| `winmm.dll` | 1 | `timeGetTime` |
| `rpcrt4.dll`, `shell32.dll` | 1 each | |

Two of these are wrappers between the client and a system DLL:

- **`mxowrap.dll`** exports the 16 functions that normally come from `dbghelp.dll`. It loads with
  the client, before any game code runs. Assumed: it is what changes client code in memory in
  Rejacked ([Routines something else has changed](#routines-something-else-has-changed)).
- **`r3d9.dll`**: `client.dll` does not import `d3d9.dll`. It gets its Direct3D 9 object from
  `r3d9.dll`, so every Direct3D call passes through that wrapper. Its cost is in
  [measurements.md](measurements.md#where-the-main-threads-time-goes).

Math imports from `msvcr71.dll`, by import-table slot:

| Slot | Function | | Slot | Function |
|---|---|---|---|---|
| `0x868258` | `_CIpow` | | `0x86830C` | `floor` |
| `0x86825C` | `_controlfp` | | `0x868358` | `tan` |
| `0x868260` | `_ftol` | | `0x8683FC` | `fmod` |
| `0x868264` | `_CIacos` | | `0x868448` | `atan2` |
| `0x8682A4` | `cos` | | `0x86844C` | `log` |
| `0x8682AC` | `sqrt` | | `0x868450` | `exp` |
| `0x8682E4` | `acos` | | `0x8684E4` | `_CIfmod` |
| `0x8682E8` | `pow` | | `0x868548` | `sin` |
| `0x8682FC` | `ceil` | | | |

The DLL replaces the `sqrt` slot, and the translator computes `floor` and `ceil` in place
([translator.md](translator.md)).

## Floating point

x87 is the old floating-point unit of x86 processors. It computes on a stack of registers, the
FPU stack.

- **All floating point is x87.** Visual C++ .NET 2003 generates x87 code unless told otherwise.
  Vector, matrix, culling, animation and 3D-sound math all run on the FPU stack.
- **The main thread runs at 24-bit precision, round to nearest.** Direct3D 9 sets this when the
  device is created, because the client does not ask it to keep the FPU state. Other threads
  use a different precision. The translated routines rely on this: they run only on the thread
  that owns the device, and other threads run the original code.
- **Float-to-integer casts go through `_ftol2`** at `0x6A92D8`, the compiler's helper, linked
  into `client.dll` and called from 697 places.
- **Cost under Rosetta 2:** about 25 ns per x87 instruction, the same at 24-, 53- and 64-bit
  precision. A routine with 21 x87 instructions takes 540 ns. `msvcr71!sqrt` (x87 `fsqrt` in
  Wine) takes about 514 ns per call.
- **Share of the main thread before any fix**, standing in the world: `client.dll` 82–86%, almost
  all of it x87 routines. The top 25 routines took about 60% of the time. Covering 90% takes
  several hundred.

## Routines we identified

| RVA | What it does | Status |
|---|---|---|
| `0x28E0` | render throttle: adjusts the draw-distance factor | not touched |
| `0x1D90` | where an allocation returned null when the 2 GB address space ran out | not touched |
| `0x6CE1` | main loop: `PeekMessage` once per frame, called through a pointer at `.data` `0x9DDE68` | not touched |
| `0x45E10` | 4×4 matrix multiply | hand-written SSE |
| `0x46510` | quaternion to rotation matrix | hand-written SSE |
| `0x183250` | rotate a vector by a quaternion | translated |
| `0x48A360`, `0x48A470`, `0x48A590` | bounding box against planes (culling) | translated. `0x48A470` takes the most time of all translated routines |
| `0x2F9900`–`0x2FF400` | about a dozen routines that look like skeletal animation | translated |
| `0x47DDB0` | world position to map grid cell, calls `_ftol2` | translated ([its cost](measurements.md#what-each-fix-gave)) |
| `0x4859D0` | comparator handed to a sort | translated, about 1% |
| `0x393E10`, `0x48FA40` | which projector lights reach an object. `0x48FA40` walks the lights and writes an entry with position and colour for each one in range. `0x393E10` is the distance from a point to a box. Called three times from `0x49DA40`, each time only while the setting `WR_Projector_Light_Chars` is on ([In a crowd](#in-a-crowd)) | translated |
| `0x29283D` | calls the DirectSound 3D-buffer setters | not touched |
| `0xDE70`, `0xDEB0`, `0xDEF0`, `0x66EBF0`, `0x66ED40` | double-precision helpers | translated |
| `0x7670`, `0x7690` | thin wrappers around C runtime math imports | not translated |
| `0x6A92D8` | `_ftol2` | SSE, written out by `xlat.py` |

After `0x48A470`, the translated routines with the most time are `0x49DA40` and `0x4DCE10`.
Beyond the light calls of `0x49DA40`, what they do is not known.

Seven routines in the list are reached only through pointers, never by a direct call:
`0x4859D0`, `0x4A5600`, `0x45F780`, `0x4D0D90`, `0x65F960`, `0x2F2730`, `0x3C9A30`.

Left out of the list on purpose:

| RVA | Reason |
|---|---|
| `0x3B9A10` | the single-precision translation differed from the double-precision one |
| `0x14580` | cannot be run in the tests (0.6% of the main thread) |
| `0x4E8F30`, `0x4D7640`, `0x3AF700` and ten smaller ones | translate, but never run to completion on random input, so they are unverified |

`0x2FE4D0` and `0x2FE670` are in the list although they differ from the original in the test
with ordinary input. Both interpolate in a table of keys whose floats start two bytes into a
word. The test's values reach them as arbitrary bit patterns, and an intermediate product exceeds
the range of a `float` (the fast rounding trade-off in [translator.md](translator.md)). On
well-formed tables both match the original over 20,000 calls each.

### Routines something else has changed

The DLL installs a replacement only where the code in memory is exactly the code the replacement
was made from. These fail that check:

| RVA | Rejacked | Revived |
|---|---|---|
| `0x1736F0` | changed in memory before the device is created (the file is unchanged) | the file itself differs (jump at `0x174758`) |
| `0x1B5890` | unchanged, replaced | changed in memory before the device is created |

With the MxOEmu launcher it is as with Rejacked: only `0x1736F0` fails the check.

## The render throttle

The client lowers its draw distance by itself when the frame rate is low. Its settings and
built-in defaults:

| Setting | Default |
|---|---|
| `Client_RenderThrottle_TargetMinFrameRate` | 30 |
| `Client_RenderThrottle_Step` | 0.05 |
| `Client_RenderThrottle_Min` | 0.25 |
| `Client_RenderThrottle_Hysteresis` | 0.3 |
| `Client_RenderThrottle_FramesForChange` | 15 |
| `Client_RenderThrottle_Override` | 0 (automatic) |

The routine at `0x28E0` keeps a factor between 0.25 and 1:

- When the frame rate stays below 30 × factor for 15 frames, the factor drops by 0.05.
- When it stays 30% above that, the factor rises.
- The factor scales the draw distances. On exit the client writes the scaled values back to
  `options.cfg` (`dl_*_prefetchradius`, `wr_*dist`, `*camerafarz`).
- A non-zero `Client_RenderThrottle_Override` holds the factor at that value.

So a slow machine draws less instead of getting much slower. Early measurements read 14–16 fps
before a big improvement and 17–19 fps after, because the throttle spent the gain on draw
distance. With `Client_RenderThrottle_Override = 1` the same scene ran at 8.5 fps before the
math fix.

## How the client uses Direct3D 9

Counts are per frame, in the world at full draw distance, 3440×1440.

| What | Observed |
|---|---|
| Device | created with mixed vertex processing, which gives software vertex shaders 8,192 constant registers |
| Vertex shader constants | 1,000–1,500 updates. Never more than 248 registers set. About a third of the updates repeat values already set |
| Draw calls | 3,600–4,000 on average, 4,000–6,000 in heavy frames |
| Dynamic vertex buffers | about 40 locks without `D3DLOCK_DISCARD` or `D3DLOCK_NOOVERWRITE` |
| Managed textures | uploaded right before first use: about 12 while the world streams in |
| Render passes | about 19, of which about 11 because the game switches render targets |
| Map | about 830 triangle fans through `DrawPrimitiveUP` |
| Shaders | 288 shader modules compiled by DXVK across both games |
| Login screen | fullscreen 800×600 with a display mode switch, then the configured resolution |

What some options cost in frame rate: [measurements.md](measurements.md#settings-that-change-the-numbers).

## The main thread

One thread runs the game logic, makes every Direct3D call and handles window messages. With all
fixes it is the limit: the GPU is idle a third to half of the time. Where its time goes:
[measurements.md](measurements.md#where-the-main-threads-time-goes).

### In a crowd

The numbers are in [measurements.md](measurements.md#in-a-crowd). What they come from:

- **Draw calls.** One frame had 9,012 draw calls: 5,377 for the picture, 1,989 for 77 shadow
  pictures of 512×512 (about 26 each, one per character), and 1,620 for one 256×256 picture at
  the start of the frame (not identified). The game switches between the shadow pictures and the
  main one, which makes 200 to 340 render passes per frame against 60 to 100 elsewhere. Without
  character shadows (`ModelShadow_Enable` and `ModelShadow_Proj_Enable` at 0) the frame rate was
  12 to 13% higher both times. The GPU was 25 to 66% idle in these sessions, so the main thread
  stayed the limit.
- **The light loop.** For each object, `0x49DA40` calls `0x48FA40`, which walks every projector
  light. Per light that runs `0x48FA40` itself, the distance routine `0x393E10`, `0xE130`, and
  twice `0x4B3FE0`, reached through the light's table of functions. `0x4B3FE0` jumps to
  `0x4A98C0`, which only returns one stored value. The loop ran in two sessions and not in the
  two before, minutes apart in the same place. Assumed: the projector lights are on only at
  night. It cost the step from 54 to 37 fps. The light filter
  ([translator.md](translator.md#hand-written-replacements)) is the fix. In the one session that
  counted them, the list had 255 to 635 lights, and the loop asked 40,000 to 160,000 times per
  frame whether a light reaches an object. With the filter 80 to 180 of those reach it.
- **`WR_Projector_Light_Chars`** gates the three calls of the loop. The two sessions with `0` and
  `1` in `useropts.cfg` were taken by day, when the loop did not run either way. Whether that
  line reaches the game is not known.

## Launchers and add-ons

**Rejacked**

- The launcher starts `matrix.exe` from `%TEMP%\MatrixOnline.0`, not from the game folder, so a
  DLL placed next to the game is not found. Overrides have to go into the system folder.
- Settings live in `%APPDATA%\The Matrix Online\`. The game writes `options.cfg`. `useropts.cfg`
  holds a block the launcher rewrites on every PLAY. Where both set a value, `options.cfg` wins.
  Both use Windows line endings.

**MxOEmu**

- Its launcher is the game's own `launcher.exe` (5,267,456 bytes), changed to load `mxowrap.dll`
  (452,096 bytes), a file that project builds. Both are in its full client and in its
  launcher-only archive. Neither comes with a shortcut.
- The game runs as `matrix.exe` here too, with `mxowrap.dll` loaded, so the same overrides
  apply. One session of about a minute in the world, among more than 100 characters: 535 of 536
  routines installed, `0x1736F0` left alone as with Rejacked.
- The main thread in that session: 37% translated math, 32% the client's integer code, 17% Wine
  and system code, 7% this DLL, 6% waiting. That is the same picture as Rejacked
  ([measurements.md](measurements.md#where-the-main-threads-time-goes)).
- Not tested: whether it works alongside Rejacked in one game folder. Rejacked's launcher writes
  its servers into `useropts.cfg` on every PLAY.

**Revived**

- Portable install with its own `options.cfg` in the game folder.
- **`mxrdisp`**: an add-on that sits in front of Direct3D 9 and scales the interface. It checks
  or hooks some client routines. By default the DLL leaves those alone
  (`DXVK_MXO_RESPECT_ADDONS`).
- **Music guard**: the starter checks the music system before the game starts. The check fails
  on Wine's DirectSound even where music works with Microsoft's. It then writes `music = off` to
  `MxORevived-audio.txt` and starts the game without music.
- **Sign-in**: the launcher types the account and password into the game's own login console
  with `ReadProcessMemory`/`WriteProcessMemory`, driven by a timer, at about four characters a
  second. Both processes are mostly idle meanwhile.
- **Background video** in the launcher (`BackgroundVideo` in `launcher-settings.json`) takes more
  than one processor core.
- Wine's own DirectMusic freezes Revived at start. Microsoft's works.

## Settings

| Setting | File | Effect |
|---|---|---|
| `Client_RenderThrottle_Override` | `options.cfg` | 0: automatic draw distance. 1: always full |
| `dl_*_prefetchradius`, `wr_*dist`, `*camerafarz` | `options.cfg` | draw distances, rewritten on exit with the throttled values |
| `EnableSplash = 0` | `useropts.cfg` | skips the logo movies |
| `Windowed` | launcher block in `useropts.cfg` | windowed or fullscreen |
| `MusicSystemEnable` | `options.cfg` | music |
| `wr_wetext_enable` | `options.cfg` | wet streets |
| `WR_Reflect_EnvMap_Enable` | Revived's `autoexec.cfg`, which switches it on | wet-street reflections while it rains |
