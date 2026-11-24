# Running The Matrix Online on a Mac with CrossOver

How to get the game running in CrossOver by hand, as done on an Apple Silicon Mac with
CrossOver 26, the MxO Rejacked launcher and the 7.6005 client. `scripts/setup.sh` does all of it
for you ([quick-start.md](quick-start.md)). Making the game fast comes afterwards, in
[building.md](building.md).

Out of the box the game shows an error box about pixel shaders, then a black screen, then a
"Music System Failed to Initialize" error. Section 2 fixes each.

Paths used here:

| Name | Meaning |
|---|---|
| `BOTTLE` | `~/Library/Application Support/CrossOver/Bottles/MatrixOnline` |
| `WINE` | `/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine` |

## 1. Bottle, launcher, game files

A bottle is CrossOver's name for one self-contained Windows setup.

1. In CrossOver, create a new bottle of type **Windows 10 64-bit** and call it `MatrixOnline`.
2. Download the launcher from <https://mxo-rejacked.com/download> and install it into that
   bottle: in CrossOver, choose to install an unlisted application, then pick the installer
   file and the bottle.
3. The launcher does not include the game. Put the client, version 7.6005, in `C:\Games\MxO`,
   which on the Mac is `$BOTTLE/drive_c/Games/MxO`. It is about 6 GB unpacked. The MxOEmu
   project offers it as a 1.3 GB archive at <https://mxoemu.info>.
4. Create an account on the Rejacked site.

Do not start the game yet.

## 2. The fixes the game needs

The game is a 32-bit program, so its files go into `$BOTTLE/drive_c/windows/syswow64`, the
bottle's folder for 32-bit system files. Keep a copy of every file you replace.

### Pixel shader error

Symptom: an error box "D3D Error … CreatePixelShader" as soon as the game starts.

Wine's shader compiler cannot handle the game's shaders. Use Microsoft's, which comes with the
game:

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

Wine's DirectMusic, which plays the game's music, gets stuck in a loop at start-up. Microsoft's
own DirectMusic files fix it. They come from two old Microsoft packages:

| Package | Take from it |
|---|---|
| DirectX End-User Runtimes, February 2010 (`directx_feb2010_redist.exe`), inside it `dxnt.cab` | `dmband.dll`, `dmcompos.dll`, `dmime.dll`, `dmloader.dll`, `dmscript.dll`, `dmstyle.dll`, `dmsynth.dll`, `dmusic.dll`, `dswave.dll`, `dsound.dll` |
| DirectX 9.0c redistributable, April 2006 (`directx_apr2006_redist.exe`), inside it `DirectX.cab` | `gm16.dls`, renamed to `gm.dls` |

Both packages are archives of `.cab` files. `cabextract` (`brew install cabextract`) unpacks
them:

```sh
cabextract -d dx2010 -F dxnt.cab directx_feb2010_redist.exe
cabextract -d dm dx2010/dxnt.cab
cabextract -d dx2006 -F DirectX.cab directx_apr2006_redist.exe
cabextract -d dls -F gm16.dls dx2006/DirectX.cab
```

Copy the ten DLLs into `syswow64`, and the sound bank into both driver folders:

```sh
cd "$BOTTLE/drive_c/windows"
for f in dmband dmcompos dmime dmloader dmscript dmstyle dmsynth dmusic dswave dsound; do
  cp /path/to/dm/$f.dll syswow64/$f.dll
done
mkdir -p syswow64/drivers system32/drivers
cp /path/to/dls/gm16.dls syswow64/drivers/gm.dls
cp /path/to/dls/gm16.dls system32/drivers/gm.dls
```

Then tell Wine to prefer them:

```sh
for f in dmband dmcompos dmime dmloader dmscript dmstyle dmsynth dmusic dswave; do
  "$WINE" --bottle MatrixOnline -- reg add 'HKCU\Software\Wine\DllOverrides' /v $f /d native,builtin /f
done
```

The test machine got these files by hand, and the commands were written down afterwards. The
packages and files are the ones `winetricks` uses for the same job. To check them: `dmime.dll`
is 181,248 bytes, `dsound.dll` 381,952 and `gm.dls` 3,440,660.

### "Music System Failed to Initialize"

Symptom: the game now shows graphics, with an Audio Error box, and there is no music.

Microsoft's DirectMusic needs Microsoft's DirectSound too, but only for the game:

```sh
"$WINE" --bottle MatrixOnline -- reg add 'HKCU\Software\Wine\AppDefaults\matrix.exe\DllOverrides' /v dsound /d native,builtin /f
```

### Crash after about a minute in the world

The game is a 32-bit program without the "large address aware" flag, so it gets 2 GB of memory
and runs out. To give it 4 GB, add this line under `[EnvironmentVariables]` in
`$BOTTLE/cxbottle.conf`:

