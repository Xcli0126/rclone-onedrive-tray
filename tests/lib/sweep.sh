#!/usr/bin/env bash
#
# sweep.sh: run the mutation table one suite at a time, and resume where it stopped.
#
#   tests/lib/sweep.sh --out DIR [suite...]     every suite, or the named ones
#   tests/lib/sweep.sh --out DIR --force        re-run suites that are already done
#   tests/lib/sweep.sh --out DIR --list         say what is done, torn and left to run
#
# A full pass is hours - 113 rows run install-flow (1m53s each here) and 89 run the tray
# suite (2m33s each) - so it is run in pieces and written down per suite. Each
# DIR/<suite>.txt opens with the header tests/lib/mutate.sh writes: the commit, whether
# the tree was dirty, and the rows the run covered.
#
# A suite counts as done only when its file holds as many verdicts as the table has rows
# for it, so a run that was interrupted is torn rather than done and is started again;
# the file is rewritten when it is. A suite whose file is complete and was measured at
# another commit is reported as stale rather than reused. The exit status is non-zero if
# any file holds a verdict that is not a clean catch (survived, skipped, no result), so
# the caller can tell a clean pass from a broken instrument - including on a run that
# does nothing but look at what is already there.
#
# Not named tests/*.sh on purpose: the documentation check counts those as suites, and
# this is a driver for one of them.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TABLE="$HERE/mutations.txt"
MUTATE="$HERE/mutate.sh"

[ -f "$TABLE" ] || { echo "no $TABLE" >&2; exit 1; }

out=""
force=0
list_only=0
suites=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out) out="${2:-}"; [ -n "$out" ] || { echo "--out needs a directory" >&2; exit 2; }; shift 2 ;;
        --force) force=1; shift ;;
        --list) list_only=1; shift ;;
        -h|--help) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) suites+=("$1"); shift ;;
    esac
done
[ -n "$out" ] || { echo "--out DIR is required (the results are deliverables, not temporaries)" >&2; exit 2; }
if ! mkdir -p "$out" || [ ! -d "$out" ] || [ ! -w "$out" ]; then
    echo "--out $out is not a directory this run can write: nothing was started" >&2
    exit 1
fi

rows_for() {  # rows_for <suite> -- how many rows the table has for it
    awk -F'\t' -v s="$1" '!/^#/ && NF==4 && $4==s' "$TABLE" | wc -l
}
verdicts_in() {  # verdicts_in <file> -- how many verdict lines it holds
    grep -cvE '^#|^$' "$1" 2>/dev/null || true
}
problems_in() {  # problems_in <file> -- verdicts that are not a clean catch
    grep -E 'SURVIVED|SKIPPED|NO RESULT' "$1" 2>/dev/null || true
}
measured_at() {  # measured_at <file> -- the commit its header names
    sed -n 's/^# commit //p' "$1" 2>/dev/null | head -1
}

# Every suite the table names, in the order the table mentions them, so a default run
# covers the table rather than a list maintained here.
if [ "${#suites[@]}" -eq 0 ]; then
    while IFS= read -r name; do suites+=("$name"); done < <(
        awk -F'\t' '!/^#/ && NF==4 && !seen[$4]++ { print $4 }' "$TABLE")
    if [ "${#suites[@]}" -eq 0 ]; then
        echo "no rows in $TABLE: nothing to sweep, and that is not a pass" >&2
        exit 1
    fi
fi

head_at="$(git -C "$HERE/../.." rev-parse --short HEAD 2>/dev/null || echo unknown)"
status=0
for suite in "${suites[@]}"; do
    file="$out/$suite.txt"
    rows="$(rows_for "$suite")"
    if [ "$rows" -eq 0 ]; then
        echo "$suite: no rows in $TABLE" >&2
        status=1
        continue
    fi
    have=0
    [ -f "$file" ] && have="$(verdicts_in "$file")"
    complete=0
    [ "$have" -ge "$rows" ] && complete=1
    state="to run"
    [ "$have" -gt 0 ] && [ "$complete" = 0 ] && state="torn"
    [ "$complete" = 1 ] && state="done"
    at=""
    [ "$complete" = 1 ] && at="$(measured_at "$file")"
    stale=""
    [ "$complete" = 1 ] && [ -n "$at" ] && [ "$at" != "$head_at" ] && stale=" (measured at $at)"
    if [ "$list_only" = 1 ]; then
        printf '%-18s %-7s %3s/%-3s rows%s\n' "$suite" "$state" "$have" "$rows" "$stale"
        # A torn file's verdicts still count for the exit status: what is there was
        # measured, and one of them being a survivor is news whether or not the rest ran.
        if [ "$have" -gt 0 ]; then
            problems="$(problems_in "$file")"
            if [ -n "$problems" ]; then
                printf '%s\n' "$problems" | sed 's/^/    /'
                status=1
            fi
        fi
        continue
    fi
    # A file that holds every verdict is done; anything else is started again, so a run
    # that was interrupted is never mistaken for coverage.
    if [ "$complete" = 1 ] && [ "$force" = 0 ]; then
        printf '%-18s already swept, left alone (%s)\n' "$suite" "$file"
        problems="$(problems_in "$file")"
        if [ -n "$problems" ]; then
            printf '%s\n' "$problems" | sed 's/^/    /'
            status=1
        fi
        continue
    fi
    if [ "$have" -gt 0 ] && [ "$complete" = 0 ]; then
        printf '%-18s torn at %s/%s rows, starting it again\n' "$suite" "$have" "$rows"
    fi
    echo "== $suite ($rows rows) -> $file"
    if ! RESULTS="$file" "$MUTATE" --suite "$suite" | tail -3; then
        status=1
    fi
    if [ "$(verdicts_in "$file")" -lt "$rows" ]; then
        echo "$suite: the run wrote fewer verdicts than rows, so it is torn" >&2
        status=1
    fi
done
exit "$status"
