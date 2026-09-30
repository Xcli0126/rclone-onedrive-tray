#!/usr/bin/env bash
#
# install-flow.sh: walk README's install path end to end inside a sandbox.
#
# README promises a specific set of files after ./setup.sh, and a specific set of
# flags on the rclone command line afterwards. Both are checked here by running
# the real scripts with HOME and every XDG directory pointed into a temporary
# tree, so the machine's own ~/.local, ~/.config, ~/.cache and systemd session
# are never part of the experiment.
#
#   tests/install-flow.sh              run everything
#   tests/install-flow.sh --verbose    also show each command's output
#
# What this does not cover: systemd actually loading the generated units. They
# are written under the sandbox's XDG_CONFIG_HOME, which the running user manager
# does not scan, so the test verifies their contents on disk and with
# systemd-analyze instead. docs/COMPATIBILITY.md says where the scheduled path
# was measured for real.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SRC_DIR/tests/lib/harness.sh" "$@"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A probe name, not onedrive-sync: install.sh and uninstall.sh act on whatever
# UNIT_NAME the config holds, and the machine may well have a live onedrive-sync.
UNIT="zz-flow-probe"
REMOTE="probefake:Vault"
LOCAL_DIR="$WORK/home/OneDrive/Vault"

export HOME="$WORK/home"
export XDG_CONFIG_HOME="$WORK/config"
export XDG_CACHE_HOME="$WORK/cache"
export XDG_DATA_HOME="$WORK/data"
export XDG_STATE_HOME="$WORK/state"
mkdir -p "$HOME" "$WORK/stubs" "$LOCAL_DIR"

CFG_DIR="$XDG_CONFIG_HOME/rclone-onedrive-tray"
CFG="$CFG_DIR/config"
UNIT_DIR="$XDG_CONFIG_HOME/systemd/user"
CALLS="$WORK/rclone-calls"
SYSTEMCTL_CALLS="$WORK/systemctl-calls"

# The one thing this suite must not do for real is talk to a remote.
cat > "$WORK/stubs/rclone" <<EOF
#!/bin/bash
case "\$1" in
    version)     echo "rclone v1.75.1" ;;
    listremotes) echo "probefake:" ;;
    lsf)         printf 'Notes/\\nArchive/\\n' ;;
    lsd)         printf '          -1 2026-01-01 00:00:00        -1 Notes\\n' ;;
    bisync)      printf '%s\\n' "\$*" >> "$CALLS"; sleep 2 ;;
    *)           : ;;
esac
exit 0
EOF

# sudo is stubbed and fails. uninstall.sh reaches for the NetworkManager hook in
# /etc, which belongs to the machine and not to this sandbox.
cat > "$WORK/stubs/sudo" <<EOF
#!/bin/bash
printf '%s\\n' "\$*" >> "$WORK/sudo-calls"
exit 1
EOF

# systemctl is stubbed too, so the watcher's "start the service" decision can be
# observed without asking the real user manager to do anything.
cat > "$WORK/stubs/systemctl" <<EOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        is-active) exit 3 ;;
        start)     printf '%s\\n' "\$*" >> "$SYSTEMCTL_CALLS"; exit 0 ;;
    esac
done
exit 0
EOF
chmod +x "$WORK/stubs/rclone" "$WORK/stubs/systemctl" "$WORK/stubs/sudo"
export PATH="$WORK/stubs:$PATH"

echo "the documented install path, in a sandbox at $WORK"

# ---------------------------------------------------------------- the wizard
title "setup.sh --yes"
run "the non-interactive wizard finishes" 0 "Wrote" \
    bash "$SRC_DIR/setup.sh" --remote "$REMOTE" --local "$LOCAL_DIR" \
        --filters obsidian --interval 7 --watch yes --unit-name "$UNIT" --yes

check "writes the config" test -f "$CFG"
check "writes the filters" test -f "$CFG_DIR/filters.txt"
check "writes the exclude list" test -f "$CFG_DIR/exclude-folders.txt"
for line in "REMOTE=\"$REMOTE\"" "LOCAL=\"$LOCAL_DIR\"" "UNIT_NAME=\"$UNIT\"" \
            "INTERVAL_MIN=\"7\"" "WATCH=\"1\"" "MAX_DELETE=\"100\"" \
            "BW_LIMIT=\"\""; do
    check "config holds $line" grep -qxF -- "$line" "$CFG"
