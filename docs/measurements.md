# Measurements

## Test setup

| | |
|---|---|
| Machine | MacBook with Apple M4, 24 GB, macOS 27.2 |
| Translation layer | CrossOver 26.3 (Wine 11, 32-bit code in a 64-bit process, Rosetta 2) |
| Display | 3440×1440 at 120 Hz external, plus the built-in display |
| Client | Rejacked install, 7.6005. Revived in the same bottle |
| Settings | fullscreen 3440×1440, maximum detail, anti-aliasing on, music on, unless stated |

## How to measure

- **Pin the render throttle, or read it.** The client lowers the draw distance to hold 30 fps
  ([client-notes.md](client-notes.md#the-render-throttle)), so a frame rate means little without
  its draw distance. `Client_RenderThrottle_Override = 1` holds full detail.
- **Frame log.** With `debug.flag` the DLL logs the frame rate, the throttle factor and the draw
  calls every five seconds ([development.md](development.md)). A draw call is one request to the
  GPU to draw something.
- **`scripts/fps-summary.py`** averages the five-second windows of that log with more than 2,500
  draw calls per frame, which leaves out login and loading screens. Every "in the world" figure
  since the single-precision fix comes from it.
- **Compare frame time per draw call, not frame rate.** Scenes differ between sessions.
- **The full profiler distorts.** It pauses every thread every 5 ms, which makes the game's
  memory writes look far slower than they are. The light mode samples only the main thread and
  DXVK's own threads, every 20 ms, and distorts far less.

## Result

Rejacked, in the world:

| | Frame rate | Draw distance |
|---|---|---|
| Stock CrossOver, windowed | 14–16 fps | cut by the throttle, amount unknown |
| Stock DXVK fixed, original math, windowed 1280×720 | 8.5 fps | full (pinned) |
| Current build, fullscreen 3440×1440 | 55–89 fps, 74 on average | full |

- Loading area, windowed 800×600: 8–18 fps on stock CrossOver, 85–89 fps with the DLL.
- Stock CrossOver has no fullscreen number: fullscreen shows a black screen there.
- The first translated build reached 23–29 fps where the original math gave 8.5 fps, but the
  game drew an 800×600 view while the external monitor was being reconfigured. The two do not
  compare.

Revived, last measured after the single-precision fix: 42–65 fps, 58 on average. Before the fixes it ran at 1–4 fps
in the world on DXVK.

## What each fix gave

Each row adds one fix to the ones above it. Fullscreen 3440×1440, sessions of one to two
minutes.

While the GPU was the limit (busy 93–100% of the time), with the draw distance on automatic:

| Fix | In the world |
|---|---|
| translated math | 17–25 fps at 60–90% draw distance |
| buffer lock fix, 12 more routines translated | 22–25 fps at 70–80% |
| texture upload fix | about 23 fps at 100% |
| vertex shader constants, faster rounding | 44–64 fps. No stall entering the world (was 50 s at 3–8 fps) |
| freed memory kept | Revived 46–53 fps (was 1–4) |
| triangle fans, no mid-frame submits | Revived 60–66 fps. Map 10 to 30 fps. GPU about 45% idle |

From here the game's main thread is the limit. Rejacked, read with `scripts/fps-summary.py`:

| Fix | In the world | Draw calls per frame | Frame time per 1,000 draw calls |
|---|---|---|---|
| single precision in 527 routines | 42–74 fps, 59 on average | 3,600 | 4.7 ms |
| map grid lookup translated, llvm-mingw compiler | 48–88 fps, 63 on average | 4,000 | 4.0 ms |
| `sqrt` replacement | 54–82 fps, 69 on average | 3,700 | 3.9 ms |
| compare branches, `floor` and `ceil` in place, float returns in `xmm0` | 60–87 fps, 73 on average | 3,600 | 3.8 ms |
| floats compared as floats | 55–89 fps, 74 on average | 3,600 | 3.8 ms |

Opening the map cost 15–20 fps before the map grid lookup was translated: that one routine,
`0x47DDB0`, took 18% of the main thread with the map open. Now it costs about 5 fps.

## Where the main thread's time goes

Rejacked, in the world. The "Now" column was sampled every 20 ms:

| | Before any fix | Now |
|---|---|---|
| x87 math in `client.dll` | 80–90% | |
| Translated and hand-written math | | about 39% |
| The client's integer code | | about 34% |
| Wine and system code | | 16–21% |
| Direct3D 9 layer | 1–2% | about 6% |

Steps on the way:

- The math share fell from 46.5% to 40.7% with the compare branches, `floor` and `ceil` in place and float returns in `xmm0`.
- The DLL's share fell from 12% to 6% with the switch to the llvm-mingw compiler.

What is left in "Wine and system code":

| Cost | Share | Why it stays |
|---|---|---|
| `PeekMessage`, once per frame | 2–6% | the cost is Wine's macOS event handling, which the DLL cannot reach |
| Copy of vertex shader constants, about 5.8 MB per frame | 2.7% | a third of the updates are redundant, but only 9% of the uploads could be skipped: about 0.25% to gain |
| `r3d9.dll` | 2.7% | the client's own Direct3D wrapper |
| DirectSound 3D-buffer setters | 2.3% | |

## Settings that change the numbers

| Setting | Effect at 3440×1440 |
|---|---|
| Rejacked launcher, "new glow shader for Screen Filter: Over-Bright (BETA)" (it rewrites `rezmap.ltb`) | halves the frame rate (18–29 fps instead of 36–52) |
| Wet-street reflections while it rains, which Revived switches on ([settings](client-notes.md#settings)) | Revived: 45–55 fps down to about 30 |
| Revived's `mxrdisp` interface scaling | about 40% of the GPU |
| `DXVK_MXO_RESPECT_ADDONS` at its default, with Revived's add-on files next to the game | about 10 fps less than with `0`. Seen by the player comparing two bottles, not taken from a frame log |
| Anti-aliasing | a few fps |
| The green tint | nothing measurable |

## In a crowd

Among more than 100 characters with the MxOEmu launcher, maximum detail, 3440×1440. Each crowd
row is the steady part of one session of one to three minutes, read from the frame log. The
frame log and the light profiler ran in all crowd sessions, so these frame rates are lower than
in play and compare only with each other. The light loop's share is from the same session's
profile ([what the loop is](client-notes.md#in-a-crowd)).

| | Draw calls per frame | Frame rate | Light loop's share of the main thread |
|---|---|---|---|
| The usual scene (no profiler) | 3,600 | 74 fps | |
| Crowd by day, character shadows on | 9,300 | 48 fps | 0% |
| Crowd by day, character shadows off | 7,750 | 54 fps | 0% |
| The same crowd minutes later, the light loop running, shadows on | 9,650 | 33 fps | 27% |
| The same, shadows off | 8,100 | 37 fps | 31% |
| A later session with the light loop running, shadows on | 10,200 | 30 fps | 28 to 31% |
| The next session, with the light filter | 9,700 to 9,950 | 42 fps | under 1%, the filter 1 to 3% |
| Seven minutes with the filter, the 67 windows before the lights came on | 8,370 | 45.7 fps | 0% |
| The same session, the 15 windows with the lights on | 8,470 | 46.2 fps | 0%, the filter 1 to 2% |

- In the 42 fps session, the one five-second window with more draw calls than the row before it
  (10,500) ran at 38 fps.
- The last two rows are one session in one place, before and after the lights came on. With the
  filter, the lights coming on no longer shows in the frame rate.
- Not measured: the same place with and without the filter in one session, and any of this
  without the profiler.

## Open problems

- **Single slow frames.** Mostly frames with 4,000–6,000 draw calls. Also a few pauses of some
  hundred milliseconds while signing in or loading, and one 0.6-second pause in the world with
  no graphics activity at all, so from the game itself.
- **Pipeline builds.** A new combination of shader and render state costs one hitch of about
  0.2 seconds, once. After that it is cached on disk.
- **Revived with music** was slow in several early sessions and fast in others, with the same
  files and settings. The stalls when the Mac is short of memory
  ([graphics.md, problem 5](graphics.md#5-one-second-stalls-when-the-mac-is-short-of-memory))
  fit that pattern, and keeping memory locked made Rejacked's stalls disappear. Revived with
  music has not been measured since.
- **Revived's sign-in takes 4–5 seconds of typing** with the processor idle. Its launcher sets
  the pace.
- **The 800×600 login screen** sometimes comes up without a display mode switch. The picture is
  scaled to fit. Mouse coordinates in that state are unverified.
- **One unexplained freeze** at the loading screen with an early build. It has not recurred.
- **Thirteen routines** translate but cannot be verified by the tests, so they stay original
  ([client-notes.md](client-notes.md#routines-we-identified)).
- **Not tested:** long sessions, interiors, other districts, any other Mac.