```
"WINE_LARGE_ADDRESS_AWARE" = "1"
```

## 3. Settings

The game's settings are in `$BOTTLE/drive_c/users/crossover/AppData/Roaming/The Matrix Online/`,
in two files: `options.cfg`, which the game writes itself, and `useropts.cfg`, where the launcher
keeps a block of its own. If both set something, `options.cfg` wins. The files use Windows line
endings.

- **Run in a window on CrossOver's stock graphics.** Fullscreen gives a black screen there.
  Keep the launcher set to windowed (`Windowed = 1` in its block) and do not switch to
  fullscreen in the game's video options. With the DLL from this repository, fullscreen works.
- **Skip the logo movies.** They show black. Add this line to `useropts.cfg`, above the
  launcher's block (the setup's `intro` step sets the same line):

  ```
  EnableSplash = 0
  ```

## 4. Play

Start "Rejacked Launcher" from the bottle in CrossOver, set the game folder to `C:\Games\MxO` in
its settings, sign in and press PLAY.

The game now works but is slow, and quietly cuts its draw distance to make up for it
([numbers](measurements.md#result)). [building.md](building.md) builds and installs the DLL that
fixes that, and [how-it-works.md](how-it-works.md) explains why the game is slow.

## Things that still go wrong

| What you see | What to do |
|---|---|
| The "Trace program: running" text in the character-creation intro disappears after a moment | Nothing. It is cosmetic and unsolved. |
| The game will not start after an external monitor was unplugged or switched to another input while the launcher was open | CrossOver has lost track of the displays. Quit the launcher and shut the bottle down (`"$WINE" --bottle MatrixOnline -- wineboot.exe --end-session --shutdown`), then start again. |
| The draw distance changes by itself | That is the game's render throttle. See [client-notes.md](client-notes.md#the-render-throttle). |
| The game crashes after about a minute in the world | It ran out of address space. Set `WINE_LARGE_ADDRESS_AWARE` as in [section 2](#crash-after-about-a-minute-in-the-world). |
| Low frame rate at high resolution with Rejacked | Untick "Use the new glow shader for 'Screen Filter: Over-Bright' (BETA)" in the Rejacked launcher. It halves the frame rate at 3440×1440. |

## MxO Revived

Revived goes into the same bottle and keeps its own copy of the game in its own folder.

1. **Install it** from <https://mxorevived.com/download.html>. `MxORevived-Installer.exe`
   downloads the game (1.3 GB) into `C:\Games\MxO Revived`. `MxORevived-Setup.exe` makes that
   folder from a game that is already installed.
2. **Install .NET.** The launcher needs the .NET 10 Desktop Runtime (x64), from Microsoft's
   installer:

   ```sh
   "$WINE" --bottle MatrixOnline -- windowsdesktop-runtime-10.0.x-win-x64.exe /install /quiet /norestart
   ```

3. **Turn on Microsoft's DirectSound for it.** The other fixes of section 2 apply to the whole
   bottle, but the DirectSound line is per program:

   ```sh
   "$WINE" --bottle MatrixOnline -- reg add 'HKCU\Software\Wine\AppDefaults\mxorev.exe\DllOverrides' /v dsound /d native,builtin /f
   ```

   Without it, Revived uses Wine's DirectSound and shows the "Music System Failed to
   Initialize" box. Do not try Wine's own DirectMusic instead: Revived froze at start with it.
4. **Turn its music back on.** Revived's starter runs its own music check, which fails on
   Wine's DirectSound. It then switches the music off and writes `music = off` into
   `MxORevived-audio.txt` in the Revived folder. Set that line to `music = on`, and
   `MusicSystemEnable = 1` in Revived's own `options.cfg`. `scripts/setup.sh music` does both.
5. **Optional: stop the launcher's background video,** which kept more than one processor core
   busy on the test machine. With the launcher closed, set `"BackgroundVideo": false` in `launcher-settings.json` in
   the Revived folder.

The DLL from this repository works with Revived. See [building.md](building.md).

## MxOEmu

The MxOEmu project's client needs no installer: its launcher is `C:\Games\MxO\launcher.exe`,
which comes with the game files from <https://mxoemu.info>. Start it with the bottle's Run
Command, or let `scripts/setup.sh game` make a shortcut for it. On the test machine it ran with
the same fixes and the same speed-up as Rejacked.

## A note on safety

A CrossOver bottle is not a sandbox. Windows programs in it run as ordinary Mac programs under
your account, and by default a bottle can see your whole disk through its `Z:` drive, and your
Documents and Downloads folders. Only run launchers you trust, and give each server a password
you use nowhere else.