done
check "config.example documents the same bandwidth key" \
    grep -qxF -- 'BW_LIMIT=""' "$SRC_DIR/config/config.example"
check "BISYNC_ARGS carries the recovery flags" \
    grep -q '^BISYNC_ARGS=".*--resilient.*--recover.*--max-lock 2m' "$CFG"
if [ -s "$CALLS" ]; then
    bad "setup.sh started a sync; --yes is documented to stop short of one"
    sed 's/^/        /' "$CALLS"
else
    ok "--yes really did stop short of the baseline sync"
fi

# ---------------------------------------------------------------- the install
title "install.sh via setup.sh"
for s in onedrive-sync onedrive-tray onedrive-watch onedrive-check onedrive-check-access; do
    check "installs $s" test -x "$HOME/.local/bin/$s"
done
check "generates $UNIT.service" test -f "$UNIT_DIR/$UNIT.service"
check "generates $UNIT.timer" test -f "$UNIT_DIR/$UNIT.timer"
check "generates $UNIT-watch.service" test -f "$UNIT_DIR/$UNIT-watch.service"
check "installs the autostart entry" \
    test -f "$XDG_CONFIG_HOME/autostart/rclone-onedrive-tray.desktop"
check "autostart points at the installed tray" \
    grep -qF "Exec=$HOME/.local/bin/onedrive-tray" \
    "$XDG_CONFIG_HOME/autostart/rclone-onedrive-tray.desktop"
check "ExecStart points at the installed wrapper" \
    grep -qF "ExecStart=$HOME/.local/bin/onedrive-sync" "$UNIT_DIR/$UNIT.service"
check "the timer uses OnUnitInactiveSec, so runs cannot overlap" \
    grep -q '^OnUnitInactiveSec=7min' "$UNIT_DIR/$UNIT.timer"
# The units are in the sandbox, which the running user manager does not read, so
# enabling them would reach a same-named unit somewhere else. It has to notice.
run "it does not enable a unit the manager cannot see" 0 "nothing was enabled" \
    bash "$SRC_DIR/install.sh" --prefix "$HOME/.local" --no-start

if command -v systemd-analyze >/dev/null 2>&1; then
    check "systemd accepts $UNIT.service" \
        systemd-analyze --user verify "$UNIT_DIR/$UNIT.service"
    check "systemd accepts $UNIT.timer" \
        systemd-analyze --user verify "$UNIT_DIR/$UNIT.timer"
    check "systemd accepts $UNIT-watch.service" \
        systemd-analyze --user verify "$UNIT_DIR/$UNIT-watch.service"
else
    skip "systemd-analyze is not installed; unit syntax unchecked"
fi

# ---------------------------------------------------------------- the wrapper
title "onedrive-sync against a stub remote"
: > "$CALLS"
run "a resync run succeeds" 0 "" "$HOME/.local/bin/onedrive-sync" --resync

if [ -s "$CALLS" ]; then
    ok "rclone was invoked exactly as configured"
    for flag in bisync "$REMOTE" "$LOCAL_DIR" --resilient --recover \
                "--max-lock 2m" "--conflict-resolve none" "--conflict-loser num" \
                --max-delete --filters-file --resync; do
        check "the command line carries $flag" grep -qF -- "$flag" "$CALLS"
    done
    # The configured MAX_DELETE is a file count, while rclone reads the flag as a
    # percentage, so what reaches rclone is a number the wrapper calculated.
    if grep -qE -- '--max-delete [0-9]+' "$CALLS"; then
        ok "the delete cap reaches rclone as a percentage"
    else
        bad "the delete cap was not passed as a number"
    fi
else
    bad "rclone was never invoked"
fi

# Two bisync processes on the same file pair delete each other's listings, so the
# lock has to make the second run wait for the first instead of racing it.
: > "$CALLS"
"$HOME/.local/bin/onedrive-sync" --resync >/dev/null 2>&1 &
FIRST=$!
sleep 0.5
STARTED="$(date +%s)"
"$HOME/.local/bin/onedrive-sync" --resync >/dev/null 2>&1
SECOND_RC=$?
ELAPSED=$(( $(date +%s) - STARTED ))
wait "$FIRST"
if [ "$SECOND_RC" -eq 0 ] && [ "$ELAPSED" -ge 1 ]; then
    ok "a second run waits for the first instead of overlapping"
