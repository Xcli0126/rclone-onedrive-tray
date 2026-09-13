#!/usr/bin/env bash
#
# filters.sh: the shipped filter rules have to actually filter.
#
# This file exists because of a real bug. Every pattern in config/filters.example
# was wrapped in single quotes, on the reasonable but wrong assumption that a
# shell would read the file. rclone reads it itself, so '- *.tmp' was a pattern
# beginning with an apostrophe and the rules for temp files, swap files and
# __pycache__ matched nothing at all. Nothing about the file looks wrong to a
# reader; only running rclone over a fixture tree catches it.
#
#   tests/filters.sh              run everything
#   tests/filters.sh --verbose    also show the listing
#
# Needs rclone, and nothing else. Nothing here touches a remote.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SRC_DIR/tests/lib/harness.sh" "$@"

FILTERS="$SRC_DIR/config/filters.example"

command -v rclone >/dev/null 2>&1 || {
    echo "rclone is not installed; nothing to check against" >&2
    exit 2
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "default filters, against rclone $(rclone version | head -1 | awk '{print $2}')"

# ---------------------------------------------------------------- the shape
title "the file itself"
# A pattern is read verbatim, so a quote becomes part of it. Checked directly as
# well as functionally, because a pattern that happens to match nothing either
# way would slip through otherwise.
if grep -nE "^[[:space:]]*[+-][[:space:]]+['\"]" "$FILTERS"; then
    bad "these rules are quoted, and rclone will treat the quote as part of the pattern"
else
    ok "no rule is quoted"
fi
check "the rules do not include a whitespace-only line" \
    grep -qvE '^[[:space:]]*$' "$FILTERS"

# ---------------------------------------------------------------- the fixture
title "a tree full of things that should not sync"
SRC="$WORK/src"
mkdir -p "$SRC"/{.rag,__pycache__,.obsidian,notes} "$SRC/.Trash-1000"

# One file per rule, plus files that merely look like they should be caught.
: > "$SRC/.DS_Store"
: > "$SRC/Thumbs.db"
: > "$SRC/desktop.ini"
: > "$SRC/.lock"
: > "$SRC/~\$draft.docx"
: > "$SRC/.rag/index.bin"
: > "$SRC/__pycache__/module.pyc"
: > "$SRC/.obsidian/workspace.json"
: > "$SRC/notes/draft.tmp"
: > "$SRC/notes/backup~"
: > "$SRC/notes/.notes.md.swp"
: > "$SRC/notes/download.partial"
: > "$SRC/.Trash-1000/deleted.txt"

# These have to survive: the anchored rules are anchored, and none of the
# patterns is meant to be so broad that it eats real files.
: > "$SRC/notes/plain.md"
: > "$SRC/notes/not-tmp.txt"
: > "$SRC/.obsidian/app.json"
: > "$SRC/notes/keep.py"

LISTING="$(rclone lsf "$SRC" --filter-from "$FILTERS" --recursive 2>&1 | sort)"
[ "$VERBOSE" = 1 ] && printf '%s\n' "$LISTING" | sed 's/^/        | /'

excluded() {
    if grep -qxF "$1" <<<"$LISTING"; then
        bad "$1 synced, but a default rule should have stopped it"
    else
        ok "$1 is filtered out"
    fi
}
kept() {
    if grep -qxF "$1" <<<"$LISTING"; then
        ok "$1 still syncs"
    else
        bad "$1 was filtered out, and it is a real file"
    fi
}

title "excluded"
excluded .DS_Store
excluded Thumbs.db
excluded desktop.ini
excluded .lock
excluded "~\$draft.docx"
excluded .rag/index.bin
excluded __pycache__/module.pyc
excluded .obsidian/workspace.json
excluded notes/draft.tmp
excluded 'notes/backup~'
excluded notes/.notes.md.swp
excluded notes/download.partial
excluded .Trash-1000/deleted.txt

title "kept"
kept notes/plain.md
kept notes/not-tmp.txt
kept .obsidian/app.json
kept notes/keep.py

summary
