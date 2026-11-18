# Running The Matrix Online on a Mac with CrossOver

This is how the test machine was set up: an Apple Silicon Mac, CrossOver 26, the MxO Rejacked
launcher and the 7.6005 client. It covers getting the game to start at all. Making it fast is
the next step, in [BUILD.md](BUILD.md).

Out of the box the game does not work in CrossOver: you get an error box about pixel shaders,
then a black screen, then a "Music System Failed to Initialize" error. Each has a specific fix,
listed below.

Paths used here:

| Name | Meaning |
|---|---|
| `BOTTLE` | `~/Library/Application Support/CrossOver/Bottles/MatrixOnline` |
| `WINE` | `/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine` |

## 1. Bottle, launcher, game files

1. In CrossOver, create a new bottle of type **Windows 10 64-bit** and call it `MatrixOnline`.
2. Download the launcher from <https://mxo-rejacked.com/download> and install it into that
   bottle (in CrossOver, choose to install an unlisted application, then pick the installer
   file and the bottle).
3. Get the game client, version 7.6005, the way the Rejacked download page describes, and
   unpack it to `C:\Games\MxO`, which on the Mac is `$BOTTLE/drive_c/Games/MxO`. It is about
   6 GB unpacked.
4. Create an account on the Rejacked site.

Do not start the game yet.

## 2. The three fixes that make it start

All files go into `$BOTTLE/drive_c/windows/syswow64` (the 32-bit system folder; the game is a
32-bit program). Keep a copy of every file you replace.

### Pixel shader error

Symptom: an error box "D3D Error … CreatePixelShader" as soon as the game starts.

Wine's own shader compiler DLL cannot handle what the game gives it. The game ships a real one:

```sh
cd "$BOTTLE/drive_c/windows/syswow64"
cp d3dcompiler_43.dll d3dcompiler_43.dll.crossover-builtin.bak
cp "$BOTTLE/drive_c/Games/MxO/D3DCompiler_43.dll" d3dcompiler_43.dll
"$WINE" --bottle MatrixOnline -- reg add 'HKCU\Software\Wine\DllOverrides' /v d3dcompiler_43 /d native,builtin /f
```

Putting the DLL next to the game does not work, because the launcher starts the game from a
temporary folder.

### Black screen with the processor at 100%

Symptom: after the pixel shader fix the window stays black and one processor core is fully
busy.

The game uses DirectMusic. Wine's version of it gets stuck in a loop on something the game
asks for during start-up. Microsoft's own DirectMusic files fix it. They come from two old
Microsoft packages:

| Package | Take from it |
|---|---|
| DirectX End-User Runtimes, February 2010 (`directx_feb2010_redist.exe`), inside it `dxnt.cab` | `dmband.dll`, `dmcompos.dll`, `dmime.dll`, `dmloader.dll`, `dmscript.dll`, `dmstyle.dll`, `dmsynth.dll`, `dmusic.dll`, `dswave.dll`, `dsound.dll` |
| DirectX 9.0c redistributable, April 2006 (`directx_apr2006_redist.exe`), inside it `DirectX.cab` | `gm16.dls`, to be renamed `gm.dls` |

Both packages are archives of `.cab` files; `cabextract` (`brew install cabextract`) unpacks
them:

```sh
cabextract -d dx2010 -F dxnt.cab directx_feb2010_redist.exe
cabextract -d dm dx2010/dxnt.cab
cabextract -d dx2006 -F DirectX.cab directx_apr2006_redist.exe
cabextract -d dls -F gm16.dls dx2006/DirectX.cab
```

Then copy the ten DLLs into `syswow64`, and the sound bank into both driver folders:

```sh
cd "$BOTTLE/drive_c/windows"
for f in dmband dmcompos dmime dmloader dmscript dmstyle dmsynth dmusic dswave dsound; do
  cp /path/to/dm/$f.dll syswow64/$f.dll
done
mkdir -p syswow64/drivers system32/drivers
cp /path/to/dls/gm16.dls syswow64/drivers/gm.dls
cp /path/to/dls/gm16.dls system32/drivers/gm.dls
```

and tell Wine to prefer them:

```sh
for f in dmband dmcompos dmime dmloader dmscript dmstyle dmsynth dmusic dswave; do
  "$WINE" --bottle MatrixOnline -- reg add 'HKCU\Software\Wine\DllOverrides' /v $f /d native,builtin /f
done
```

