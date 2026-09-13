#!/usr/bin/env bash
#
# harness.sh: the small test harness the suites under tests/ share.
#
# Sourced, never executed. The counters and helpers live here so that two suites
# cannot drift into reporting the same case differently.
#
#   . tests/lib/harness.sh "$@"
#
# The caller's first argument may be --verbose to echo each command's output.
# Counters are prefixed to stay out of the way of the caller's own variables.

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

_pass=0
_fail=0
_skip=0

ok()    { printf '  \033[32mok\033[0m    %s\n' "$*"; _pass=$((_pass + 1)); }
bad()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; _fail=$((_fail + 1)); }
skip()  { printf '  \033[33mskip\033[0m  %s\n' "$*"; _skip=$((_skip + 1)); }
title() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# run <label> <want-exit> <want-substring> <command...>
# want-exit may be "-" to accept anything; an empty want-substring matches all.
run() {
    local label="$1" want_rc="$2" want_msg="$3"; shift 3
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [ "$VERBOSE" = 1 ]; then
        printf '        $ %s\n' "$*"
        printf '%s\n' "$out" | head -12 | sed 's/^/        | /'
    fi
    if [ "$want_rc" != "-" ] && [ "$rc" != "$want_rc" ]; then
        bad "$label: exit $rc, expected $want_rc"
        printf '%s\n' "$out" | head -3 | sed 's/^/        /'
        return
    fi
    if [ -n "$want_msg" ] && ! grep -qF -- "$want_msg" <<<"$out"; then
        bad "$label: output never mentioned '$want_msg'"
        printf '%s\n' "$out" | head -3 | sed 's/^/        /'
        return
    fi
    ok "$label"
}

# check <label> <command...>  -- passes when the command exits zero.
check() {
    local label="$1"; shift
    local out
    if out="$("$@" 2>&1)"; then
        ok "$label"
    else
        bad "$label"
        printf '%s\n' "$out" | head -3 | sed 's/^/        /'
    fi
}

# check_absent <label> <path>...  -- passes when none of the paths exist.
check_absent() {
    local label="$1"; shift
    local p
    for p in "$@"; do
        if [ -e "$p" ]; then
            bad "$label: $p still exists"
            return
        fi
    done
    ok "$label"
}

# summary  -- the closing count, and a non-zero exit if anything failed.
summary() {
    printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' \
        "$_pass" "$_fail" "$_skip"
    [ "$_fail" -eq 0 ] || exit 1
}
