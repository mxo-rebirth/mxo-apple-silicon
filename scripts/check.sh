#!/bin/bash
# The checks that need neither the game nor CrossOver: shell syntax under the bash macOS ships, the
# two linters, and the rules of STYLEGUIDE.md that a script can check. GitHub runs the same on every
# push and pull request. Needs the linters:  brew install shellcheck ruff

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

echo "== ruff"
ruff check --no-cache translator scripts

echo "== Python 3.9 syntax"   # the Python of macOS's developer tools
ruff check --no-cache --select E9 --target-version py39 translator scripts

echo "== writing rules and step lists"
python3 -I scripts/check-rules.py

echo "all checks passed"
