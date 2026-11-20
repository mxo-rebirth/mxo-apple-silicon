# Measurements

## Test setup

| | |
|---|---|
| Machine | MacBook with Apple M4, 24 GB, macOS 27.2 |
| Translation layer | CrossOver 26.3 (Wine 11, 32-bit code in a 64-bit process, Rosetta 2) |
| Display | 3440×1440 at 120 Hz external, plus the built-in display |
| Client | Rejacked install, 7.6005; Revived in the same bottle |
| Settings | fullscreen 3440×1440, maximum detail, anti-aliasing on, music on, unless stated |

## How to measure

- **Pin the render throttle or read it.** The client cuts draw distance to hold 30 fps
  ([client-notes.md](client-notes.md#the-render-throttle)), so a frame rate means little without
  the draw distance that went with it. `Client_RenderThrottle_Override = 1` holds full detail.
- **Frame log.** With `debug.flag` the DLL logs frame rate, throttle factor and draw calls every
  five seconds ([development.md](development.md)).
- **`scripts/fps-summary.py`** averages the windows of that log with more than 2,500 draw calls
  per frame, which leaves out login and loading screens. All "in the world" figures from v26 on
  come from it.
- **Compare frame time per draw call, not frame rate.** Scenes differ between sessions.
- **The full profiler distorts.** It pauses every thread every 5 ms, which made memory writes in
  the game look extremely slow and sent us after a problem that existed only while profiling.
  The light mode samples the main thread every 20 ms and distorts far less.

## Result

Rejacked, in the world:

| | Frame rate | Draw distance |
|---|---|---|
| Stock CrossOver, windowed | 14–16 fps | cut by the throttle, amount unknown |
| Stock DXVK fixed, original math, windowed 1280×720 | 8.5 fps | full (pinned) |
| Current build, fullscreen 3440×1440 | 55–89 fps, 74 on average | full |

Loading area, windowed 800×600: 8–18 fps on stock CrossOver, 85–89 fps with the DLL.

We have no fullscreen number for stock CrossOver: fullscreen shows a black screen there.

Revived was last measured with v26: 42–65 fps, 58 on average. Before the fixes it ran at 1–4 fps
in the world on DXVK.

## By build

Fullscreen 3440×1440, throttle on automatic, sessions of one to two minutes:

| Build | Change | In the world |
|---|---|---|
| first builds | translated math | 17–25 fps at 60–90% draw distance |
| | buffer lock fix, 12 routines the first build lacked | 22–25 fps at 70–80% |
| | texture upload fix | about 23 fps at 100% |
| v8 | vertex shader constants, faster rounding | 44–64 fps; no stall entering the world (was 50 s at 3–8 fps) |
| v11 | freed memory kept | Revived 46–53 fps (was 1–4) |
| v24 | triangle fans, mid-frame submits | Revived 60–66 fps; map 10 to 30 fps; GPU about 45% idle |

From v8 to v24 the GPU was the limit (busy 93–100% of the time); since v24 the main thread is.

Rejacked from v26 on, from `scripts/fps-summary.py`:

| Build | Change | In the world | Draw calls per frame | Frame time per 1,000 draw calls |
|---|---|---|---|---|
| v26 | single precision in 527 routines | 42–74 fps, 59 on average | 3,600 | 4.7 ms |
| v28 | map grid lookup translated, llvm-mingw build | 48–88 fps, 63 on average | 4,000 | 4.0 ms |
| v30 | `sqrt` replacement | 54–82 fps, 69 on average | 3,700 | 3.9 ms |
| v33 | compare branches, `floor` and `ceil` in place, float returns in `xmm0` | 60–87 fps, 73 on average | 3,600 | 3.8 ms |
| v36 | floats compared as floats | 55–89 fps, 74 on average | 3,600 | 3.8 ms |

Opening the map costs about 5 fps since v27. It was 15–20: one routine, `0x47DDB0`, took 18% of
the main thread with the map open.

A caveat on the early numbers: the 8.5 fps figure has a counterpart of 23–29 fps for the first
translated build, but that was taken while the external monitor was being reconfigured and the
game drew an 800×600 view, so the pair is not a fair comparison.

## Where the main thread's time goes

Rejacked, in the world:

| | Before any fix | v36 |
|---|---|---|
| x87 math in `client.dll` | 80–90% | |
| Translated and hand-written math | | about 39% |
| The client's integer code | | about 34% |
| Wine and system code | | 16–21% |
| Direct3D 9 layer | 1–2% | about 6% |

Steps on the way: the math share fell from 46.5% to 40.7% between v30 and v33, and the DLL's
share from 12% to 6% with the compiler switch in v28.

What is left in "Wine and system code":

| Cost | Share | Why it stays |
|---|---|---|
| `PeekMessage`, once per frame | 2–6% | Wine's macOS event handling; not reachable from the DLL |
| Copy of vertex shader constants | 2.7% | a third of the updates are redundant, but only 9% of the uploads could be skipped: about 0.25% to gain |
| `r3d9.dll` | 2.7% | the client's own Direct3D wrapper |
| DirectSound 3D-buffer setters | 2.3% | |

## Settings that change the numbers

| Setting | Effect at 3440×1440 |
|---|---|
| Rejacked launcher, "new glow shader for Screen Filter: Over-Bright (BETA)" | halves the frame rate (18–29 fps instead of 36–52) |
| Wet-street reflections in rain (Revived) | 45–55 fps down to about 30 |
| Anti-aliasing | a few fps |
| The green tint | nothing measurable |

## Open problems

- **Single slow frames.** Mostly frames with 4,000–6,000 draw calls, a few pauses of some
  hundred milliseconds while signing in or loading, and one 0.6-second pause in the world with
  no graphics activity at all, so from the game itself.
- **Pipeline builds.** A new combination of shader and render state costs one hitch of about
  0.2 seconds, once; it is cached on disk afterwards.
- **Revived with music** was slow in several early sessions and fast in others, with the same
  files and settings. The memory-pressure stalls ([graphics.md](graphics.md), problem 5) fit
  that pattern, and with memory kept locked Rejacked's stalls disappeared. Revived with music
  has not been measured since.
- **Revived's sign-in takes 4–5 seconds of typing** with the processor idle. The pace is set by
  its launcher.
- **The 800×600 login screen** sometimes comes up without a display mode switch. The picture is
  scaled to fit; mouse coordinates in that state are unverified.
- **One unexplained freeze** at the loading screen with an early build. It has not recurred.
- **Thirteen routines** translate but cannot be verified by the tests, so they stay original
  ([client-notes.md](client-notes.md#routines-we-identified)).
- **Not tested:** long sessions, combat, interiors, other districts, any other Mac.