else
    bad "the second run did not wait (exit $SECOND_RC after ${ELAPSED}s)"
fi
check "both runs reach rclone, one after the other" test "$(wc -l < "$CALLS")" -eq 2
check "the lock lives in its own cache directory, not a shared /tmp name" \
    test -f "$XDG_CACHE_HOME/rclone-onedrive-tray/sync.lck"

# ---------------------------------------------------------------- the watcher
title "onedrive-watch"
# The sandbox config is ours, so the waits can be short. Left as setup.sh wrote
# them they are 8 and 12 seconds, which is right in production and slow here.
sed -i 's/^WATCH_DEBOUNCE=.*/WATCH_DEBOUNCE="1"/; s/^WATCH_SETTLE=.*/WATCH_SETTLE="1"/' "$CFG"
: > "$SYSTEMCTL_CALLS"

"$HOME/.local/bin/onedrive-watch" >/dev/null 2>"$WORK/watch.log" &
WATCH_PID=$!
sleep 3                      # let the startup drain finish
touch "$LOCAL_DIR/note.md"
for _ in $(seq 1 30); do
    [ -s "$SYSTEMCTL_CALLS" ] && break
    sleep 0.5
done
kill "$WATCH_PID" 2>/dev/null
wait "$WATCH_PID" 2>/dev/null

if grep -q "start .*$UNIT" "$SYSTEMCTL_CALLS" 2>/dev/null; then
    ok "an edit in the tree asks systemd to start $UNIT"
else
    bad "an edit did not lead to a sync request"
    head -3 "$WORK/watch.log" | sed 's/^/        /'
fi
check "the watcher reports the tree it watches" \
    grep -qF "watching $LOCAL_DIR" "$WORK/watch.log"

# ---------------------------------------------------------------- the checker
title "onedrive-check"
check "the checker is installed" test -x "$HOME/.local/bin/onedrive-check"
run "a clean tree needs nothing" 0 "nothing to fix" \
    "$HOME/.local/bin/onedrive-check"

# One name Microsoft reserves, one pair the service cannot keep apart.
touch "$LOCAL_DIR/CON" "$LOCAL_DIR/Clash.md" "$LOCAL_DIR/clash.md"
run "a reserved name is reported" 1 "reserved name: CON" \
    "$HOME/.local/bin/onedrive-check"
run "a case clash is reported" 1 "OneDrive ignores case" \
    "$HOME/.local/bin/onedrive-check"
rm -f "$LOCAL_DIR/CON" "$LOCAL_DIR/clash.md"
: > "$LOCAL_DIR/a:b.md"
run "a name that will be renamed does not fail the check" 0 "will rename these" \
    "$HOME/.local/bin/onedrive-check"
rm -f "$LOCAL_DIR/a:b.md"

# The wrapper checks before a resync, because that is the run that uploads
# everything and turns one bad name into a permanent retry loop.
touch "$LOCAL_DIR/CON"
run "a resync reports the bad name and carries on" 0 "reserved name: CON" \
    "$HOME/.local/bin/onedrive-sync" --resync
rm -f "$LOCAL_DIR/CON" "$LOCAL_DIR/Clash.md" "$LOCAL_DIR/clash.md"

run "the help text is not truncated" 0 "were taken are in" \
    "$HOME/.local/bin/onedrive-check" --help

# ---------------------------------------------------------------- the delete cap
# rclone bisync reads --max-delete as a PERCENTAGE, so passing the configured
# file count straight through capped nothing at all. Measured on rclone 1.75.1
# before the fix: --max-delete 100 with 250 of 300 files deleted exited 0 and
# propagated the deletions. The wrapper now converts the count using the size of
# the pair, taken from rclone's listing.
title "the delete cap"
CAP="$WORK/cap"
mkdir -p "$CAP/cfg/rclone-onedrive-tray" "$CAP/cache/rclone/bisync" "$CAP/local"
for i in $(seq 1 200); do : > "$CAP/local/f$i.txt"; done
slug="$(printf '%s' "$CAP/local" | sed -e 's|^/||' -e 's|[/: ]|_|g')"
{ printf '# bisync listing v1 from test\n'
  for i in $(seq 1 200); do
      printf -- '-        1 - - 2026-01-01T00:00:00.000000000+0000 "f%s.txt"\n' "$i"
  done
} > "$CAP/cache/rclone/bisync/x..$slug.path1.lst"
cat > "$CAP/rclone" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CAP_ARGS"
[ -n "${CAP_STDERR:-}" ] && printf '%s\n' "$CAP_STDERR" >&2
exit "${CAP_RC:-0}"
STUB
chmod +x "$CAP/rclone"

