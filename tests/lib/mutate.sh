#!/usr/bin/env bash
#
# mutate.sh: which of the shipped behaviours would the suites actually notice?
#
#   tests/lib/mutate.sh                    every row
#   tests/lib/mutate.sh <id>...            named rows only
#   tests/lib/mutate.sh --suite tray       every row whose suite is the named one
#   tests/lib/mutate.sh --lint             check the table itself, without a suite
#   tests/lib/mutate.sh --self-test        check the verdict classifier on its own
#   RESULTS=mutations.txt tests/lib/mutate.sh     also write the table to a file
#
# A full pass is hours: 113 of the rows run install-flow (about twelve minutes each
# here) and 89 run the tray suite. `--suite` is how a pass is done in pieces, one
# suite at a time, which is also how a partial sweep is recorded: the verdicts in
# RESULTS carry the commit they were measured at.
#
# Each row of mutations.txt describes one small, deliberate change to a shipped
# script: a rule removed, a comparison flipped, a default changed, a flag
# dropped. The harness copies the tree, applies that one change with sed, runs
# the named suite against the copy, and records whether the suite failed. A
# change no suite notices is a hole in the suite, not a curiosity: this is how a
# branch in onedrive-check that no filesystem can reach, and one assertion of the
# tray suite's delete scenario that could not fail, were found.
#
# The sweep is not part of CI: a full pass runs a suite per row and takes hours,
# and it answers a question rather than guarding a door. `--lint` and `--self-test`
# are, because between them they take a second and they are what says the table is
# still an instrument: a row whose expression stopped matching mutates nothing and
# can only be reported SKIPPED hours later. It is not named tests/*.sh on purpose,
# so the documentation check does not count it as a sixth suite.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TABLE="$HERE/mutations.txt"
WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

[ -f "$TABLE" ] || { echo "no $TABLE" >&2; exit 1; }

# --suite <name>: the rows whose suite column is that name. Checked against the
# table, so a typo is a refusal rather than a sweep that says "no row matched".
suite_only=""
if [ "${1:-}" = "--suite" ]; then
    suite_only="${2:-}"
    [ -n "$suite_only" ] || { echo "--suite needs a suite name" >&2; exit 1; }
    grep -q "	$suite_only\$" "$TABLE" || {
        echo "no row in $TABLE is run by the suite '$suite_only'" >&2; exit 1; }
    shift 2
fi
wanted=("$@")

# A row whose change no suite can notice, and that no suite can notice because the
# branch is unreachable on this machine rather than because the suites are thin.
# `check-name-limit` sets the checker's name limit to 99999, and a local filesystem
# refuses a name past 255 bytes before that limit is consulted, so the row survives
# by construction and is written down in docs/KNOWN-ISSUES.md as the one branch
# without a case. Without this list the harness could never exit 0, and every full
# sweep would be red for a reason that is already recorded.
KNOWN_SURVIVORS=" check-name-limit tray-local-root-guard "
# `tray-setunits-invalidate` was on this list for several rounds, with a note saying the
# suite lacked the ordering that would notice it. The ordering was written - pause
# recovery, then the pause ending, with the poll's own periodic re-ask held out of the
# way - and the row is caught now: 306 passed, 1 failed under it, 307 passed, 0 failed
# here. The lesson belongs in the ledger rather than here: "the suite lacks this
# ordering" was true of the cases, not of the code.
# The first is unreachable by construction: a local filesystem refuses a name past 255
# bytes before onedrive-check's own 99999-byte limit is consulted. The second is
# unreachable while _local_delete_path() resolves LOCAL with the same expanduser+realpath
# that local_path_problem() refuses the filesystem root with, so no value can be accepted
# by the first and land on "/" in the second; the case for it is the tilde shape in
# tests/tray.sh, which fails if the two resolutions come apart again - and did, for one
# commit, before this note.
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

