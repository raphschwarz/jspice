#!/usr/bin/env bash
# Prints the section of macos/CHANGELOG.md for one version (its heading left out), as the notes of its release:
#   release-notes.sh 1.1.0     (a leading "v" is allowed)
#   release-notes.sh Unreleased
# Fails, printing nothing, when the changelog has no such section or it is empty.
set -euo pipefail
if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 <version>|Unreleased" >&2
  exit 2
fi
VERSION="${1#v}"
CHANGELOG="$(dirname "$0")/../CHANGELOG.md"
# a heading "## 1.1.0", "## [1.1.0]" or either followed by " - date"; the section runs to the next "## " heading, and
# loses its blank lines at either end
NOTES=$(awk -v version="$VERSION" '
  /^## / {
    heading = substr($0, 4)
    sub(/^\[/, "", heading)
    sub(/\]/, "", heading)
    split(heading, words)
    # (compared as strings: as numbers 1 and 1.0 would be equal)
    inside = ((words[1] "") == (version ""))
    next
  }
  inside {
    lines[++count] = $0
    if ($0 ~ /[^ \t]/) { if (!first) first = count; last = count }
  }
  END { if (first) for (i = first; i <= last; i++) print lines[i] }
' "$CHANGELOG")
if [ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]; then
  echo "release-notes.sh: CHANGELOG.md has no notes for $VERSION" >&2
  exit 1
fi
printf '%s\n' "$NOTES"