# cap_config [extra config lines] -- rewrite the CAP fixture's config.
cap_config() {
    cat > "$CAP/cfg/rclone-onedrive-tray/config" <<EOF
REMOTE="capfake:Vault"
LOCAL="$CAP/local"
LOG="$CAP/sync.log"
RCLONE="rclone"
MAX_DELETE="100"
RETRIES="1"
${1:-}
EOF
}

# cap_env [VAR=VALUE...] -- run something against the CAP fixture. The stub
# rclone reads CAP_ARGS for where to record its argv, and CAP_STDERR and CAP_RC
# for the failure it should report, so a case is set up by adding to this.
cap_env() {
    env PATH="$CAP:$PATH" XDG_CONFIG_HOME="$CAP/cfg" XDG_CACHE_HOME="$CAP/cache" \
        CAP_ARGS="$WORK/cap-args" "$@"
}

cap_config
: > "$WORK/cap-args"
cap_env "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
if grep -q -- '--max-delete 50' "$WORK/cap-args"; then
    ok "a count of 100 over 200 files becomes --max-delete 50"
else
    bad "expected --max-delete 50, recorded: $(head -1 "$WORK/cap-args" 2>/dev/null)"
fi

# The cap aborting has to be reported as such, with a way forward.
CAP_STDERR='2026/01/01 00:00:00 ERROR : Safety abort: too many deletes (>50%, 150 of 200) on Path1'
run "an abort is reported as a delete-cap problem" 1 "[maxdelete]" \
    cap_env CAP_STDERR="$CAP_STDERR" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"
run "and it says how to proceed" 1 "--force" \
    cap_env CAP_STDERR="$CAP_STDERR" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"

# The configured count is translated into rclone's percentage, and the edges of
# that translation matter: 0 must refuse every deletion, an unusable value must
# leave rclone's own 50% default in place rather than switching it off with 100,
# and a count at least as large as the folder must say so in the log.
cap_case() {  # cap_case <value> -> prints the --max-delete the stub recorded
    sed -i "s|^MAX_DELETE=.*|MAX_DELETE=\"$1\"|" "$CAP/cfg/rclone-onedrive-tray/config"
    : > "$WORK/cap-args"
    cap_env "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
    grep -oE -- '--max-delete [0-9]+' "$WORK/cap-args" | awk '{print $2}'
}
check "MAX_DELETE=0 refuses every deletion" test "$(cap_case 0)" = 0
check "MAX_DELETE=100 over 200 files is 50 percent" test "$(cap_case 100)" = 50
check "a count the size of the folder becomes 100" test "$(cap_case 200)" = 100
if [ -z "$(cap_case -1)" ]; then
    ok "an unusable count leaves rclone's own default in place"
else
    bad "an unusable count still passed --max-delete"
fi
if [ -z "$(cap_case abc)" ]; then
    ok "a non-numeric count passes no flag either"
else
    bad "a non-numeric count still passed --max-delete"
fi
check "and it is called out in the log" grep -q "MAX_DELETE='abc' is not a usable count" "$CAP/sync.log"
sed -i "s|^MAX_DELETE=.*|MAX_DELETE=\"100\"|" "$CAP/cfg/rclone-onedrive-tray/config"

# Two ways the denominator can be wrong, both found by an adversarial pass.
# A --force inherited from BISYNC_ARGS bypasses rclone's cap, and it used to
# pass silently while every other guard looked intact.
cap_config 'BISYNC_ARGS="--resilient --force"'
: > "$CAP/sync.log"; : > "$WORK/cap-args"
cap_env "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
check "an inherited --force is called out in the log" \
    grep -q -- "--force is set in BISYNC_ARGS" "$CAP/sync.log"

