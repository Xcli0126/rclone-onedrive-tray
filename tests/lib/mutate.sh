#!/usr/bin/env bash
#
# mutate.sh: which of the shipped behaviours would the suites actually notice?
#
#   tests/lib/mutate.sh              every row
#   tests/lib/mutate.sh <id>...      named rows only
#   tests/lib/mutate.sh --self-test  check the verdict classifier on its own
#   RESULTS=mutations.txt tests/lib/mutate.sh     also write the table to a file
#
# Each row of mutations.txt describes one small, deliberate change to a shipped
# script: a rule removed, a comparison flipped, a default changed, a flag
# dropped. The harness copies the tree, applies that one change with sed, runs
# the named suite against the copy, and records whether the suite failed. A
# change no suite notices is a hole in the suite, not a curiosity: this is how a
# branch in onedrive-check that no filesystem can reach, and one assertion of the
# tray suite's delete scenario that could not fail, were found.
#
# Not part of CI: it takes ten minutes, and it answers a question rather than
# guarding a door. It is not named tests/*.sh on purpose, so the documentation
# check does not count it as a sixth suite.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TABLE="$HERE/mutations.txt"
WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

[ -f "$TABLE" ] || { echo "no $TABLE" >&2; exit 1; }
wanted=("$@")

note() {
    printf '%s\n' "$*"
    [ -n "${RESULTS:-}" ] && printf '%s\n' "$*" >> "$RESULTS"
}

# classify <a suite's closing line> -> caught | survived | unresolved
#
# The count is read as a number. Matching the text "0 failed" called a suite that
# reported "20 failed" a survivor, so one row here read caught at 18 failures and
# SURVIVED at 20, which is the one answer this script exists to get right. A line
# with no count at all is a suite that died before printing its summary, and that
# is unresolved rather than a catch.
classify() {
    local failed_count
    failed_count="$(printf '%s\n' "$1" |
        grep -oE '[0-9]+ failed' | tail -1 | grep -oE '^[0-9]+' || true)"
    if [ -z "$failed_count" ]; then
        printf 'unresolved'
    elif [ "$failed_count" -eq 0 ]; then
        printf 'survived'
    else
        printf 'caught'
    fi
}

# --self-test: the classifier decides every row's verdict, so it is checked
# against lines it has to read correctly before any suite is run. It is the only
# part of this script with an answer that can be wrong on its own.
if [ "${1:-}" = "--self-test" ]; then
    bad=0
    while IFS='|' read -r line want; do
        [ -n "$line" ] || continue
        got="$(classify "$line")"
        if [ "$got" != "$want" ]; then
            printf 'self-test: %-44s want %s, got %s\n' "$line" "$want" "$got" >&2
            bad=1
        fi
    done <<'ROWS'
221 passed, 20 failed, 0 skipped|caught
240 passed, 10 failed, 0 skipped|caught
238 passed, 3 failed, 0 skipped|caught
37 passed, 0 failed, 0 skipped|survived
0 passed, 0 failed, 12 skipped|survived
the suite printed no summary at all|unresolved
ROWS
    if [ "$bad" -eq 0 ]; then
        echo "self-test: the classifier reads all six lines correctly"
    fi
    exit "$bad"
fi

[ -n "${RESULTS:-}" ] && : > "$RESULTS"

# A row whose change no suite can notice, and that no suite can notice because the
# branch is unreachable on this machine rather than because the suites are thin.
# `check-name-limit` sets the checker's name limit to 99999, and a local filesystem
# refuses a name past 255 bytes before that limit is consulted, so the row survives
# by construction and is written down in docs/KNOWN-ISSUES.md as the one branch
# without a case. Without this list the harness could never exit 0, and every full
# sweep would be red for a reason that is already recorded.
KNOWN_SURVIVORS=" check-name-limit "
survived=0
known=0

# An id in the list above that names no row would excuse nothing and hide the typo
# that made it name nothing, so each one has to be a row in the table.
for known_id in $KNOWN_SURVIVORS; do
    grep -q "^${known_id}	" "$TABLE" || {
        echo "KNOWN_SURVIVORS names $known_id, which is not a row in $TABLE" >&2
        exit 1
    }
done
caught=0
skipped=0
unresolved=0

while IFS=$'\t' read -r id target expr suite; do
    case "$id" in ''|'#'*) continue ;; esac
    if [ "${#wanted[@]}" -gt 0 ]; then
        hit=0
        for w in "${wanted[@]}"; do [ "$w" = "$id" ] && hit=1; done
        [ "$hit" = 1 ] || continue
    fi

    rm -rf "${WORK:?}/tree"
    mkdir -p "$WORK/tree"
    tar -C "$REPO" --exclude=.git -cf - . | tar -C "$WORK/tree" -xf -

    before="$(md5sum < "$WORK/tree/$target")"
    sed -i "$expr" "$WORK/tree/$target" 2>/dev/null
    after="$(md5sum < "$WORK/tree/$target")"
    if [ "$before" = "$after" ]; then
        note "$(printf '%-34s SKIPPED  the expression matched nothing' "$id")"
        skipped=$((skipped + 1))
        continue
    fi

    out="$(cd "$WORK/tree" && timeout 900 bash "tests/$suite.sh" 2>&1 | tail -1 |
        sed -e 's/\x1b\[[0-9;]*m//g')"
    # A row counts as caught only when the suite really reported failures. A
    # suite that died before printing its summary lands here as unresolved, not
    # as a catch: otherwise a broken harness reads as a strong one.
    case "$(classify "$out")" in
        survived)
            case "$KNOWN_SURVIVORS" in
                *" $id "*)
                    note "$(printf '%-34s survived (known: the branch is unreachable here) %s' "$id" "$out")"
                    known=$((known + 1)) ;;
                *)
                    note "$(printf '%-34s SURVIVED %s' "$id" "$out")"
                    survived=$((survived + 1)) ;;
            esac ;;
        caught)
            note "$(printf '%-34s caught   %s' "$id" "$out")"
            caught=$((caught + 1)) ;;
        *)
            note "$(printf '%-34s NO RESULT %s' "$id" "${out:-<no output>}")"
            unresolved=$((unresolved + 1)) ;;
    esac
done < "$TABLE"

# Naming an id that matches no row verifies nothing, and saying so is the point
# of running one.
if [ "${#wanted[@]}" -gt 0 ] &&
        [ "$((caught + survived + known + skipped + unresolved))" -eq 0 ]; then
    echo "no row matched: ${wanted[*]}" >&2
    exit 1
fi

note "$(printf '\n%d caught, %d survived, %d survived-by-design, %d skipped, %d unresolved' \
    "$caught" "$survived" "$known" "$skipped" "$unresolved")"
# A row whose expression matches nothing, or a suite that dies, is a broken
# instrument rather than a clean run, so both fail this script.
[ "$survived" -eq 0 ] && [ "$skipped" -eq 0 ] && [ "$unresolved" -eq 0 ]
