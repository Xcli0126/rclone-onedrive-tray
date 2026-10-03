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
# The property is that no line is made only of blanks. An empty line is not one of
# those, and the shipped file has five of them on purpose, so the expression asks
# for one or more whitespace characters. The previous form,
# `grep -qvE '^[[:space:]]*$'`, exits 0 as soon as ANY line is not blank, which is
# true of every file with a rule in it, so it could not fail.
check "no line is made only of blanks" \
    bash -c '! grep -qE "^[[:space:]]+$" "$1"' _ "$FILTERS"
# And the same expression has to notice one, or the check above proves nothing.
BLANKS_PROBE="$WORK/blanks-probe"
cp "$FILTERS" "$BLANKS_PROBE"
printf '   \t \n' >> "$BLANKS_PROBE"
check "and a line of blanks would be caught" \
    grep -qE '^[[:space:]]+$' "$BLANKS_PROBE"

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
CHK_REMOTE="onedrive:$(printf 'r%.0s' {1..400})"
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

# A directory whose name the service will rewrite covers everything inside it, so
# it is one entry rather than one per file: 501 lines for one fix is a report
# nobody reads, and the docs promise one entry per offending subtree.
mkdir -p "$CHK_TREE/renamed:dir"
: > "$CHK_TREE/renamed:dir/one.md"
: > "$CHK_TREE/renamed:dir/two.md"
: > "$CHK_TREE/renamed:dir/three.md"
CHK_OUT="$(env XDG_CONFIG_HOME="$WORK/checkcfg" "$CHECKER" 2>&1)"; CHK_RC=$?
check "a renamed directory is one entry, not one per file under it" \
    grep -qF "OneDrive will rename these (1)" <<<"$CHK_OUT"
if grep -q "renamed:dir/one.md" <<<"$CHK_OUT"; then
    bad "the files inside a renamed directory were listed again"
else
    ok "and the files inside it are not listed again"
fi
rm -rf "$CHK_TREE/renamed:dir"

: > "$CHK_TREE/a:b.md"
run "a renamed name does not fail the check" 0 "will rename these" \
    env XDG_CONFIG_HOME="$WORK/checkcfg" "$CHECKER"

# docs/TROUBLESHOOTING.md promises six groups of names OneDrive rewrites, and only
# the illegal-character one was exercised: the other five arms of the checker could
# each be deleted with every suite still green. One name per group, through the real
# checker, so a group that stops being reported is a failure.
title "the rename groups the docs promise"
rename_case() {  # rename_case <the name> <the phrase the report must use>
    local name="$1" phrase="$2" out
    : > "$CHK_TREE/$name"
    out="$(env XDG_CONFIG_HOME="$WORK/checkcfg" "$CHECKER" 2>&1)"
    if grep -qF "$phrase" <<<"$out"; then
        ok "the checker reports: $phrase"
    else
        bad "the checker did not report: $phrase"
    fi
    rm -f "$CHK_TREE/$name"
}
rename_case $'~tilde.md' 'leading tilde'
rename_case ' leadspace.md' 'space at the start or end'
rename_case 'trailspace.md ' 'space at the start or end'
rename_case 'trailperiod.' 'period at the end'
rename_case $'del\x7fname' 'DEL (0x7f)'
rename_case $'ctrl\x01name' 'control character'
rename_case $'bad\xffname' 'not valid UTF-8'

# One name that is both renamed and over-long is two problems behind one path,
# so the closing line has to give both numbers. While it printed only the group
# headings' idea of a count, a reader could add the headings up and get 3 for a
# tree holding 2 things to look at. The over-long one is a deep directory rather
# than a long file name: this filesystem stops at 255 bytes and 255 is the legal
# maximum, so the total path length is the only way to reach that group at all.
# The colon is what makes the same path a rename as well.
CHK_DEEP="$CHK_TREE"
for _ in 1 2 3 4 5 6; do
    CHK_DEEP="$CHK_DEEP/$(printf 'd%.0s' $(seq 1 55))"
done
mkdir -p "$CHK_DEEP"
CHK_LONG="$CHK_DEEP/$(printf 'd%.0s' {1..54}):$(printf 'x%.0s' {1..40})"
mkdir "$CHK_LONG"
CHK_OUT="$(env XDG_CONFIG_HOME="$WORK/checkcfg" "$CHECKER" 2>&1)"; CHK_RC=$?
check "a name that is renamed and over-long still exits 1" \
    test "$CHK_RC" -eq 1
check "a name that is renamed and over-long is counted as renamed" \
    grep -qF "OneDrive will rename these (2)" <<<"$CHK_OUT"
check "the same name is also counted as over-long" \
    grep -qF "These paths are too long (1)" <<<"$CHK_OUT"
check "the closing line gives paths and problems separately" \
    grep -qxF -- "  2 paths to look at (3 problems). Limits and measurements: docs/TROUBLESHOOTING.md" <<<"$CHK_OUT"

# One of each, because the same sentence has to read as English when both numbers
# are 1. The renamed file from above is the one that stays.
rm -rf "${CHK_DEEP:?}"
CHK_OUT="$(env XDG_CONFIG_HOME="$WORK/checkcfg" "$CHECKER" 2>&1)"; CHK_RC=$?
check "a single renamed name still exits 0" test "$CHK_RC" -eq 0
check "the closing line says 1 path and 1 problem, not 1 paths" \
    grep -qxF -- "  1 path to look at (1 problem). Limits and measurements: docs/TROUBLESHOOTING.md" <<<"$CHK_OUT"

# The name limit is 255 characters, and the check used -ge, so a name of exactly
# that length was reported as over-long: a legal name failed the check. Only
# 256 and up are over it.
CHK_MAX="$(printf 'm%.0s' $(seq 1 255))"
: > "$CHK_TREE/$CHK_MAX"
CHK_OUT="$(env XDG_CONFIG_HOME="$WORK/checkcfg" "$CHECKER" 2>&1)"; CHK_RC=$?
check "a name of exactly 255 characters is within the limit" \
    test "$CHK_RC" -eq 0
if grep -q "name is 255 chars" <<<"$CHK_OUT"; then
    bad "a 255-character name was reported as over-long"
else
    ok "and it is not in the too-long group"
fi
rm -f "$CHK_TREE/$CHK_MAX"

summary
