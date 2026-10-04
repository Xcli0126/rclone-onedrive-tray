#!/usr/bin/env bash
#
# sweep.sh: run the mutation table one suite at a time, and resume where it stopped.
#
#   tests/lib/sweep.sh --out DIR [suite...]     every suite, or the named ones
#   tests/lib/sweep.sh --out DIR --force        re-run suites whose file is there
#   tests/lib/sweep.sh --out DIR --list         say what is done and what is not
#
# A full pass is hours - 113 rows run install-flow (1m53s each here) and 89 run the tray
# suite (three to four minutes each) - so it is run in pieces and written down per
# suite. Each DIR/<suite>.txt opens with the header tests/lib/mutate.sh writes: the
# commit, whether the tree was dirty, and the rows the run covered. A suite whose file
# already exists is left alone, which is what makes the pass resumable; --force runs it
# again. The exit status is non-zero if any suite reported a survivor, a skip or no
# result, so the caller can tell a clean pass from a broken instrument.
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
        -h|--help) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) suites+=("$1"); shift ;;
    esac
done
[ -n "$out" ] || { echo "--out DIR is required (the results are deliverables, not temporaries)" >&2; exit 2; }
mkdir -p "$out"

# Every suite the table names, in the order the table mentions them, so a default run
# covers the table rather than a list maintained here.
if [ "${#suites[@]}" -eq 0 ]; then
    while IFS= read -r name; do suites+=("$name"); done < <(
        awk -F'\t' '!/^#/ && NF==4 && !seen[$4]++ { print $4 }' "$TABLE")
fi

status=0
for suite in "${suites[@]}"; do
    file="$out/$suite.txt"
    rows="$(awk -F'\t' -v s="$suite" '!/^#/ && NF==4 && $4==s' "$TABLE" | wc -l)"
    if [ "$rows" -eq 0 ]; then
        echo "$suite: no rows in $TABLE" >&2
        status=1
        continue
    fi
    if [ "$list_only" = 1 ]; then
        if [ -s "$file" ]; then
            printf '%-18s done   %s\n' "$suite" "$(sed -n '3p' "$file")"
        else
            printf '%-18s to run %s rows\n' "$suite" "$rows"
        fi
        continue
    fi
    if [ -s "$file" ] && [ "$force" = 0 ]; then
        printf '%-18s already swept, left alone (%s)\n' "$suite" "$file"
        continue
    fi
    echo "== $suite ($rows rows) -> $file"
    if RESULTS="$file" "$MUTATE" --suite "$suite" | tail -3; then
        :
    else
        status=1
    fi
done
exit "$status"
