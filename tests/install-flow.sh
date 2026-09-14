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
            "INTERVAL_MIN=\"7\"" "WATCH=\"1\"" "MAX_DELETE=\"100\""; do
    check "config holds $line" grep -qxF -- "$line" "$CFG"
done
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
for s in onedrive-sync onedrive-tray onedrive-watch; do
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
cat > "$CAP/cfg/rclone-onedrive-tray/config" <<EOF
REMOTE="capfake:Vault"
LOCAL="$CAP/local"
LOG="$CAP/sync.log"
RCLONE="rclone"
MAX_DELETE="100"
RETRIES="1"
EOF
cat > "$CAP/rclone" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CAP_ARGS"
[ -n "${CAP_STDERR:-}" ] && printf '%s\n' "$CAP_STDERR" >&2
exit "${CAP_RC:-0}"
STUB
chmod +x "$CAP/rclone"

: > "$WORK/cap-args"
env PATH="$CAP:$PATH" XDG_CONFIG_HOME="$CAP/cfg" XDG_CACHE_HOME="$CAP/cache" \
    CAP_ARGS="$WORK/cap-args" "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
if grep -q -- '--max-delete 50' "$WORK/cap-args"; then
    ok "a count of 100 over 200 files becomes --max-delete 50"
else
    bad "expected --max-delete 50, recorded: $(head -1 "$WORK/cap-args" 2>/dev/null)"
fi

# The cap aborting has to be reported as such, with a way forward.
CAP_STDERR='2026/01/01 00:00:00 ERROR : Safety abort: too many deletes (>50%, 150 of 200) on Path1'
run "an abort is reported as a delete-cap problem" 1 "[maxdelete]" \
    env PATH="$CAP:$PATH" XDG_CONFIG_HOME="$CAP/cfg" XDG_CACHE_HOME="$CAP/cache" \
        CAP_ARGS="$WORK/cap-args" CAP_STDERR="$CAP_STDERR" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"
run "and it says how to proceed" 1 "--force" \
    env PATH="$CAP:$PATH" XDG_CONFIG_HOME="$CAP/cfg" XDG_CACHE_HOME="$CAP/cache" \
        CAP_ARGS="$WORK/cap-args" CAP_STDERR="$CAP_STDERR" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"

# The configured count is translated into rclone's percentage, and the edges of
# that translation matter: 0 must refuse every deletion, an unusable value must
# leave rclone's own 50% default in place rather than switching it off with 100,
# and a count at least as large as the folder must say so in the log.
cap_case() {  # cap_case <value> -> prints the --max-delete the stub recorded
    sed -i "s|^MAX_DELETE=.*|MAX_DELETE=\"$1\"|" "$CAP/cfg/rclone-onedrive-tray/config"
    : > "$WORK/cap-args"
    env PATH="$CAP:$PATH" XDG_CONFIG_HOME="$CAP/cfg" XDG_CACHE_HOME="$CAP/cache" \
        CAP_ARGS="$WORK/cap-args" "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
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
check "and it is called out in the log" grep -q "MAX_DELETE='abc' is not a number" "$CAP/sync.log"
sed -i "s|^MAX_DELETE=.*|MAX_DELETE=\"100\"|" "$CAP/cfg/rclone-onedrive-tray/config"

# The wrapper logs its own "--max-delete N%" line before every run, and an
# earlier version of the hint matched that text, so every unrelated failure was
# reported as a delete-cap abort.
: > "$CAP/sync.log"
CAP_STDERR='2026/01/01 00:00:00 ERROR : Bisync critical error: something else'
run "an unrelated failure is not blamed on the delete cap" 1 "[resync]" \
    env PATH="$CAP:$PATH" XDG_CONFIG_HOME="$CAP/cfg" XDG_CACHE_HOME="$CAP/cache" \
        CAP_ARGS="$WORK/cap-args" CAP_STDERR="$CAP_STDERR" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"
if grep -q 'maxdelete' "$CAP/sync.log"; then
    bad "the delete-cap tag reached the log for an unrelated failure"
else
    ok "and the log has no delete-cap tag for it"
fi

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
    "$HOME/.local/bin/onedrive-watch" "$HOME/.local/bin/onedrive-check"
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