# Two pairs naming one local path: guessing which listing belongs to this run
# produced a denominator several times too large, so the size is called unknown
# and the conservative cap is used instead.
{ printf '# bisync listing v1\n'
  for i in $(seq 1 3000); do printf -- '-        1 - - 2026-01-01T00:00:00.000000000+0000 "a%s"\n' "$i"; done
} > "$CAP/cache/rclone/bisync/otherpair..$slug.path1.lst"
cap_config
: > "$CAP/sync.log"; : > "$WORK/cap-args"
cap_env "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
check "two pairs on one local path are refused rather than guessed" \
    grep -q "pairs share" "$CAP/sync.log"
check "and the conservative cap is used" grep -q -- "--max-delete 5" "$WORK/cap-args"
rm -f "$CAP/cache/rclone/bisync/otherpair..$slug.path1.lst"

# The wrapper logs its own "--max-delete N%" line before every run, and an
# earlier version of the hint matched that text, so every unrelated failure was
# reported as a delete-cap abort.
: > "$CAP/sync.log"
CAP_STDERR='2026/01/01 00:00:00 ERROR : Bisync critical error: something else'
run "an unrelated failure is not blamed on the delete cap" 1 "[resync]" \
    cap_env CAP_STDERR="$CAP_STDERR" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"
if grep -q 'maxdelete' "$CAP/sync.log"; then
    bad "the delete-cap tag reached the log for an unrelated failure"
else
    ok "and the log has no delete-cap tag for it"
fi

# ---------------------------------------------------------------- the bandwidth limit
# The tray's settings dialog writes BW_LIMIT. A value rclone cannot parse would
# turn every scheduled run into a failure, and the tray has nothing to report but
# "rclone failed", so the shape is judged here and an unusable value is dropped
# into the log instead of onto the command line. The CAP stub already records the
# argv verbatim, so one config rewrite per case is all this needs.
title "the bandwidth limit"
probe_run() {  # probe_run -> the argv the stub recorded
    : > "$WORK/cap-args"; : > "$CAP/sync.log"
    cap_env "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
    cat "$WORK/cap-args" 2>/dev/null
}
probe_case() { cap_config "${1:-}"; probe_run; }

for value in 1M 5M 10M 500k 1.5M; do
    args="$(probe_case "BW_LIMIT=\"$value\"")"
    check "BW_LIMIT=$value reaches rclone as --bwlimit" \
        grep -qF -- "--bwlimit $value" <<<"$args"
done

# A settings dialog may hand the value over with space around it, or with quotes
# as part of it. Both are stripped, and the size that reaches rclone is the bare
# one, because "--bwlimit '  10M '" is not a size rclone would parse either.
args="$(probe_case 'BW_LIMIT="  10M  "')"
check "surrounding whitespace is trimmed" grep -qF -- '--bwlimit 10M' <<<"$args"
args="$(probe_case 'BW_LIMIT="\"500k\""')"
check "a value carrying quotes is unwrapped" grep -qF -- '--bwlimit 500k' <<<"$args"

# Empty and absent both mean no limit, which is rclone's own default, so no flag
# is passed and the command line stays as it was for every existing install.
for absent in 'BW_LIMIT=""' ''; do
    args="$(probe_case "$absent")"
    if grep -q -- '--bwlimit' <<<"$args"; then
        bad "'$absent' still passed --bwlimit"
    else
        ok "'$absent' means no limit, and no flag"
    fi
done

# A value rclone would reject fails every run, so it is refused here with the
# reason in the log. Each of these has the wrong shape for a different reason.
for bad_value in '5M/1M' 'fast' 'M5' '1..5M' '5.' '-5M'; do
    args="$(probe_case "BW_LIMIT=\"$bad_value\"")"
    if grep -q -- '--bwlimit' <<<"$args"; then
        bad "BW_LIMIT=$bad_value was passed to rclone anyway"
    elif grep -qF "BW_LIMIT='$bad_value' is not a usable rclone size" "$CAP/sync.log"; then
        ok "BW_LIMIT=$bad_value is refused, with the reason in the log"
    else
        bad "BW_LIMIT=$bad_value was dropped without a reason in the log"
    fi
done

# ---------------------------------------------------------------- empty vs absent keys
# BISYNC_ARGS="" used to read as "unset", so emptying it handed the full default
# set back to somebody who had just asked for no extra flags. Whether the key is
# in the config at all is what tells the two apart.
title "an empty BISYNC_ARGS"
args="$(probe_case 'BISYNC_ARGS=""')"
if grep -q -- '--resilient' <<<"$args"; then
    bad 'BISYNC_ARGS="" still brought the default flags back'