On the test machine these files were copied by hand, and the commands above were written down
afterwards; the package and file names are the ones `winetricks` uses for the same job. For
checking: `dmime.dll` is 181,248 bytes, `dsound.dll` 381,952 and `gm.dls` 3,440,660.

### "Music System Failed to Initialize"

Symptom: the game now shows graphics, with an Audio Error box, and there is no music.

Microsoft's DirectMusic needs Microsoft's DirectSound to go with it, but only for the game:

```sh
"$WINE" --bottle MatrixOnline -- reg add 'HKCU\Software\Wine\AppDefaults\matrix.exe\DllOverrides' /v dsound /d native,builtin /f
```

## 3. Settings

The game's settings are in
`$BOTTLE/drive_c/users/crossover/AppData/Roaming/The Matrix Online/`. Two files matter:
`options.cfg`, which the game writes itself, and `useropts.cfg`, where the launcher keeps a
block of its own. If both set something, `options.cfg` wins. The files use Windows line
endings.

- **Run in a window on CrossOver's stock graphics.** Fullscreen gives a black screen there.
  Keep the launcher set to windowed (`Windowed = 1` in its block) and do not switch to
  fullscreen in the game's video options. With the DLL from this repository installed,
  fullscreen works.
- **Skip the logo movies.** They show black. Add this line to `useropts.cfg`, above the
  launcher's block:

  ```
  EnableSplash = 0
  ```

## 4. Play

Start "Rejacked Launcher" from the bottle in CrossOver, set the game folder to `C:\Games\MxO` in
its settings, sign in and press PLAY.

At this point the game works but is slow: 8–18 fps in the loading area and around 15 fps in the
world, with the game quietly cutting the draw distance. [BUILD.md](BUILD.md) describes how to
build and install the DLL that fixes that, and [README.md](README.md) explains why it is slow.

## Things that still go wrong

| What you see | What to do |
|---|---|
| The "Trace program: running" text in the character-creation intro disappears after a moment | Nothing; it is cosmetic and unsolved. |
| "Jack out" seems to do nothing | The game counts down a few seconds while you stand still. Otherwise close the window. |
| The game will not start after an external monitor was unplugged or switched to another input while the launcher was open | CrossOver has lost track of the displays. Quit the launcher and shut the bottle down (`"$WINE" --bottle MatrixOnline -- wineboot.exe --end-session --shutdown`), then start again. |
| Draw distance changes by itself | That is the game's render throttle; see the README. |
| The game crashes after about a minute in the world | It ran out of address space. Add `"WINE_LARGE_ADDRESS_AWARE" = "1"` under `[EnvironmentVariables]` in `$BOTTLE/cxbottle.conf`. |
| Low frame rate at high resolution with Rejacked | Untick "Use the new glow shader for 'Screen Filter: Over-Bright' (BETA)" in the Rejacked launcher; it halves the frame rate at 3440×1440. |

## MxO Revived

Revived was installed into the same bottle. Its launcher needs the .NET 10 Desktop Runtime
(x64), installed in the bottle with Microsoft's installer:

```sh
"$WINE" --bottle MatrixOnline -- windowsdesktop-runtime-10.0.x-win-x64.exe /install /quiet /norestart
```

Revived keeps its own copy of the game in its own folder. The first two fixes above apply to
the whole bottle, so it gets them too. For music it needs the DirectSound line as well, with
its own executable name:

```sh
"$WINE" --bottle MatrixOnline -- reg add 'HKCU\Software\Wine\AppDefaults\mxorev.exe\DllOverrides' /v dsound /d native,builtin /f
```

Revived's starter also has a music guard: if its own check of the music system fails (it does
when the check runs on Wine's DirectSound), it switches the game's music off and writes
`music = off` into `MxORevived-audio.txt` in the Revived folder. Set that line to `music = on`,
and `MusicSystemEnable = 1` in Revived's own `options.cfg`.

Without the line above, Wine's DirectSound is used and Revived shows the "Music System Failed
to Initialize" box. Do not try Wine's own DirectMusic instead: Revived froze at start with it.

The DLL from this repository works with Revived; see BUILD.md.

## A note on safety

A CrossOver bottle is not a sandbox. Windows programs in it run as ordinary Mac programs under
your account, and by default a bottle can see your whole disk through its `Z:` drive and your
Documents and Downloads folders. Only run launchers you trust, and use a password for each
server that you use nowhere else.