# --lint: the table is the instrument, so it is checked on its own, in a second
# rather than in a sweep. A row whose expression no longer matches its file is not
# a survivor and not a hole in a suite: it mutates nothing, so running it can only
# say SKIPPED, and the sweep fails on that. That is how this pass earns its place -
# the row for the invalidation inside _set_units() stopped matching when a docstring
# gained a blank line, and only a full sweep would have said so.
#
# The last check is that failure's general shape: a sed range ending on an empty
# line stops at the first blank line of the block it aims at, which in a script
# with docstrings is often before the line it meant to change.
lint_table() {  # lint_table <table> <root>  -> 0 when every row is usable
    local table="$1" root="$2" problems=0 id target expr suite
    while IFS=$'\t' read -r id target expr suite; do
        case "$id" in ''|'#'*) continue ;; esac
        if [ -z "$suite" ]; then
            printf 'lint: %s: not four tab-separated fields\n' "$id" >&2
            problems=$((problems + 1)); continue
        fi
        if [ ! -f "$root/$target" ]; then
            printf 'lint: %s: no such file: %s\n' "$id" "$target" >&2
            problems=$((problems + 1)); continue
        fi
        if [ ! -f "$root/tests/$suite.sh" ]; then
            printf 'lint: %s: no such suite: tests/%s.sh\n' "$id" "$suite" >&2
            problems=$((problems + 1)); continue
        fi
        # An expression sed refuses is not a mutation. The comparison below would
        # read its empty output as "matches nothing", which is a different verdict,
        # and a row whose sed writes part of its output and then fails would read as
        # a change. Measured on the lint that only compared content: a row holding
        # `q1` passed with sed exiting 1. Status and content both count.
        if ! sed "$expr" "$root/$target" >"$WORK/lint.out" 2>"$WORK/lint.err"; then
            printf 'lint: %s: sed refused the expression: %s\n' "$id" \
                "$(head -1 "$WORK/lint.err")" >&2
            problems=$((problems + 1)); continue
        fi
        if cmp -s "$WORK/lint.out" "$root/$target"; then
            printf 'lint: %s: the expression matches nothing in %s\n' "$id" "$target" >&2
            problems=$((problems + 1))
        fi
        # The range rule, applied to the address and not to the whole expression: a
        # replacement can hold the same three characters, and a substring test called
        # those rows broken. The address is everything before the command, and the
        # command starts at the last whitespace-preceded `s` (a replacement may hold
        # " s" too); an expression with none is cut at its first `s`, which is inside
        # a regex only in rows this cannot judge. Whitespace is not part of an
        # address, so `1,/^$/ s|...|` and `1,/^$/s|...|` are both refused - the
        # first version of this rule looked only at expressions starting with `/`
        # and was defeated by a numeric address, a leading space, and `/ s/,/^$/`.
        #
        # No shipped row uses a blank-line range; this is a guard for the next one.
        # Leading whitespace is stripped first, because sed tolerates it and the
        # first version of this rule skipped such a row outright.
        stripped="${expr#"${expr%%[![:space:]]*}"}"
        case "$stripped" in
            s*) ;;
            *)
                addr="${stripped% s*}"
                addr="${addr//[[:space:]]/}"
                case "$addr" in
                    *',/^$/'*|*'/^$/,/'*)
                        printf 'lint: %s: the range is addressed by an empty line, which is the first blank line of the block it aims at\n' "$id" >&2
                        problems=$((problems + 1)) ;;
                esac ;;
        esac
    done < "$table"
    return "$problems"
}

if [ "${1:-}" = "--lint" ]; then
    status=0
    lint_table "$TABLE" "$REPO" || status=$?
    for known_id in $KNOWN_SURVIVORS; do
        grep -q "^${known_id}	" "$TABLE" || {
            echo "KNOWN_SURVIVORS names $known_id, which is not a row in $TABLE" >&2
            status=$((status + 1))
        }
    done
    if [ "$status" -eq 0 ]; then
        echo "lint: $(grep -cvE '^#|^$' "$TABLE") rows, every one targeting a file, naming a suite, and matching its file"
    fi
    exit "$status"
fi

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
    # The lint has an answer of its own: which rows it can tell apart. Its two
    # failures are the two that cost a sweep to find - a row that mutates nothing,
    # and a range addressed by an empty line - so both are put in front of it here
    # beside a row that has to come back clean.
    LINT_FIX="$WORK/self-test-lint"
    mkdir -p "$LINT_FIX/tests"
    cat > "$LINT_FIX/target.sh" <<'FIXTURE'