else
    ok "an explicitly empty BISYNC_ARGS passes no extra flags"
fi
check "and the log says the value was empty" \
    grep -qF "BISYNC_ARGS is set but empty" "$CAP/sync.log"

args="$(probe_case)"
check "an absent key still gets the documented default" \
    grep -qF -- '--resilient --recover --max-lock 2m' <<<"$args"
check "and the log says where the flags came from" \
    grep -qF "BISYNC_ARGS is not in the config" "$CAP/sync.log"

args="$(probe_case 'BISYNC_ARGS="--resilient"')"
check "a value that is set is used as written" grep -qF -- '--resilient' <<<"$args"
if grep -qF -- '--conflict-resolve' <<<"$args"; then
    bad "the default set leaked back in beside an explicit value"
else
    ok "and nothing from the default set is added to it"
fi

# ---------------------------------------------------------------- the exclude list
# The tray's "Folders to sync" menu writes this file. A line holding only spaces
# is not a folder, and it used to become --exclude "/   /**": rclone matched that
# on every run.
title "the exclude list"
EXF="$WORK/exclude-folders.txt"
printf 'Keep\n\n   \t \n# a comment\nDrop\r\n  Spaced  \n/root\n..\nEvil..Dir\n' > "$EXF"
args="$(probe_case "EXCLUDE_FOLDERS_FILE=\"$EXF\"")"
check "a plain name is excluded" grep -qF -- '--exclude /Keep/**' <<<"$args"
check "a CRLF line is excluded without the CR" grep -qF -- '--exclude /Drop/**' <<<"$args"
check "a name with space around it is trimmed" grep -qF -- '--exclude /Spaced/**' <<<"$args"
check "exactly the three usable names reach rclone" \
    test "$(grep -o -- '--exclude' <<<"$args" | wc -l)" -eq 3
if grep -qE -- '--exclude /[[:space:]]+/\*\*' <<<"$args"; then
    bad "a whitespace-only line still became an exclude rule"
else
    ok "a whitespace-only line is skipped"
fi
check "the log counts only the folders that were kept" \
    grep -qF "3 folder(s) deselected" "$CAP/sync.log"
# A slash or a .. would step outside the top level the tray offered, so the name
# is refused with the reason rather than handed to rclone.
check "a name with a slash is refused, and the log says so" \
    grep -qF "ignoring exclude entry '/root'" "$CAP/sync.log"
check "a name with .. is refused too" \
    grep -qF "ignoring exclude entry 'Evil..Dir'" "$CAP/sync.log"
check "and the bare .. entry with it" \
    grep -qF "ignoring exclude entry '..'" "$CAP/sync.log"

# ---------------------------------------------------------------- the log itself
# mkdir -p with 2>/dev/null hid its own failure, so a run could report success
# having written no log at all, and the failure hint then pointed at a file that
# could not exist.
title "a log that cannot be written"
RO="$WORK/readonly"
mkdir -p "$RO"
chmod 500 "$RO"
if [ -w "$RO" ]; then
    skip "a 0500 directory is still writable here, so the log check was not exercised"
else
    cap_config "LOG=\"$RO/sync.log\""
    : > "$WORK/cap-args"
    run "a run whose log cannot be opened fails, naming the path" 1 "$RO/sync.log" \
        cap_env "$HOME/.local/bin/onedrive-sync"
    check "and it stopped before touching the remote" test ! -s "$WORK/cap-args"

    # The same defect one level up: the directory cannot be created at all.
    cap_config "LOG=\"$RO/nested/sync.log\""
    : > "$WORK/cap-args"
    out="$(cap_env "$HOME/.local/bin/onedrive-sync" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "$RO/nested/sync.log" <<<"$out"; then
        ok "a log directory that cannot be created is reported too"
    else
        bad "an uncreatable log directory passed silently (rc=$rc)"
    fi
    check "and that run stopped before touching the remote too" \
        test ! -s "$WORK/cap-args"
fi
chmod 700 "$RO"

# The sections below read the CAP log, so the config goes back to the plain one.
cap_config

