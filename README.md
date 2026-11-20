# The Matrix Online on Apple Silicon Macs

Makes The Matrix Online run fast in CrossOver on Apple Silicon Macs, for MxO Rejacked, MxO Revived
and other projects that use the 2009 client.

On the test machine (M4, fullscreen 3440×1440, maximum detail) the game went from about 15 fps
with a shortened draw distance to 55–89 fps at full draw distance.

## What you need

- An Apple Silicon Mac with [CrossOver](https://www.codeweavers.com/crossover) (tested with 26.3).
- A CrossOver bottle with the game installed: [docs/crossover.md](docs/crossover.md), step 1.
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

The first run downloads about 420 MB (Microsoft's DirectX packages, CodeWeavers' CrossOver
source code and a compiler) and uses about 1.1 GB of disk space in the `build` folder.

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

For players:

| | |
|---|---|
| [docs/crossover.md](docs/crossover.md) | setting up the bottle and the game by hand |
| [docs/building.md](docs/building.md) | building and installing by hand, switches, going back |

For developers and the game teams:

| | |
|---|---|
| [docs/how-it-works.md](docs/how-it-works.md) | why the game is slow on Apple Silicon and what the fix is |
| [docs/client-notes.md](docs/client-notes.md) | reverse-engineering notes on the client |
| [docs/translator.md](docs/translator.md) | the x87 to SSE2 translator |
| [docs/graphics.md](docs/graphics.md) | the graphics problems and their fixes |
| [docs/measurements.md](docs/measurements.md) | method, results, open problems |
| [docs/development.md](docs/development.md) | repository layout, diagnostics, profiling |
| [tests/README.md](tests/README.md) | the tests that compare the translated math with the original |

## Licence

zlib: [LICENSE](LICENSE). The patch in `dxvk/` is a modified part of
[DXVK](https://github.com/doitsujin/dxvk), which has the same licence:
[dxvk/LICENSE](dxvk/LICENSE). The Matrix Online belongs to its owners; this repository contains
none of it.