f() {
    """A docstring with a blank line in it.

    And a body.
    """
    x=1
    return 1
}
g() {
    y=1
}
FIXTURE
    : > "$LINT_FIX/tests/probe.sh"
    # Four tab-separated fields, one row per failure the lint exists to name.
    printf '%b\n' \
        "live-row\ttarget.sh\ts/^    x=1$/    x=2/\tprobe" \
        "dead-row\ttarget.sh\t/^f() {/,/^$/ s/^    x=1$/    x=2/\tprobe" \
        "blank-range\ttarget.sh\t/^g() {/,/^$/ s/^    y=1$/    y=2/\tprobe" \
        "missing-file\tnope.sh\ts/^x$/y/\tprobe" \
        "missing-suite\ttarget.sh\ts/^    x=1$/    x=2/\tno-such-suite" \
        "bad-expression\ttarget.sh\ts|zzz\tprobe" \
        "spaced-range\ttarget.sh\t/^g() {/, /^$/ s/^    y=1$/    y=2/\tprobe" \
        "plain-range\ttarget.sh\t/^f() {/,/^}/ s/^    x=1$/    x=2/\tprobe" \
        "range-text-in-replacement\ttarget.sh\ts|^    y=1$|    y=1 ,/^$/,|\tprobe" \
        "numeric-range\ttarget.sh\t1,/^$/ s/^    x=1$/    x=2/\tprobe" \
        "spaced-start\ttarget.sh\t /^f() {/,/^$/ s/^    x=1$/    x=2/\tprobe" \
        "space-before-s\ttarget.sh\t/ s/,/^$/ s/^    x=1$/    x=2/\tprobe" \
        > "$LINT_FIX/table"
    lint_out="$(lint_table "$LINT_FIX/table" "$LINT_FIX" 2>&1)"
    lint_rc=$?
    # The row and the complaint together: a row that is reported for the wrong reason
    # ("matches nothing" instead of the range) used to count as reported, which is how
    # the leading-space row passed this self-test while the lint skipped it.
    while IFS='|' read -r want_id want_text; do
        case "$lint_out" in
            *"$want_id: $want_text"*) ;;
            *) printf 'self-test: the lint did not report %s for %s\n' \
                   "$want_id" "$want_text" >&2; bad=1 ;;
        esac
    done <<'WANT'
dead-row|the range is addressed
blank-range|the range is addressed
missing-file|no such file
missing-suite|no such suite
bad-expression|sed refused the expression
spaced-range|the range is addressed
numeric-range|the range is addressed
spaced-start|the range is addressed
space-before-s|the range is addressed
WANT
    case "$lint_out" in
        *live-row*) printf 'self-test: the lint reported a row that is fine\n' >&2; bad=1 ;;
    esac
    if [ "$lint_rc" -eq 0 ]; then
        printf 'self-test: the lint exited 0 over a table with four bad rows\n' >&2
        bad=1
    fi
    grep -v -e dead-row -e blank-range -e missing-file -e missing-suite \
        -e bad-expression -e spaced-range -e numeric-range -e spaced-start \
        -e space-before-s "$LINT_FIX/table" > "$LINT_FIX/table-good"
    if ! lint_table "$LINT_FIX/table-good" "$LINT_FIX" >/dev/null 2>&1; then
        printf 'self-test: the lint reported a table of good rows\n' >&2
        bad=1
    fi

    if [ "$bad" -eq 0 ]; then
        echo "self-test: the classifier reads all six lines, and the lint names nine bad rows and no good one"
    fi
    exit "$bad"
fi

[ -n "${RESULTS:-}" ] && : > "$RESULTS"

caught=0
skipped=0
unresolved=0

while IFS=$'\t' read -r id target expr suite; do
    case "$id" in ''|'#'*) continue ;; esac
    if [ -n "$suite_only" ] && [ "$suite" != "$suite_only" ]; then
        continue
    fi
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
