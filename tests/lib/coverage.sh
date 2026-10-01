#!/usr/bin/env bash
#
# coverage.sh: which lines of the shipped scripts the suites actually execute.
#
#   tests/lib/coverage.sh                 every suite
#   tests/lib/coverage.sh filters         one suite
#
# Not part of CI: it is an instrument to reach for when asking whether a suite
# still runs the code it names, not a gate. It is not named tests/*.sh on
# purpose, so the documentation check does not count it as a sixth suite.
#
# How it works: BASH_ENV points at a file that turns on `set -x` with a PS4 of
# "TRACE <script>:<line>", for the shipped scripts only, and writes that to a
# private file descriptor. The suites run normally against it, the trace is
# deduplicated, and the result is compared with each script's non-comment lines.
#
# Two known blind spots, both worth knowing before quoting a number:
#   * bash does not trace control flow, so `fi`, `else`, `esac` and `done` never
#     appear and are excluded from the line count as well.
#   * a script run under `env -i` loses BASH_ENV and goes untraced. One suite
#     case does that deliberately (setup.sh, to keep its HOME and XDG_* clean),
#     so setup.sh reads lower here than it is.
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

TRACED='onedrive-sync|onedrive-check|onedrive-check-access|onedrive-doctor|onedrive-watch|install.sh|uninstall.sh|setup.sh'
cat > "$WORK/bash_env.sh" <<EOF
case "\${0##*/}" in
    $TRACED)
        exec 19>>"\${TRACE_FILE:-/dev/null}"
        BASH_XTRACEFD=19
        PS4='TRACE \${0##*/}:\${LINENO} '
        set -x
        ;;
esac
EOF

export TRACE_FILE="$WORK/trace.log"
export BASH_ENV="$WORK/bash_env.sh"

if [ "$#" -gt 0 ]; then
    suites=("$@")
else
    suites=(docs filters dependency-matrix install-flow tray)
fi

cd "$SRC_DIR" || exit 1
for suite in "${suites[@]}"; do
    printf 'running %s\n' "$suite" >&2
    bash "tests/$suite.sh" >/dev/null 2>&1 || true
done

if [ ! -s "$TRACE_FILE" ]; then
    echo "no trace was written; BASH_ENV was not picked up" >&2
    exit 1
fi

awk '
    match($0, /^TRACE [^:]+:[0-9]+/) {
        rec = substr($0, 7, RLENGTH - 6)
        if (!seen[rec]++) print rec
    }
' "$TRACE_FILE" | sort > "$WORK/executed.txt"

printf '\n%-28s %6s %6s %7s\n' script ran code percent
for path in bin/onedrive-sync bin/onedrive-check bin/onedrive-check-access \
            bin/onedrive-doctor bin/onedrive-watch install.sh uninstall.sh setup.sh; do
    name="${path##*/}"
    code="$(grep -vcE '^[[:space:]]*(#|$)' "$path")"
    ran="$(grep -c "^$name:" "$WORK/executed.txt" || true)"
    # Lines bash never traces: a bare fi/else/esac/done/brace can never be hit.
    never_traced="$(grep -cE '^[[:space:]]*(fi|else|elif|then|do|done|esac|\}|\);?|;;)[[:space:]]*$' "$path" || true)"
    code=$((code - never_traced))
    [ "$code" -gt 0 ] || code=1
    printf '%-28s %6s %6s %6s%%\n' "$path" "$ran" "$code" "$((ran * 100 / code))"
done
