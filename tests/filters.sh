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
# A pattern is read verbatim, so a quote becomes part of it. The quote can sit
# anywhere in the rule, not only right after the sign: a check that looked at
# one position passed a file with "- *.bak'" appended.
rules_are_unquoted() {
    ! grep -qE "^[[:space:]]*[+-][[:space:]]+.*['\"]" "$1"
}

title "the file itself"
# Checked directly as well as functionally, because a pattern that happens to
# match nothing either way would slip through otherwise.
if rules_are_unquoted "$FILTERS"; then
    ok "no rule is quoted"
else
    bad "these rules are quoted, and rclone will treat the quote as part of the pattern"
    grep -nE "^[[:space:]]*[+-][[:space:]]+.*['\"]" "$FILTERS" || true
fi
check "the rules do not include a whitespace-only line" \
    grep -qvE '^[[:space:]]*$' "$FILTERS"

# The check itself has to fail on a quoted rule, or it proves nothing. Both
# positions are exercised: at the end of the pattern and in the middle of it.
QUOTED="$WORK/filters.quoted"
cp "$FILTERS" "$QUOTED"
printf -- "- *.bak'\n" >> "$QUOTED"
if rules_are_unquoted "$QUOTED"; then
    bad "the quote check missed a rule with a quote at the end"
else
    ok "the quote check catches a trailing quote"
fi
printf -- "- mid\"dle.tmp\n" >> "$QUOTED"
if rules_are_unquoted "$QUOTED"; then
    bad "the quote check missed a double quote mid-pattern"
else
    ok "the quote check catches a quote inside a rule"
fi

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

# ---------------------------------------------------------------- the checker
# bin/onedrive-check is the pre-flight that says which names the filters did not
# catch. These are the regressions an adversarial pass found in it: a trailing
# slash on LOCAL used to suppress every "too long" report, and --max used to
# reach the arithmetic with whatever it was handed.
title "onedrive-check"
CHECKER="$SRC_DIR/bin/onedrive-check"
CHK_CFG="$WORK/checkcfg/rclone-onedrive-tray"
CHK_TREE="$WORK/checktree"
mkdir -p "$CHK_CFG" "$CHK_TREE"
: > "$CHK_TREE/plain.md"

# A 400-character remote path puts every entry past the measured 380 limit, so
# the trailing slash on LOCAL is the only thing that can hide the report.
CHK_REMOTE="onedrive:$(printf 'r%.0s' $(seq 1 400))"
printf 'LOCAL="%s/"\nREMOTE="%s"\n' "$CHK_TREE" "$CHK_REMOTE" > "$CHK_CFG/config"
run "a trailing slash on LOCAL still reports over-long paths" 1 "too long" \
    env XDG_CONFIG_HOME="$WORK/checkcfg" "$CHECKER"
printf 'LOCAL="%s"\nREMOTE="%s"\n' "$CHK_TREE" "$CHK_REMOTE" > "$CHK_CFG/config"
run "the same LOCAL without the slash gives the same verdict" 1 "too long" \
    env XDG_CONFIG_HOME="$WORK/checkcfg" "$CHECKER"

# --max is a positive integer or a usage error, and a usage error is one line.
printf 'LOCAL="%s"\nREMOTE="onedrive:Vault"\n' "$CHK_TREE" > "$CHK_CFG/config"
run "--max refuses a non-number" 2 "positive integer" \
    env XDG_CONFIG_HOME="$WORK/checkcfg" "$CHECKER" --max abc
run "--max refuses a negative number" 2 "positive integer" \
    env XDG_CONFIG_HOME="$WORK/checkcfg" "$CHECKER" --max -3

# The reserved-name list is the stem before the first dot, not the whole name.
: > "$CHK_TREE/CON.txt"
run "CON.txt is refused like CON" 1 "reserved name: CON.txt" \
    env XDG_CONFIG_HOME="$WORK/checkcfg" "$CHECKER"
rm -f "$CHK_TREE/CON.txt"
: > "$CHK_TREE/a:b.md"
run "a renamed name does not fail the check" 0 "will rename these" \
    env XDG_CONFIG_HOME="$WORK/checkcfg" "$CHECKER"

summary
