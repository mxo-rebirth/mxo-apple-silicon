# Style Guide

How code and docs are written in this repo. Shell scripts for the bash that macOS ships, Python 3 with the standard library only, and one C++ patch on the DXVK in CodeWeavers' source.

## Core Principles

- **Names explain the code**: a reader can tell what a function or a variable is for from its name
- **One job each**: a function, a script or a setup step does one thing
- **One home for each thing**: every address, constant and rule is written once. Other code reads it from there.
- **Measure first**: a speed claim comes from a profile or a frame log, never from a guess. [measurements.md](docs/measurements.md) says how each number was taken.
- **Nothing from the game in the repo**: routines are recognised by hash and translated on the player's Mac. Anything made from `client.dll` stays in `build/`.

## Layout

The table of files is in [docs/development.md](docs/development.md#layout). A new file gets a row there in the same change.

## Naming

- `lower_snake` for shell and Python functions and for local variables, `UPPER_CASE` for constants and for shell variables that several functions share
- A one-letter name only for a loop counter or a value used within the next few lines
- A yes-or-no function reads like one: `has_rejacked`, `needs_build`, `game_running`, `intro_off`
- A size says its unit: `DXVK_KEEP_EMPTY_CHUNKS_MB`
- A function that hands back more than a line of text says where: `choose` sets `CHOICE`, `wrap` sets `WRAPPED`

## Shell

- The scripts run on `/bin/bash` 3.2. No associative arrays, no `mapfile`, no `${name,,}`.
- `set -euo pipefail` at the top. A command that may fail says so with a test or `|| true`.
- Every expansion is quoted
- A function is at most 80 lines and does not nest deeper than it needs to
- Deleting uses `${name:?}`, so an empty variable can never widen what is removed
- Programs are found by name with `ps -o comm=`. Their command lines are never read or printed.
- The setup never reads passwords, launcher logins or credential stores, and keeps every file it replaces with a `.setup-backup` suffix
- Colours, frames and animation appear only on a terminal. Piped, every message is a plain line that still makes sense alone.
- Every question has a default, and `--yes` takes it. A default never replaces settings a player already has. Where the game comes from is the one question `--yes` skips: a 1.3 GB download is not started unasked.
- A file in the bottle is written next to the old one and renamed, so it is there whole or not at all
- A temporary folder is entered in `LEFTOVERS` when it is made. The exit trap removes it however the setup ends.
- A message names a step as its command: `scripts/setup.sh NAME`

## Python

- Standard library only, and no network
- The scripts start Python with `python3 -I`, so nothing from the folder or the environment is loaded
- The code runs on Python 3.9, the one in macOS's developer tools
- Python lives in files of its own, never in a here-document of a shell script, where no linter sees it

## The DXVK Patch

- All changes to DXVK are in one patch file. `scripts/build.sh` applies it to a fresh copy of CodeWeavers' source.
- Code in the patch follows the style of the DXVK code around it
- A fix can be switched off with an environment variable and has a row in the [switch table](docs/building.md#switches). [graphics.md](docs/graphics.md) names the few that cannot.
- A switch is read through `env::isFixEnabled`, `env::getEnvSwitch` or `env::getEnvSizeMB`, which also log a value that is not the default or not understood
- `translator/mxo_x87_apply.h` and its copy in the patch are one file. The build stops if they differ.
- A routine is replaced only when its bytes in memory match the bytes it was translated from

## Checking Input

- An installer is started only after its checksum matches the one its publisher prints
- Links are read from the publishers' pages and must be `https`. A file name is checked against a pattern before use.
- A page that no longer looks as expected stops that step with a message. The setup never falls back to a guess.
- The game archive has no published checksum. The setup says where it comes from.

## Tests and Checks

```sh
scripts/check.sh    # shell syntax under bash 3.2, shellcheck, ruff, the helpers' tests, the writing rules
```

- `scripts/check.sh` needs neither the game nor CrossOver. GitHub runs it on every push and pull request (`.github/workflows/check.yml`).
- The translation is tested against the original code, bit for bit: [tests/README.md](tests/README.md). Those tests need the game and run under Wine.
- A change to the translator is compared with its output before the change, over the whole routine list. A differing line has to be meant.
- A change to the setup is run in a scratch bottle first (`CX_BOTTLE_PATH` points CrossOver at another folder), once on a terminal and once piped
- A change to the look is looked at in a real terminal, dark and light, wide and narrow
- There are no warnings, only errors. A rule is changed in `.shellcheckrc` or `ruff.toml`, never with a comment that switches a check off.

## Comments and Docs

- A comment explains **why**, not what the code does. One line if possible.
- No history in comments: no dates, versions or "changed this" notes
- If a comment no longer matches the code, fix or delete it in the same change
- No semicolons in comments, in docs or in the messages the scripts print
- The README is for players and stays short. What developers and the game teams need is in `docs/`.
- What was not tested is said so, next to the claim
- No logo or title art of the game or the films, and no character names, in the repo or in what the setup prints
- People's names and accounts never appear. The repository's own address is the one exception: the installer and the README need it.

## Commits

- Conventional Commits, written as commands: `feat: add …`, `fix: mark …`, `perf(translator): compare …`
- Pull request titles use the same format, typed by what the PR is mainly about. The description follows `.github/pull_request_template.md`.
- One commit per real step. Small follow-up fixes are merged into that commit before pushing.
- No names of users, accounts or other projects
- `scripts/check.sh` passes before every commit

## Things That Have Bitten Us

- **An apostrophe inside `"${name:+text}"` ends a bash 3.2 script with a parse error.** Build the text in a statement of its own.
- **A variable directly before a non-ASCII character needs braces** in bash 3.2: `${RULE}─`
- **`tput cols` inside `$( )` asks the pipe.** `stty size < /dev/tty` asks the terminal.
- **CrossOver's bottle view follows `cxmenu.conf`.** The plist under `desktopdata` can be out of date.
- **A bottle made with `cxbottle` has MSync off and shows no icons** unless the three `--param` values of `create_bottle` are passed
- **Add-on files next to the game cost speed.** The DLL leaves alone every routine an `mx*.dll` points into, unless `DXVK_MXO_RESPECT_ADDONS=0`.
- **The profiler changes what it measures.** Frame rates are judged with it off.

## Known Gaps

- `scripts/build.sh` and the last part of `scripts/setup.sh` run outside functions
- `translator/xlat.py` has functions far over 80 lines
- The setup's shell has no tests in the repo. Its Python helpers have (`tests/setup/`).
- No test covers the two hand-written matrix routines of the DLL