# ---------------------------------------------------------------- the access check
# rclone's --check-access aborts a run when a marker file is missing on one side,
# which is the shape of a network, auth or mount failure. It is opt-in, because
# switching it on changes what bisync demands of the tree: an existing install
# must keep the command line it had until CHECK_ACCESS asks for the check. The
# stub records each bisync argv verbatim, so the three configurations can be told
# apart on the recorded command line.
title "the access check"
ACC="$WORK/access"
mkdir -p "$ACC/cfg/rclone-onedrive-tray" "$ACC/cache" "$ACC/local" "$ACC/remote"
cat > "$ACC/rclone" <<'STUB'
#!/bin/bash
# bisync appends; copyto and lsf are what onedrive-check-access calls. The
# remote is a name rclone resolves (accessfake:Vault), not a path this stub can
# write to, so copyto lands the file in $ACC_REMOTE, which is where an alias
# remote would have put it.
case "$1" in
    bisync) printf '%s\n' "$*" >> "$ACC_ARGS" ;;
    copyto) printf '%s\n' "$*" >> "$ACC_ARGS"
            cp -- "$2" "$ACC_REMOTE/$(basename "$3")" ;;
    lsf)    ls -1 "$ACC_REMOTE" 2>/dev/null || true ;;
esac
exit 0
STUB
chmod +x "$ACC/rclone"

# The two keys are rewritten per case; the rest of the file stays put.
acc_config() {  # acc_config <CHECK_ACCESS> <CHECK_FILENAME>
    cat > "$ACC/cfg/rclone-onedrive-tray/config" <<EOF
REMOTE="accessfake:Vault"
LOCAL="$ACC/local"
LOG="$ACC/cache/sync.log"
RCLONE="rclone"
MAX_DELETE="0"
RETRIES="1"
CHECK_ACCESS="$1"
CHECK_FILENAME="$2"
EOF
}

# acc_env [VAR=VALUE...] -- run something against the ACC fixture.
acc_env() {
    env PATH="$ACC:$PATH" XDG_CONFIG_HOME="$ACC/cfg" XDG_CACHE_HOME="$ACC/cache" \
        ACC_ARGS="$WORK/access-args" "$@"
}

access_case() {  # access_case <CHECK_ACCESS> <CHECK_FILENAME> -> the bits of argv asked about
    acc_config "$1" "$2"
    : > "$WORK/access-args"
    acc_env "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
    cat "$WORK/access-args" 2>/dev/null
}

# The key off is the default for every existing install, and it is the case that
# has to be exactly as it was before: no flag, so rclone's own default applies.
if access_case 0 "" | grep -q -- '--check-access'; then
    bad "the check reached rclone with CHECK_ACCESS=0"
else
    ok "with the key off no access check reaches rclone"
fi
if access_case "" "" | grep -q -- '--check-access'; then
    bad "an unset key still asked for the check"
else
    ok "an unset key leaves the command line alone too"
fi

# On, with no filename: the flag alone, and rclone falls back to RCLONE_TEST.
args="$(access_case 1 "")"
if grep -q -- '--check-access' <<<"$args"; then
    ok "with the key on the flag reaches rclone"
else
    bad "CHECK_ACCESS=1 did not pass --check-access"
fi
if grep -q -- '--check-filename' <<<"$args"; then
    bad "--check-filename was passed without a CHECK_FILENAME"
else
    ok "and nothing overrides rclone's own RCLONE_TEST default"
fi

# On with a filename: both flags, and the configured name is what is passed.
# Upstream recommends a name already present in many places over one marker at
# the root, so this is the setting for an existing tree.
args="$(access_case 1 ".sync-id")"
if grep -q -- '--check-filename .sync-id' <<<"$args"; then
    ok "CHECK_FILENAME reaches rclone as --check-filename"
else
    bad "--check-filename .sync-id was not on the command line"
fi
if [ "$(printf '%s\n' "$args" | wc -l)" -eq 1 ]; then
    ok "and it did not run twice"
else
    bad "the wrapper invoked rclone more than once for one run"
fi

# A filename on its own is not a request for the check. The marker file it names
# is the user's own, and asking for it while the key is off would abort runs that
# work today.
if access_case 0 ".sync-id" | grep -q -- '--check-access'; then
    bad "CHECK_FILENAME switched the check on by itself"
else
    ok "CHECK_FILENAME without CHECK_ACCESS changes nothing"
fi

