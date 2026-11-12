#!/usr/bin/env bash
#
# check_app_paths.sh <app bundle or file>...
#
# Fails when a packaged app still holds a path or name of the machine that
# built it: a path in the macOS users folder (where home directories live),
# the path of this checkout, or the login name of the person running the
# check. Every file in the bundle is searched byte for byte, so this covers
# strings compiled into the executable as well as the debug map that
# `strip -S` removes.
#
# tools/package_app.sh runs it on every app it makes. Run it again on a
# signed copy before publishing it.
#
# Exit status: 0 nothing found; 1 something found (listed); 2 usage error.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <app bundle or file>..." >&2
  exit 2
fi
for target in "$@"; do
  if [ ! -e "$target" ]; then
    echo "check_app_paths: $target does not exist" >&2
    exit 2
  fi
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The folder that holds home directories on macOS.
USERS_FOLDER="/Users"

needles=("$USERS_FOLDER/" "$ROOT_DIR/")
if [ -n "${HOME:-}" ] && [ "$HOME" != "/" ]; then
  needles+=("${HOME%/}/")
fi
# A short login name also turns up inside ordinary words and binary data, so
# it is searched for on its own only from five characters up; shorter names
# are still caught through the home-directory path.
login="$(id -un 2>/dev/null || true)"
if [ "${#login}" -ge 5 ]; then
  needles+=("$login")
fi

grep_args=()
for needle in "${needles[@]}"; do
  grep_args+=(-e "$needle")
done

set +e
hits="$(LC_ALL=C grep -r -a -l -F "${grep_args[@]}" -- "$@")"
status=$?
set -e
if [ "$status" -gt 1 ]; then
  echo "check_app_paths: the search did not run cleanly" >&2
  exit 2
fi
if [ -z "$hits" ]; then
  echo "check_app_paths: no build-machine paths or names in $*"
  exit 0
fi

echo "FAIL: build-machine paths or names in the packaged app (do not publish it):" >&2
while IFS= read -r file; do
  # The printable runs of the file that hold a match (strings(1) skips the
  # symbol table, where the debug map lives).
  LC_ALL=C tr -c '[:print:]' '\n' < "$file" | LC_ALL=C grep -F "${grep_args[@]}" \
    > "${TMPDIR:-/tmp}/check_app_paths.$$" || true
  echo "  $file: $(wc -l < "${TMPDIR:-/tmp}/check_app_paths.$$" | tr -d ' ') match(es), for example" >&2
  sort -u "${TMPDIR:-/tmp}/check_app_paths.$$" | head -5 | cut -c1-200 | sed -e 's/^/      /' >&2
  rm -f "${TMPDIR:-/tmp}/check_app_paths.$$"
done <<< "$hits"
exit 1
