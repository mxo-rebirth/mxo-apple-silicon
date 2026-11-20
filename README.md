# The Matrix Online on Apple Silicon Macs

Makes The Matrix Online run fast in CrossOver on Apple Silicon Macs, for MxO Rejacked, MxO Revived
and other projects that use the 2009 client.

On the test machine (M4, fullscreen 3440×1440, maximum detail) the game went from about 15 fps
with a shortened draw distance to 55–89 fps at full draw distance.

## What you need

- An Apple Silicon Mac with [CrossOver](https://www.codeweavers.com/crossover) (tested with 26.3).
- A CrossOver bottle with the game installed: [CROSSOVER.md](CROSSOVER.md), step 1.
- The build tools, once: `brew install mingw-w64 meson ninja glslang`

## Set up

Close the game and its launcher, download this repository, and run:

```sh
cd mxo-apple-silicon
scripts/setup.sh
```

It asks which bottle to use and then goes through four steps, asking before each:

| Step | What it does |
|---|---|
| Start fixes | Installs what the game needs to start at all: the game's own shader compiler, Microsoft's DirectMusic and DirectSound, the music sound bank, and a larger memory limit for the game. |
| Build | Builds the speed-up (`d3d9.dll`) on your Mac from your own copy of the game. Takes a few minutes. |
| Install | Installs it for every MxO game it found in the bottle, and lets the games share their pipeline caches so they stutter less. Everything else in the bottle keeps CrossOver's normal graphics. |
| Music | Revived only: switches music back on if Revived's starter turned it off. |

The first run downloads about 300 MB: Microsoft's DirectX packages and CodeWeavers' CrossOver
source code.

Then start the game from its launcher as usual.

## Tips

- **Ctrl+Shift+F** in the game shows or hides the frame-rate counter (if you chose it during
  setup). It starts hidden.
- **Rejacked:** untick "Use the new glow shader for 'Screen Filter: Over-Bright' (BETA)" in the
  launcher. It halves the frame rate at high resolutions.
- **Close memory-hungry apps** before playing. When the Mac is short of memory, the game can
  stutter.

## Undo

```sh
scripts/setup.sh --bottle YourBottleName uninstall
```

The game goes back to CrossOver's normal graphics. Every file the setup replaced was kept with
a `.setup-backup` suffix.

## Good to know

- **Experimental.** It has been played by one person on one Mac, in short sessions.
- **Built on your Mac, from your game.** Nothing from the game is in this repository. Do not
  share the built `d3d9.dll`: it contains code translated from your game files.
- **It changes the game's code in memory** (math routines only, nothing network-related).
  Check that your server allows it.
- **Intel Macs and Windows PCs** gain nothing from the math part.

## More

| | |
|---|---|
| [HOW-IT-WORKS.md](HOW-IT-WORKS.md) | why the game is slow on Apple Silicon, what was fixed, measurements, open problems |
| [CROSSOVER.md](CROSSOVER.md) | setting up the bottle and the game by hand |
| [BUILD.md](BUILD.md) | building and installing by hand, all switches, diagnostics |
| [tests/README.md](tests/README.md) | the tests that compare the translated math with the original |

Licence: zlib, like DXVK, which this is built on; see `LICENSE` and HOW-IT-WORKS.md.
