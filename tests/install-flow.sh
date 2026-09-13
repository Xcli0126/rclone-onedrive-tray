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
chmod +x "$WORK/stubs/rclone" "$WORK/stubs/systemctl"
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
                "--max-delete 100" --filters-file --resync; do
        check "the command line carries $flag" grep -qF -- "$flag" "$CALLS"
    done
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

# ---------------------------------------------------------------- uninstall
title "uninstall.sh"
run "uninstall finishes" 0 "" bash "$SRC_DIR/uninstall.sh" --prefix "$HOME/.local"
check_absent "removes the installed scripts" \
    "$HOME/.local/bin/onedrive-sync" "$HOME/.local/bin/onedrive-tray" \
    "$HOME/.local/bin/onedrive-watch"
check_absent "removes the units" \
    "$UNIT_DIR/$UNIT.service" "$UNIT_DIR/$UNIT.timer" "$UNIT_DIR/$UNIT-watch.service"
check "keeps the configuration (documented; --purge removes it)" test -f "$CFG"

summary
