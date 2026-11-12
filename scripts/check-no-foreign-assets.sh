#!/usr/bin/env bash
#
# check-no-foreign-assets.sh
#
# Keeps other software's files out of Refab Artist: application and plug-in
# bundles, executables and dynamic libraries, interface files, icon files,
# installers and help documents. AGENTS.md "What stays out of the repo"
# states the rule; this script checks it by file type and path.
#
# Usage:
#   scripts/check-no-foreign-assets.sh --staged   # scan staged files only (pre-commit)
#   scripts/check-no-foreign-assets.sh --all      # scan every tracked file
#
# There is no CI. The opt-in pre-commit hook (.githooks/pre-commit) runs
# --staged; the maintainer runs --all before merging outside contributions.
#
# Exits 0 if clean, 1 with a list of offending paths if not, 2 on a usage
# error.
#
# Runs on macOS and Linux with bash and POSIX tools; no GNU-only flags.

set -u

MODE=""
if [ "$#" -ge 1 ]; then
  MODE="$1"
fi

if [ "$#" -ne 1 ] || { [ "$MODE" != "--staged" ] && [ "$MODE" != "--all" ]; }; then
  echo "usage: $0 --staged | --all" >&2
  exit 2
fi

# Resolve repo root so the script works from any cwd.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "error: not inside a git working tree" >&2
  exit 2
fi
cd "$REPO_ROOT" || exit 2

# Paths this project owns that would otherwise match a blocked type, one per
# line. Keep this list short and reviewed.
#   app/RefabArtist/Packaging/AppIcon.icns: the app's own icon, drawn from
#   geometry by tools/icon/make_app_icon.py (no outside art).
ALLOWED_PATHS='app/RefabArtist/Packaging/AppIcon.icns'

FILES_TMP="$(mktemp -t refabartist-asset-check.XXXXXX)"
LOWER_TMP="$(mktemp -t refabartist-asset-lower.XXXXXX)"
VIOLATIONS_TMP="$(mktemp -t refabartist-asset-violations.XXXXXX)"
trap 'rm -f "$FILES_TMP" "$LOWER_TMP" "$VIOLATIONS_TMP"' EXIT
: > "$VIOLATIONS_TMP"

# NUL-separated so unusual file names arrive unquoted.
if [ "$MODE" = "--staged" ]; then
  # Only Added/Copied/Modified/Renamed staged paths. Skip Deleted.
  git diff --cached --name-only -z --diff-filter=ACMR > "$FILES_TMP"
else
  git ls-files -z > "$FILES_TMP"
fi
# Lowercased once for the case-insensitive path checks.
tr 'A-Z' 'a-z' < "$FILES_TMP" > "$LOWER_TMP"

record_violation() {
  # $1 = path, $2 = reason
  printf '  %s\n    reason: %s\n' "$1" "$2" >> "$VIOLATIONS_TMP"
}

is_allowed() {
  [ -n "$ALLOWED_PATHS" ] && printf '%s\n' "$ALLOWED_PATHS" | grep -Fxq -- "$1"
}

# First eight bytes of the file as it will be committed, as lowercase hex.
# --staged reads the index so a later working-tree edit cannot hide a staged
# binary; --all reads the working tree.
leading_hex() {
  if [ "$MODE" = "--staged" ]; then
    git cat-file blob ":$1" 2>/dev/null | head -c 8 | od -An -tx1 | tr -d ' \n'
  elif [ -f "$1" ]; then
    head -c 8 -- "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n'
  fi
}

# Checks against the path, case-insensitively ($2 is the lowercased path).
# Returns 0 after recording the first reason found, 1 if the path is fine.
check_path() {
  path="$1"
  lower_path="$2"
  lower_base="${lower_path##*/}"

  # Anything inside an application, framework, plug-in or help bundle, or
  # laid out like the inside of one.
  case "/$lower_path" in
    *.app/*|*.framework/*|*.bundle/*|*.plugin/*|*.appex/*|*.xpc/*|*.kext/*|*.help/*)
      record_violation "$path" "file inside an application, framework, plug-in or help bundle"
      return 0
      ;;
    */contents/macos/*|*/contents/frameworks/*|*/contents/resources/*|*/contents/plugins/*)
      record_violation "$path" "file laid out like the inside of an application bundle"
      return 0
      ;;
  esac

  case "$lower_base" in
    *.nib|*.xib|*.storyboard|*.storyboardc)
      record_violation "$path" "interface file (.nib/.xib/.storyboard)"
      return 0
      ;;
    *.icns|*.car)
      record_violation "$path" "icon or compiled asset catalog (.icns/.car)"
      return 0
      ;;
    *.dylib|*.so|*.so.*)
      record_violation "$path" "dynamic library"
      return 0
      ;;
    *.dmg|*.pkg|*.mpkg|*.xip|*.msi|*.exe)
      record_violation "$path" "installer, disk image or executable"
      return 0
      ;;
    *.chm|*.hlp|*.helpindex)
      record_violation "$path" "help file"
      return 0
      ;;
    *help*.pdf|*manual*.pdf|*userguide*.pdf|*user-guide*.pdf|*user_guide*.pdf)
      record_violation "$path" "help document (PDF)"
      return 0
      ;;
  esac
  return 1
}

# Checks against the file's leading bytes: Mach-O executables, libraries and
# object files (thin and universal), and ELF binaries. Static archives
# (`!<arch>`) are not matched, so vendored .a libraries pass.
check_content() {
  path="$1"
  hex="$(leading_hex "$path")"
  case "$hex" in
    feedface*|feedfacf*|cefaedfe*|cffaedfe*)
      record_violation "$path" "Mach-O binary"
      ;;
    cafebabe00000001*|cafebabe00000002*|cafebabe00000003*|cafebabe00000004*|cafebabf*)
      record_violation "$path" "universal (fat) Mach-O binary"
      ;;
    7f454c46*)
      record_violation "$path" "ELF binary"
      ;;
  esac
}

while IFS= read -r -d '' path <&3 && IFS= read -r -d '' lower_path <&4; do
  [ -z "$path" ] && continue
  is_allowed "$path" && continue
  check_path "$path" "$lower_path" && continue
  check_content "$path"
done 3< "$FILES_TMP" 4< "$LOWER_TMP"

if [ -s "$VIOLATIONS_TMP" ]; then
  echo "check-no-foreign-assets: FAIL" >&2
  echo "" >&2
  echo "These paths are other software's files or binaries:" >&2
  echo "" >&2
  cat "$VIOLATIONS_TMP" >&2
  echo "" >&2
  echo "App bundles, binaries, interface files, icons, installers and help" >&2
  echo "documents from other software never belong in this repository." >&2
  echo "See AGENTS.md \"What stays out of the repo\"." >&2
  exit 1
fi

echo "check-no-foreign-assets: OK"
exit 0
