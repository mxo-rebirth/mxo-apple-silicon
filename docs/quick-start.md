# Quick start

From a Mac without CrossOver to the game, without the details. Those are in
[crossover.md](crossover.md) and [building.md](building.md).

1. **Install [CrossOver](https://www.codeweavers.com/crossover)** and open it once.
2. **Install [Homebrew](https://brew.sh)** with the command on its page, in an administrator
   account. If you will play under a standard account, also run this there now, because a
   standard account cannot install with Homebrew:

   ```sh
   brew install mingw-w64 meson ninja glslang
   ```

3. **Paste this into Terminal:**

   ```sh
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mxo-rebirth/mxo-apple-silicon/main/install.sh)"
   ```

4. **Answer its questions.** Return takes the default each time: a new bottle called
   `MatrixOnline`, the game (a 1.3 GB download), the launchers of all three servers, a limit of
   90 fps, the graphics settings for your Mac and the fastest setting for add-ons. Answer `n` to a launcher you
   do not want.
5. **Revived only: click through the two installers that open,** Microsoft's .NET and then
   Revived's. When Revived's asks where The Matrix Online is installed, choose `C:\Games\MxO`.
   Keep the folder it offers for Revived itself, and do not start the game from there.
6. **Wait for "Done".** The build takes 5 to 10 minutes.
7. **Make an account** with the server you want to play on: [MxO Rejacked](https://mxo-rejacked.com),
   [MxO Revived](https://mxorevived.com) or [MxOEmu](https://mxoemu.info).
8. **Play.** In CrossOver, open the bottle `MatrixOnline`, start the launcher, sign in and press
   Play. If the Rejacked launcher asks for the game folder, choose `C:\Games\MxO`.

Ctrl+Shift+F in the game shows the frame rate.

| | |
|---|---|
| Something goes wrong | [crossover.md](crossover.md#things-that-still-go-wrong) |
| Change an answer later | Paste the command again |
| Undo | The command with `uninstall` at the end |