# The script that creates what the check looks for. rclone will not create it, so
# the tree it protects is broken by the check's introduction unless the file is
# there on both sides before the key is turned on.
title "onedrive-check-access"
acc_config 0 ""
rm -f "$ACC/local/RCLONE_TEST" "$ACC/remote/RCLONE_TEST"
: > "$WORK/access-args"
run "the marker file is created on both sides" 0 "both present" \
    acc_env ACC_REMOTE="$ACC/remote" "$HOME/.local/bin/onedrive-check-access"
check "the marker file reaches both sides" test "$(wc -l < "$WORK/access-args")" -eq 1
check "it goes to one file at a time (copyto, not a tree copy)" \
    grep -q '^copyto ' "$WORK/access-args"
check "the local marker exists" test -f "$ACC/local/RCLONE_TEST"
check "the remote marker exists" test -f "$ACC/remote/RCLONE_TEST"
before="$(cat "$ACC/remote/RCLONE_TEST")"
run "the script is safe to run twice" 0 "keeps" \
    acc_env ACC_REMOTE="$ACC/remote" "$HOME/.local/bin/onedrive-check-access"
check "and the marker was left alone" test "$(cat "$ACC/remote/RCLONE_TEST")" = "$before"
run "it says what it would do without touching anything" 0 "would write" \
    acc_env ACC_REMOTE="$ACC/remote" "$HOME/.local/bin/onedrive-check-access" --dry-run

# ---------------------------------------------------------------- hint tags
# A failure that happens before Microsoft answers is a network problem, however
# much its message talks about tokens. rclone says:
#   couldn't fetch token: Post ".../oauth2/v2.0/token": EOF
# and that used to be reported as an expired sign-in.
title "network failures and expired sign-ins"
CAP_EOF='2026/01/01 00:00:00 CRITICAL: failed to get root: Get "https://graph.microsoft.com/v1.0/drives/X/root": couldn'"'"'t fetch token: Post "https://login.microsoftonline.com/common/oauth2/v2.0/token": EOF'
CAP_AUTH='2026/01/01 00:00:00 CRITICAL: Failed to refresh token: oauth2: cannot fetch token: 400 Bad Request: {"error":"invalid_grant","error_description":"AADSTS70043: The refresh token has expired"}'
run "a token fetch that never reached Microsoft is a network problem" 1 "[network]" \
    cap_env CAP_STDERR="$CAP_EOF" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"
run "a refused token is an expired sign-in, and says what to click" 1 "[auth]" \
    cap_env CAP_STDERR="$CAP_AUTH" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"
run "and the message names the tray item and the command" 1 "config reconnect" \
    cap_env CAP_STDERR="$CAP_AUTH" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"

# ---------------------------------------------------------------- uninstall
title "uninstall.sh"
UNINSTALL_OUT="$(bash "$SRC_DIR/uninstall.sh" --prefix "$HOME/.local" 2>&1)"
UNINSTALL_RC=$?
if [ "$UNINSTALL_RC" -eq 0 ]; then
    ok "uninstall finishes"
else
    bad "uninstall exits $UNINSTALL_RC"
    printf '%s\n' "$UNINSTALL_OUT" | head -3 | sed 's/^/        /'
fi
check_absent "removes the installed scripts" \
    "$HOME/.local/bin/onedrive-sync" "$HOME/.local/bin/onedrive-tray" \
    "$HOME/.local/bin/onedrive-watch" "$HOME/.local/bin/onedrive-check" \
    "$HOME/.local/bin/onedrive-check-access"
check_absent "removes the units" \
    "$UNIT_DIR/$UNIT.service" "$UNIT_DIR/$UNIT.timer" "$UNIT_DIR/$UNIT-watch.service"
check "keeps the configuration (documented; --purge removes it)" test -f "$CFG"
# The hook in /etc belongs to the machine. This sandbox never had one, and the
# unit name it would name is not the one being removed, so sudo must not run.
check_absent "never ran sudo" "$WORK/sudo-calls"
HOOK=/etc/NetworkManager/dispatcher.d/90-rclone-onedrive-tray
if [ -f "$HOOK" ]; then
    if grep -q "Leaving" <<<"$UNINSTALL_OUT"; then
        ok "left the machine-wide hook to the install that owns it"
    else
        bad "a hook exists for another unit and uninstall did not say it left it alone"
    fi
else
    skip "no NetworkManager hook on this machine to leave alone"
fi

summary
