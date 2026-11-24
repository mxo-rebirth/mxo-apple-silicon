# The Matrix Online on Apple Silicon Macs

> [!WARNING]
> Experimental. Recommended for advanced users.

Makes The Matrix Online run fast in CrossOver on Apple Silicon Macs. It supports MxO Rejacked,
MxO Revived and MxOEmu.

On the test machine (M4, 3440×1440, maximum detail) the game went from about 15 fps to 55–89 fps.

![The game in a window on a Mac desktop, the frame-rate counter at the top left showing 63 fps](docs/screenshot.png)

MxO Revived at 63 fps, in a window on a 3440×1440 screen.

## What you need

- An Apple Silicon Mac with macOS 26 or newer
- [CrossOver](https://www.codeweavers.com/crossover)
- [Homebrew](https://brew.sh)

Tested on one Mac (M4) with macOS 27 and CrossOver 26.3. The setup can download the game itself.

## Set up

The command below downloads this repository and runs a script from it on your Mac. The script
changes files in the CrossOver bottle you choose and keeps a copy of every file it replaces.
Read [install.sh](install.sh) and [scripts/setup.sh](scripts/setup.sh) first if you want to
know what they do. You run it at your own risk.

Close the game and its launcher and paste this into Terminal:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mxo-rebirth/mxo-apple-silicon/main/install.sh)"
```

It clones this repository to `~/mxo-apple-silicon` and runs `scripts/setup.sh` there. Run it
again to update.

Everything can also be done by hand, without the script:
[docs/crossover.md](docs/crossover.md) sets up the bottle and the game, and
[docs/building.md](docs/building.md#build) builds and installs the speed-up.

![The setup in a Terminal window: its opening words, the frame of the server stats site, the system check, its advice on a separate account and a new bottle being made](docs/setup.png)

The setup asks a few questions and then does the rest:

| Step | What it does |
|---|---|
| Game | Gets the game and the launchers, if the bottle has none |
| Start fixes | What the game needs to start |
| Build | Builds the speed-up from your copy of the game |
| Install | Installs it for every MxO game in the bottle |
| Detail | On request: maximum graphics |
| Intro | On request: no logo movies |
| Icons | Launcher icons in CrossOver |
| Revived | Music on, launcher video off |

The first run downloads about 420 MB and uses about 1.1 GB of disk space. The game adds a 1.3 GB
download, about 6 GB unpacked. Every step is described in [docs/building.md](docs/building.md).

Then start the game from its launcher as usual.

## Tips

- **Ctrl+Shift+F** in the game shows or hides the frame-rate counter.
- **Change something later:** run the same command again. It updates itself and asks its
  questions again, with what the bottle has as the defaults.
- **Another launcher later:** the same command with `game` at the end.
- **Fan noise:** the setup offers a limit of 90 fps. For another one, put `--fps 120 install` at
  the end of the command.
- **Rejacked:** untick "Use the new glow shader for 'Screen Filter: Over-Bright' (BETA)" in the
  launcher. It halves the frame rate at high resolutions. If the launcher asks for the game
  folder, choose `C:\Games\MxO`.
- **Stutter:** close memory-hungry apps before playing.
- **Who is online:** <https://whoisjackedin.com>

## Undo

```sh
~/mxo-apple-silicon/scripts/setup.sh uninstall
```

The game goes back to CrossOver's normal graphics. Every file the setup replaced was kept with
a `.setup-backup` suffix.

## Good to know

- **Use it at your own risk.** See the [licence](LICENSE).
- **Our advice, not a requirement: play under a separate macOS account.** Programs in CrossOver
  can reach every file of the account they run in. If you do, install the build tools from the
  account that has Homebrew first: `brew install mingw-w64 meson ninja glslang`
- **Built on your Mac, from your game.** No game file is in this repository. Do not share the
  built `d3d9.dll`.
- **It changes the game's math code in memory.** Check that your server allows it.

## More

| | |
|---|---|
| [docs/crossover.md](docs/crossover.md) | setting up by hand |
| [docs/building.md](docs/building.md) | every setup step, building by hand, switches |
| [docs/how-it-works.md](docs/how-it-works.md) | why the game is slow on Apple Silicon and what the fix is |
| [docs/client-notes.md](docs/client-notes.md) | notes on the client |
| [docs/translator.md](docs/translator.md) | the x87 to SSE2 translator |
| [docs/graphics.md](docs/graphics.md) | the graphics problems and their fixes |
| [docs/measurements.md](docs/measurements.md) | method and results |
| [docs/development.md](docs/development.md) | layout, diagnostics, profiling |
| [tests/README.md](tests/README.md) | the tests |

## Licence

The code is zlib licensed, see [LICENSE](LICENSE). The patch in `dxvk/` is a modified part of
[DXVK](https://github.com/doitsujin/dxvk) (zlib), see [dxvk/LICENSE](dxvk/LICENSE). This
repository contains no game files, and the screenshot shows the game.

The Matrix Online is a trademark of Warner Bros. Entertainment Inc. CrossOver is a trademark of
CodeWeavers, Inc. This fan project is not affiliated with or endorsed by Warner Bros.,
CodeWeavers or any of the server teams.
