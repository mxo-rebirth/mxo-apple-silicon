#!/bin/bash
# The checks that need neither the game nor CrossOver: shell syntax under macOS's bash, the two linters,
# the tests of the setup's Python helpers and the STYLEGUIDE.md rules a script can check. GitHub runs
# the same on every pull request and every push to main. Needs the linters:
#   brew install shellcheck ruff

set -euo pipefail
cd "$(dirname "$0")/.."

old_bash() {   # bash 3.2: the one in /bin on a Mac, the same version in a container elsewhere
  if [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = 3 ]; then
    /bin/bash "$@"
  else
    docker run --rm -v "$PWD:/repo" -w /repo bash:3.2 bash "$@"
  fi
}

scripts=(install.sh scripts/*.sh)

echo "== shell syntax under bash 3.2"
for script in "${scripts[@]}"; do old_bash -n "$script"; done

echo "== shellcheck"
shellcheck "${scripts[@]}"

python_folders=(translator scripts tests/setup)

echo "== ruff"
ruff check --no-cache "${python_folders[@]}"

echo "== Python 3.9 syntax"   # the Python of macOS's developer tools
ruff check --no-cache --select E9 --target-version py39 "${python_folders[@]}"

echo "== the setup's helpers"
python3 -I tests/setup/test_setup_helpers.py

echo "== writing rules, bash 3.2 and step lists"
python3 -I scripts/check-rules.py

echo "all checks passed"
