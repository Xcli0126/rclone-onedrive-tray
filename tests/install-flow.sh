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
        disable)   printf '%s\\n' "\$*" >> "$SYSTEMCTL_CALLS"; exit 0 ;;
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
if cmp -s "$SRC_DIR/config/config.example" "$CFG_DIR/config.example"; then
    ok "and the example beside it is the shipped one"
else
    bad "config.example beside the config differs from the shipped file"
fi
check "writes the filters" test -f "$CFG_DIR/filters.txt"
# A filters file that exists but holds "# none" is the same as no filters at all,
# and a user following the wizard would never see it. The copy of the example was
# replaced by a stub and every case still passed, because nothing compared the
# contents of the file the wizard wrote.
check "the obsidian filters are the shipped example, rule for rule" \
    cmp -s "$SRC_DIR/config/filters.example" "$CFG_DIR/filters.txt"
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

# ------------------------------------------------------- a value that needs escaping
# The wizard writes the config of a file onedrive-sync sources with `.`. A remote
# or a path holding a quote, a dollar or a backtick has to be escaped on the way
# in, or the file fails to source or sources to a different string and the break
# shows up later, in the wrapper. No suite reached this code before: setup.sh was
# the least-executed script in the tree, at 42% of its lines.
title "a config value that needs escaping"
QUOTE_HOME="$WORK/quote-home"
# The four characters the writer escapes: backslash, quote, dollar, backtick.
QUOTE_REMOTE="probefake:we\"ird\$x\`tick\`"
rm -rf "$QUOTE_HOME"; mkdir -p "$QUOTE_HOME"
env -i PATH="$WORK/stubs:/usr/bin:/bin" HOME="$QUOTE_HOME" LANG=C.UTF-8 \
    XDG_CONFIG_HOME="$QUOTE_HOME/.config" XDG_CACHE_HOME="$QUOTE_HOME/.cache" \
    bash "$SRC_DIR/setup.sh" --remote "$QUOTE_REMOTE" \
        --local "$QUOTE_HOME/OneDrive" --filters none --yes --no-install \
    >"$WORK/quote-out.txt" 2>&1
QUOTE_CFG="$QUOTE_HOME/.config/rclone-onedrive-tray/config"
check "the wizard writes a config for a remote that needs escaping" \
    test -f "$QUOTE_CFG"
check "and escapes the quote on the way in" \
    grep -q 'REMOTE="probefake:we\\"ird' "$QUOTE_CFG"
# Read it back the way onedrive-sync does. The source is a variable path, hence
# the directive, which is the form the rest of the repo already uses.
# shellcheck source=/dev/null
QUOTE_GOT="$(set -u; . "$QUOTE_CFG"; printf '%s' "$REMOTE")"
if [ "$QUOTE_GOT" = "$QUOTE_REMOTE" ]; then
    ok "and the value comes back unchanged when the file is sourced"
else
    bad "the value changed: want '$QUOTE_REMOTE', got '$QUOTE_GOT'"
    sed 's/^/        /' "$WORK/quote-out.txt" | head -3
fi

# ---------------------------------------------------------------- re-running the wizard
# ask() returns the prompt's default without reading anything under --yes or
# when stdin is not a terminal. The overwrite prompt's default was "n", so
# --yes could never re-run the wizard: it answered its own question with "no"
# and then told the user to delete the config by hand. --yes is an instruction
# not to ask, and the flags beside it are the answer.
title "re-running setup.sh"
RERUN_HOME="$WORK/rerun-home"
rm -rf "$RERUN_HOME"; mkdir -p "$RERUN_HOME"
RERUN_CFG="$RERUN_HOME/.config/rclone-onedrive-tray/config"
run "the first --yes run writes a config" 0 "Wrote" \
    env HOME="$RERUN_HOME" XDG_CONFIG_HOME="$RERUN_HOME/.config" \
        XDG_CACHE_HOME="$RERUN_HOME/.cache" \
    bash "$SRC_DIR/setup.sh" --remote "$REMOTE" --local "$RERUN_HOME/OneDrive" \
        --filters none --interval 9 --unit-name zz-rerun-probe --yes --no-install
run "a second --yes run overwrites it instead of aborting" 0 "Wrote" \
    env HOME="$RERUN_HOME" XDG_CONFIG_HOME="$RERUN_HOME/.config" \
        XDG_CACHE_HOME="$RERUN_HOME/.cache" \
    bash "$SRC_DIR/setup.sh" --remote "$REMOTE" --local "$RERUN_HOME/OneDrive" \
        --filters none --interval 11 --unit-name zz-rerun-probe --yes --no-install
check "and the second run's value is the one on disk" \
    grep -qxF 'INTERVAL_MIN="11"' "$RERUN_CFG"

# ---------------------------------------------------------------- what a re-run keeps
# ask() returns the prompt's default without reading anything under --yes or
# when stdin is not a terminal. The exclude list was truncated on every run and
# the example filters were copied straight over the file, so the documented
# scripted re-run replaced hand-written rules and emptied the folder list; the
# caches those rules kept out then started syncing.
title "what a scripted re-run of the wizard keeps"
KEEP_HOME="$WORK/keep-home"
KEEP_CFG_DIR="$KEEP_HOME/.config/rclone-onedrive-tray"
KEEP_FILTERS="$KEEP_CFG_DIR/filters.txt"
KEEP_EXCLUDES="$KEEP_CFG_DIR/exclude-folders.txt"
rm -rf "$KEEP_HOME"; mkdir -p "$KEEP_HOME"
env HOME="$KEEP_HOME" XDG_CONFIG_HOME="$KEEP_HOME/.config" \
    XDG_CACHE_HOME="$KEEP_HOME/.cache" \
    bash "$SRC_DIR/setup.sh" --remote "$REMOTE" --local "$KEEP_HOME/OneDrive" \
        --filters obsidian --skip-folders "Archive" --interval 9 \
        --unit-name zz-keep-probe --yes --no-install >/dev/null 2>&1
printf -- '- /my-own-rule/**\n' >> "$KEEP_FILTERS"
printf 'Handwritten\n' >> "$KEEP_EXCLUDES"
run "a scripted re-run says which files it kept" 0 "kept the existing filters.txt" \
    env HOME="$KEEP_HOME" XDG_CONFIG_HOME="$KEEP_HOME/.config" \
        XDG_CACHE_HOME="$KEEP_HOME/.cache" \
    bash "$SRC_DIR/setup.sh" --remote "$REMOTE" --local "$KEEP_HOME/OneDrive" \
        --interval 9 --unit-name zz-keep-probe --yes --no-install
check "and the hand-written filter rule survives that run" \
    grep -qxF -- '- /my-own-rule/**' "$KEEP_FILTERS"
check "and the hand-written exclude entry survives it" \
    grep -qxF 'Handwritten' "$KEEP_EXCLUDES"

# The flags, and only the flags, replace the two files. An explicitly empty
# --skip-folders means "clear the list", which used to die inside bash.
run "an explicit --skip-folders with no value clears the list" 0 "Wrote" \
    env HOME="$KEEP_HOME" XDG_CONFIG_HOME="$KEEP_HOME/.config" \
        XDG_CACHE_HOME="$KEEP_HOME/.cache" \
    bash "$SRC_DIR/setup.sh" --remote "$REMOTE" --local "$KEEP_HOME/OneDrive" \
        --filters none --skip-folders "" --interval 9 \
        --unit-name zz-keep-probe --yes --no-install
if grep -qxF '# no exclusions' "$KEEP_FILTERS" && [ ! -s "$KEEP_EXCLUDES" ]; then
    ok "and --filters none replaced the filters while the empty list was cleared"
else
    bad "the flags did not replace the files: filters='$(head -1 "$KEEP_FILTERS")' excludes=$(wc -c < "$KEEP_EXCLUDES") bytes"
fi

# The first-sync prompt is written "(Y/n)" and was tested with = "y", so the
# capital the prompt advertises meant "no". script(1) gives the wizard a real
# terminal, which is the only way ask() reads anything at all. The sync it would
# start is a stub that records the call, and the config already exists so the
# overwrite prompt is exercised beside it.
PTY_HOME="$WORK/pty-home"
rm -rf "$PTY_HOME"
mkdir -p "$PTY_HOME/.local/bin" "$PTY_HOME/.config/rclone-onedrive-tray"
cat > "$PTY_HOME/.local/bin/onedrive-sync" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$PTY_HOME/sync-calls"
EOF
chmod +x "$PTY_HOME/.local/bin/onedrive-sync"
printf 'REMOTE="%s"\nLOCAL="%s"\nUNIT_NAME="zz-pty-probe"\n' \
    "$REMOTE" "$PTY_HOME/OneDrive" > "$PTY_HOME/.config/rclone-onedrive-tray/config"

pty_setup() {  # pty_setup <answers with \n> -- drive the wizard on a terminal
    printf '%b' "$1" | timeout 60 script -qec \
        "env HOME=$PTY_HOME XDG_CONFIG_HOME=$PTY_HOME/.config XDG_CACHE_HOME=$PTY_HOME/.cache bash $SRC_DIR/setup.sh --remote $REMOTE --local $PTY_HOME/OneDrive --filters none --unit-name zz-pty-probe --skip-folders x --no-install" \
        /dev/null >"$WORK/pty-out.txt" 2>&1
}

rm -f "$PTY_HOME/sync-calls"
pty_setup 'Y\nY\n'
if grep -q -- '--resync' "$PTY_HOME/sync-calls" 2>/dev/null; then
    ok "the capital Y the (Y/n) prompt advertises starts the first sync"
else
    bad "a capital Y at the (Y/n) prompt did not start the first sync"
    grep -a 'Run it now' "$WORK/pty-out.txt" | head -2 | sed 's/^/        /'
fi
rm -f "$PTY_HOME/sync-calls"
pty_setup 'Y\nn\n'
check "an n at the same prompt leaves the first sync to the user" \
    test ! -s "$PTY_HOME/sync-calls"

# With no terminal and no --yes, ask() hands back the (Y/n) prompt's default, so
# the run started the first sync on its own. Under --no-install the wrapper was
# never installed: the shell printed its "No such file" error and the script
# went on to print "Done" over it.
NOSYNC_HOME="$WORK/nosync-home"
rm -rf "$NOSYNC_HOME"; mkdir -p "$NOSYNC_HOME"
NOSYNC_OUT="$(env HOME="$NOSYNC_HOME" XDG_CONFIG_HOME="$NOSYNC_HOME/.config" \
    XDG_CACHE_HOME="$NOSYNC_HOME/.cache" \
    bash "$SRC_DIR/setup.sh" --remote "$REMOTE" --local "$NOSYNC_HOME/OneDrive" \
        --filters none --unit-name zz-nosync-probe --no-install </dev/null 2>&1)"
NOSYNC_RC=$?
if [ "$NOSYNC_RC" -eq 0 ] && grep -qF 'skipping the first sync' <<<"$NOSYNC_OUT" &&
        ! grep -qF 'No such file' <<<"$NOSYNC_OUT"; then
    ok "a wizard run with no installed wrapper skips the first sync"
else
    bad "the first sync ran against a wrapper that is not installed (rc=$NOSYNC_RC)"
    printf '%s\n' "$NOSYNC_OUT" | tail -4 | sed 's/^/        /'
fi

# The other half: the wrapper IS installed and stdin is still not a terminal.
# ask() answers the (Y/n) prompt's default for that case too, so the wizard started
# a full, uninterruptible baseline sync with nobody there to answer. The case above
# could not see it, because --no-install left the wrapper absent.
NOTTY_HOME="$WORK/notty-home"
rm -rf "$NOTTY_HOME"; mkdir -p "$NOTTY_HOME/.local/bin"
cat > "$NOTTY_HOME/.local/bin/onedrive-sync" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/sync-calls"
STUB
chmod +x "$NOTTY_HOME/.local/bin/onedrive-sync"
NOTTY_OUT="$(env HOME="$NOTTY_HOME" XDG_CONFIG_HOME="$NOTTY_HOME/.config" \
    XDG_CACHE_HOME="$NOTTY_HOME/.cache" \
    bash "$SRC_DIR/setup.sh" --remote "$REMOTE" --local "$NOTTY_HOME/OneDrive" \
        --filters none --unit-name zz-notty-probe --no-install </dev/null 2>&1)"
NOTTY_RC=$?
if [ "$NOTTY_RC" -eq 0 ] && grep -qF 'left to you' <<<"$NOTTY_OUT" &&
        [ ! -e "$NOTTY_HOME/sync-calls" ]; then
    ok "a wizard run with no terminal leaves the first sync to the user"
else
    bad "the first sync started with no terminal to answer (rc=$NOTTY_RC)"
    printf '%s\n' "$NOTTY_OUT" | tail -4 | sed 's/^/        /'
fi

# ---------------------------------------------------------------- the install
title "install.sh via setup.sh"
for s in onedrive-sync onedrive-tray onedrive-watch onedrive-check onedrive-check-access \
         onedrive-doctor; do
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
# Quoted, because systemd splits ExecStart on whitespace and a prefix can
# contain a space. A path that needs no quoting still reads the same to systemd.
check "ExecStart points at the installed wrapper" \
    grep -qF "ExecStart=\"$HOME/.local/bin/onedrive-sync\"" "$UNIT_DIR/$UNIT.service"
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

# ---------------------------------------------------------------- the autostart entry
# The entry is the tray's "Start tray at login" setting: unticking the box
# removes the file and the tray reads its presence. install.sh rewrote it on
# every run, so `git pull && ./install.sh` turned the setting back on with no
# message. It is written for a first install and refreshed when it is already
# there; on a re-run whose entry was removed, it stays removed.
title "the autostart entry on a re-run"
AUTOSTART_FILE="$XDG_CONFIG_HOME/autostart/rclone-onedrive-tray.desktop"
rm -f "$AUTOSTART_FILE"
run "a re-run leaves a removed autostart entry removed" 0 "left absent" \
    bash "$SRC_DIR/install.sh" --prefix "$HOME/.local" --no-start
check_absent "and the entry is still absent afterwards" "$AUTOSTART_FILE"

# ---------------------------------------------------------------- the interval drop-in
# The timer unit is written from INTERVAL_MIN here, but the tray's settings
# dialog writes OnUnitInactiveSec into a drop-in beside it and a drop-in wins.
# An old one silently overrode a config edit, so the config owns the interval.
title "the timer interval drop-in"
DROPIN_HOME="$WORK/dropin-home"
DROPIN_CFG_DIR="$DROPIN_HOME/.config/rclone-onedrive-tray"
DROPIN_UNIT_DIR="$DROPIN_HOME/.config/systemd/user"
DROPIN_FILE="$DROPIN_UNIT_DIR/zz-dropin-probe.timer.d/interval.conf"
rm -rf "$DROPIN_HOME"
mkdir -p "$DROPIN_CFG_DIR" "$DROPIN_UNIT_DIR/zz-dropin-probe.timer.d"
cat > "$DROPIN_CFG_DIR/config" <<EOF
REMOTE="$REMOTE"
LOCAL="$DROPIN_HOME/OneDrive"
UNIT_NAME="zz-dropin-probe"
INTERVAL_MIN="5"
WATCH="0"
EOF
printf '# Set by the tray settings dialog.\n[Timer]\nOnUnitInactiveSec=42min\n' \
    > "$DROPIN_FILE"
run "a drop-in that disagrees with INTERVAL_MIN says what it did" 0 \
    "it now says 5min" \
    env HOME="$DROPIN_HOME" XDG_CONFIG_HOME="$DROPIN_HOME/.config" \
        XDG_CACHE_HOME="$DROPIN_HOME/.cache" XDG_DATA_HOME="$DROPIN_HOME/.data" \
    bash "$SRC_DIR/install.sh" --prefix "$DROPIN_HOME/.local" --no-start
check "and the drop-in now holds the config's value" \
    grep -qxF 'OnUnitInactiveSec=5min' "$DROPIN_FILE"

# ---------------------------------------------------------------- the watcher unit
# install.sh wrote <unit>-watch.service only when WATCH=1, and nothing ever
# disabled one. WATCH=0 therefore left an old watcher running, and WATCH=1 after
# a WATCH=0 install had no unit file for the settings switch to enable. The unit
# is written on every run now and the enable step decides what to do with it.
title "the watcher unit and WATCH"
WATCH_HOME="$WORK/watch-home"
WATCH_CFG_DIR="$WATCH_HOME/.config/rclone-onedrive-tray"
WATCH_UNIT_DIR="$WATCH_HOME/.config/systemd/user"
WATCH_STUB_DIR="$WATCH_HOME/.local/bin/stubs"
WATCH_CALLS="$WORK/watch-systemctl-calls"
WATCH_PROBE="zz-watch-probe"
rm -rf "$WATCH_HOME"
mkdir -p "$WATCH_CFG_DIR" "$WATCH_STUB_DIR"
cat > "$WATCH_CFG_DIR/config" <<EOF
REMOTE="$REMOTE"
LOCAL="$WATCH_HOME/OneDrive"
UNIT_NAME="$WATCH_PROBE"
INTERVAL_MIN="5"
WATCH="0"
EOF
# The stub answers the FragmentPath probe with the unit this run writes, so the
# enable branch is the one exercised, and it records every call it was handed.
cat > "$WATCH_STUB_DIR/systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WATCH_CALLS"
case "\$*" in
    *"show -p FragmentPath"*) printf '%s\n' "$WATCH_UNIT_DIR/$WATCH_PROBE.timer" ;;
esac
exit 0
EOF
chmod +x "$WATCH_STUB_DIR/systemctl"
: > "$WATCH_CALLS"
run "a WATCH=0 install writes the watcher unit and says it disabled it" 0 \
    "watcher disabled" \
    env HOME="$WATCH_HOME" XDG_CONFIG_HOME="$WATCH_HOME/.config" \
        XDG_CACHE_HOME="$WATCH_HOME/.cache" XDG_DATA_HOME="$WATCH_HOME/.data" \
        PATH="$WATCH_STUB_DIR:$PATH" \
    bash "$SRC_DIR/install.sh" --prefix "$WATCH_HOME/.local" --no-start
check "and the unit file the settings switch needs is there" \
    test -f "$WATCH_UNIT_DIR/$WATCH_PROBE-watch.service"
check "and systemd was asked to disable that watcher" \
    grep -qF -- "disable --now $WATCH_PROBE-watch.service" "$WATCH_CALLS"

# An update rewrites the watcher unit, but `enable --now` does nothing to a unit
# that is already active, and the watcher is a loop: without a restart it keeps
# running the old code until reboot.
printf '#!/bin/bash\nexit 0\n' > "$WATCH_STUB_DIR/inotifywait"
chmod +x "$WATCH_STUB_DIR/inotifywait"
sed -i 's/^WATCH=.*/WATCH="1"/' "$WATCH_CFG_DIR/config"
: > "$WATCH_CALLS"
env HOME="$WATCH_HOME" XDG_CONFIG_HOME="$WATCH_HOME/.config" \
    XDG_CACHE_HOME="$WATCH_HOME/.cache" XDG_DATA_HOME="$WATCH_HOME/.data" \
    PATH="$WATCH_STUB_DIR:$PATH" \
    bash "$SRC_DIR/install.sh" --prefix "$WATCH_HOME/.local" --no-start \
    >"$WORK/watch-install-out.txt" 2>&1
check "an install that rewrites the watcher unit restarts a running one" \
    grep -qF -- "try-restart $WATCH_PROBE-watch.service" "$WATCH_CALLS"

# A UNIT_NAME changed between installs leaves the old timer enabled forever, and
# nothing said so. The timer is the entry point systemd starts.
title "a sibling timer left by an earlier unit name"
printf '[Timer]\nOnUnitInactiveSec=9min\n' > "$WATCH_UNIT_DIR/zz-old-name.timer"
run "an install warns about a sibling timer that is not the configured name" 0 \
    "systemctl --user disable --now zz-old-name.timer" \
    env HOME="$WATCH_HOME" XDG_CONFIG_HOME="$WATCH_HOME/.config" \
        XDG_CACHE_HOME="$WATCH_HOME/.cache" XDG_DATA_HOME="$WATCH_HOME/.data" \
        PATH="$WATCH_STUB_DIR:$PATH" \
    bash "$SRC_DIR/install.sh" --prefix "$WATCH_HOME/.local" --no-start

# ---------------------------------------------------------------- a prefix with a space
# Exec= in a desktop entry is not a shell word list: the parser splits it on
# spaces, so a prefix like "/home/x/My Files" used to produce a two-argument
# command and the tray never started at login. A name that cannot be split is
# quoted, which is what the Desktop Entry specification asks for, and a literal
# % is written %% because a single one is a field code.
title "an install prefix that needs quoting"
SPACE_HOME="$WORK/space home"
rm -rf "$SPACE_HOME"; mkdir -p "$SPACE_HOME"
env HOME="$SPACE_HOME" XDG_CONFIG_HOME="$SPACE_HOME/.config" \
    XDG_CACHE_HOME="$SPACE_HOME/.cache" XDG_DATA_HOME="$SPACE_HOME/.data" \
    bash "$SRC_DIR/install.sh" --no-start >"$WORK/space-out.txt" 2>&1
SPACE_DESKTOP="$SPACE_HOME/.config/autostart/rclone-onedrive-tray.desktop"
check "the desktop entry is written for a prefix with a space" \
    test -f "$SPACE_DESKTOP"
if grep -qxF "Exec=\"$SPACE_HOME/.local/bin/onedrive-tray\"" "$SPACE_DESKTOP"; then
    ok "Exec double quotes the tray path, so the space stays one argument"
else
    bad "Exec is not quoted for a path with a space: $(grep '^Exec=' "$SPACE_DESKTOP" 2>/dev/null)"
fi

# The unit file is not a desktop entry, but it has the same problem: systemd
# splits ExecStart on whitespace unless the path is quoted, and it expands %i and
# friends inside a unit, so a percent in the path has to be written twice.
# This install has no config to take a unit name from, so it uses the default.
SPACE_UNIT="$SPACE_HOME/.config/systemd/user/onedrive-sync.service"
check "the unit is written for a prefix with a space" test -f "$SPACE_UNIT"
if grep -qxF "ExecStart=\"$SPACE_HOME/.local/bin/onedrive-sync\"" "$SPACE_UNIT"; then
    ok "ExecStart quotes the sync path, so the space stays one argument"
else
    bad "ExecStart is not quoted for a path with a space: $(grep '^ExecStart=' "$SPACE_UNIT" 2>/dev/null)"
fi

PCT_HOME="$WORK/pct%home"
rm -rf "$PCT_HOME"; mkdir -p "$PCT_HOME"
env HOME="$PCT_HOME" XDG_CONFIG_HOME="$PCT_HOME/.config" \
    XDG_CACHE_HOME="$PCT_HOME/.cache" XDG_DATA_HOME="$PCT_HOME/.data" \
    bash "$SRC_DIR/install.sh" --no-start >"$WORK/pct-out.txt" 2>&1
PCT_DESKTOP="$PCT_HOME/.config/autostart/rclone-onedrive-tray.desktop"
PCT_EXPECT="${PCT_HOME//%/%%}/.local/bin/onedrive-tray"
check "a percent in the path is escaped as a literal field code" \
    grep -qxF "Exec=\"$PCT_EXPECT\"" "$PCT_DESKTOP"
# The same run writes the service unit, where a lone % starts a specifier (%h,
# %U, %i), and nothing read it: deleting the escape in systemd_exec_arg left
# every suite green.
PCT_UNIT="$PCT_HOME/.config/systemd/user/onedrive-sync.service"
check "the unit escapes the percent in ExecStart the same way" \
    grep -qxF "ExecStart=\"${PCT_HOME//%/%%}/.local/bin/onedrive-sync\"" "$PCT_UNIT"

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

# Three names from the same documented list were invisible to the checker:
# ".lock" left the stem empty, "desktop.ini" reduced to "desktop", and "_vti_"
# was not in the list at all. The default filters happen to skip the first two,
# so an untouched install was covered by luck rather than by the checker.
# docs/FEATURE-PARITY.md lists all three beside CON.
for reserved in .lock desktop.ini _vti_; do
    : > "$LOCAL_DIR/$reserved"
    run "'$reserved' is a reserved name" 1 "reserved name: $reserved" \
        "$HOME/.local/bin/onedrive-check"
    rm -f "$LOCAL_DIR/$reserved"
done
run "and the tree is clean again once those are gone" 0 "nothing to fix" \
    "$HOME/.local/bin/onedrive-check"

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

# The pair size used to be the larger of the listing and a full walk of LOCAL, so
# a tree bigger than its listing inflated the denominator. The listing is the
# count rclone itself compares the percentage against, so it decides, and the
# walk only happens when there is no listing at all.
BIGLOCAL="$CAP/listing-wins"
mkdir -p "$BIGLOCAL"
for i in $(seq 1 1000); do : > "$BIGLOCAL/b$i.txt"; done
big_slug="$(printf '%s' "$BIGLOCAL" | sed -e 's|^/||' -e 's|[/: ]|_|g')"
{ printf '# bisync listing v1 from test\n'
  for i in $(seq 1 200); do
      printf -- '-        1 - - 2026-01-01T00:00:00.000000000+0000 "b%s.txt"\n' "$i"
  done
} > "$CAP/cache/rclone/bisync/bigpair..$big_slug.path1.lst"
cap_config "LOCAL=\"$BIGLOCAL\""
: > "$WORK/cap-args"
cap_env "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
if grep -q -- '--max-delete 50' "$WORK/cap-args"; then
    ok "a tree larger than its listing is measured by the listing, not walked"
else
    bad "the local walk won over the listing: $(grep -o -- '--max-delete [0-9]*' "$WORK/cap-args" | head -1)"
fi
cap_config

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

# ---------------------------------------------------------------- the argv table
# Four of the last five defects lived on this one command line: a percentage
# read as a count, a bandwidth value rclone cannot parse, an empty BISYNC_ARGS
# meaning two different things, and --resync passed twice. A case per bug is
# what let the next one through, so the whole line is pinned here instead: each
# row runs the wrapper once through the stub rclone and compares the recorded
# argv with an expected string, character for character.
title "the command line, pinned row by row"
CAP_REMOTE="capfake:Vault"
DEF_ARGS='--resilient --recover --max-lock 2m --conflict-resolve none --conflict-loser num --stats 2s'

# Two more fixtures for the delete-cap rows: one with 200 files and no listing,
# one with nothing at all, so both fallbacks inside pair_size() are reachable.
mkdir -p "$CAP/no-listing" "$CAP/empty-local"
for i in $(seq 1 200); do : > "$CAP/no-listing/g$i.txt"; done

# argv_line <local> [tail] -- exactly what the wrapper should hand to rclone.
argv_line() {
    local tail=""
    [ -n "${2:-}" ] && tail=" $2"
    printf 'bisync %s %s %s --log-level INFO --log-file %s%s' \
        "$CAP_REMOTE" "$1" "$DEF_ARGS" "$CAP/sync.log" "$tail"
}

# argv_row <label> <expected> <config-extra> [wrapper arguments...]
argv_row() {
    local label="$1" expected="$2" extra="$3"; shift 3
    cap_config "$extra"
    : > "$WORK/cap-args"
    cap_env "$HOME/.local/bin/onedrive-sync" "$@" >/dev/null 2>&1 || true
    local got
    got="$(cat "$WORK/cap-args" 2>/dev/null)"
    if [ "$got" = "$expected" ]; then
        ok "$label"
    else
        bad "$label"
        printf '        want: %s\n        got:  %s\n' "$expected" "$got"
    fi
}

argv_row "the default config, no arguments: the whole baseline line" \
    "$(argv_line "$CAP/local" '--max-delete 50')" ""
argv_row "MAX_DELETE=100 over a 200-file pair: 50 percent of the local tree" \
    "$(argv_line "$CAP/no-listing" '--max-delete 50')" \
    "LOCAL=\"$CAP/no-listing\""
argv_row "a pair whose size cannot be determined keeps the conservative 5 percent" \
    "$(argv_line "$CAP/empty-local" '--max-delete 5')" \
    "LOCAL=\"$CAP/empty-local\""
argv_row "BW_LIMIT=1.5M reaches rclone as --bwlimit 1.5M" \
    "$(argv_line "$CAP/local" '--max-delete 50 --bwlimit 1.5M')" \
    'BW_LIMIT="1.5M"'
argv_row "a BW_LIMIT rclone cannot parse is dropped, never passed on" \
    "$(argv_line "$CAP/local" '--max-delete 50')" \
    'BW_LIMIT="5M/1M"'
argv_row "an absent BISYNC_ARGS gets the built-in default set" \
    "$(argv_line "$CAP/local" '--max-delete 50')" ""
argv_row "an empty BISYNC_ARGS passes no extra flags at all" \
    "bisync $CAP_REMOTE $CAP/local --log-level INFO --log-file $CAP/sync.log --max-delete 50" \
    'BISYNC_ARGS=""'
argv_row "a BISYNC_ARGS that is set is used as written, nothing added" \
    "bisync $CAP_REMOTE $CAP/local --resilient --stats 5s --log-level INFO --log-file $CAP/sync.log --max-delete 50" \
    'BISYNC_ARGS="--resilient --stats 5s"'
argv_row "CHECK_ACCESS=1 adds the flag and leaves RCLONE_TEST alone" \
    "$(argv_line "$CAP/local" '--max-delete 50 --check-access')" \
    'CHECK_ACCESS="1"'
argv_row "CHECK_ACCESS=1 with a CHECK_FILENAME adds the name as well" \
    "$(argv_line "$CAP/local" '--max-delete 50 --check-access --check-filename .sync-id')" \
    'CHECK_ACCESS="1"
CHECK_FILENAME=".sync-id"'
argv_row "--dry-run is forwarded and changes nothing else" \
    "$(argv_line "$CAP/local" '--max-delete 50 --dry-run')" "" --dry-run
# rclone refuses -v together with --log-level, so --verbose drops the level and
# keeps only the log file. Pinned here because the flag used to fail every
# attempt of the run.
argv_row "--verbose is forwarded, and replaces --log-level" \
    "bisync $CAP_REMOTE $CAP/local $DEF_ARGS --log-file $CAP/sync.log --max-delete 50 --verbose" \
    "" --verbose
# rclone's check is on the verbose flag, not on its spelling, and BISYNC_ARGS is
# the way a short one reaches the command line.
argv_row "-v in BISYNC_ARGS also replaces --log-level" \
    "bisync $CAP_REMOTE $CAP/local -v --log-file $CAP/sync.log --max-delete 50" \
    'BISYNC_ARGS="-v"'
argv_row "a short cluster holding a v counts as verbose too" \
    "bisync $CAP_REMOTE $CAP/local -Pv --log-file $CAP/sync.log --max-delete 50" \
    'BISYNC_ARGS="-Pv"'
# The wrapper's own arguments asked the same question as the loop above and used
# to answer it differently: -v was refused as an unknown option while BISYNC_ARGS
# holding the same thing was treated as verbose.
argv_row "-v on the command line is accepted and forwarded" \
    "bisync $CAP_REMOTE $CAP/local $DEF_ARGS --log-file $CAP/sync.log --max-delete 50 -v" \
    "" -v
argv_row "-vv on the command line is accepted too" \
    "bisync $CAP_REMOTE $CAP/local $DEF_ARGS --log-file $CAP/sync.log --max-delete 50 -vv" \
    "" -vv
run "an option that is not one of the documented ones is still refused" 2 "unknown option: -Z" \
    cap_env "$HOME/.local/bin/onedrive-sync" -Z

# BISYNC_ARGS is split on whitespace, so a quoted pattern is three words and one of
# them is a positional rclone refuses. That failure used to arrive as rclone's own
# usage text in the journal, every run, with the config key never named.
cap_config 'BISYNC_ARGS="--resilient --exclude \"/My Docs/**\""'
run "a quoted token in BISYNC_ARGS is refused with the key named" 1 \
    "BISYNC_ARGS holds a token that begins or ends with a quote" \
    cap_env "$HOME/.local/bin/onedrive-sync"
check "and the message says where a pattern with a space belongs" \
    grep -q "FILTERS_FILE" <<<"$(cap_env "$HOME/.local/bin/onedrive-sync" 2>&1)"
# An apostrophe inside a word is one word and works, so it must not be refused.
cap_config 'BISYNC_ARGS="--resilient --exclude=/home/o'\''brien/**"'
run "a quote inside a word is left alone" 0 "" \
    cap_env "$HOME/.local/bin/onedrive-sync"
# The numeric keys the wrapper refuses: without a case here, the only proof was
# the doctor's message about it.
cap_config 'RETRIES="0"'
run "RETRIES=0 stops the run and names the key" 1 "RETRIES='0' is not a positive integer" \
    cap_env "$HOME/.local/bin/onedrive-sync"
cap_config 'MAX_LOG_BYTES="5MB"'
run "MAX_LOG_BYTES with a unit suffix stops the run and names the key" 1 \
    "MAX_LOG_BYTES='5MB' is not a positive integer" \
    cap_env "$HOME/.local/bin/onedrive-sync"
cap_config
argv_row "--force is forwarded and the delete cap stays on the line" \
    "$(argv_line "$CAP/local" '--max-delete 50 --force')" "" --force
argv_row "--resync reaches rclone exactly once" \
    "$(argv_line "$CAP/local" '--max-delete 50 --resync')" "" --resync
argv_row "--force --resync both arrive, in that order, once each" \
    "$(argv_line "$CAP/local" '--max-delete 50 --force --resync')" "" --force --resync
# The keys the settings dialog and the installer write are read by the tray and
# by systemd, never by rclone, so a config full of them adds nothing here.
argv_row "the tray and scheduler keys never reach rclone" \
    "$(argv_line "$CAP/local" '--max-delete 50')" \
    'WATCH="1"
WATCH_DEBOUNCE="8"
INTERVAL_MIN="5"
UNIT_NAME="cap-unit"
UI_LANG="zh"
SHOW_ICON="1"'

# The rows rewrote the CAP config; the sections below want the plain one back.
cap_config

# ---------------------------------------------------------------- numeric keys
# A numeric key that is not a number used to fail in a way that hid itself:
# `seq 1 three` printed nothing, so the loop body never ran, rclone was never
# invoked, and the run ended on "all 0 attempts failed". MAX_LOG_BYTES="5MB" made
# the rotation comparison error out and skip the rotation in silence, and
# RETRY_DELAY="three" killed the sleep between two attempts. One line naming the
# key, the value and the config file replaces all three.
title "a numeric key that is not a number"
NUMKEY_CFG="$CAP/cfg/rclone-onedrive-tray/config"
for key in RETRIES RETRY_DELAY MAX_LOG_BYTES; do
    cap_config "$key=\"three\""
    : > "$WORK/cap-args"
    out="$(cap_env "$HOME/.local/bin/onedrive-sync" 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && grep -qF "$key='three'" <<<"$out" &&
            grep -qF "$NUMKEY_CFG" <<<"$out"; then
        ok "$key=three is refused, naming the key, the value and the file"
    else
        bad "$key=three: exit $rc, $(head -1 <<<"$out")"
    fi
    check "and $key=three never reached rclone" test ! -s "$WORK/cap-args"
done

# Absent and empty both keep the documented default, which is what an install
# that never had the key already gets.
cap_config 'RETRIES=""
RETRY_DELAY=""
MAX_LOG_BYTES=""'
: > "$WORK/cap-args"
run "an empty RETRIES, RETRY_DELAY and MAX_LOG_BYTES keep the defaults" 0 "" \
    cap_env "$HOME/.local/bin/onedrive-sync"
check "and that run still reached rclone once" \
    test "$(wc -l < "$WORK/cap-args")" -eq 1
cap_config

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

# rclone reads the pattern as a glob. A folder named "Photos [2024]" was handed
# over as a character class, matched nothing, and kept syncing while the tray
# reported it as left out; a name holding a "*" behaves the same way.
printf 'Photos [2024]\nstar*dir\n' > "$EXF"
args="$(probe_case "EXCLUDE_FOLDERS_FILE=\"$EXF\"")"
check "a name with a bracket is escaped, not read as a class" \
    grep -qF -- '--exclude /Photos [[]2024[]]/**' <<<"$args"
check "a name with a star is escaped too" \
    grep -qF -- '--exclude /star[*]dir/**' <<<"$args"

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
# What rclone 1.75.1 actually writes when the refresh token is refused: one line
# that matches the network patterns ("couldn't fetch token") and the auth ones
# ("invalid_grant") at the same time, captured here from a real run. Which table
# is asked first decides whether the user is told to wait for a retry or to sign
# in again.
CAP_AUTH_MIXED="2026/10/04 03:54:31 CRITICAL: Failed to create file system for \"onedrive:Vault\": failed to get root: Get \"https://graph.microsoft.com/v1.0/drives/b!/root\": couldn't fetch token: invalid_grant: maybe token expired? - try refreshing with \"rclone config reconnect onedrive:\""
run "a token fetch that never reached Microsoft is a network problem" 1 "[network]" \
    cap_env CAP_STDERR="$CAP_EOF" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"
run "a refused token is an expired sign-in, and says what to click" 1 "[auth]" \
    cap_env CAP_STDERR="$CAP_AUTH" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"
run "and the message names the tray item and the command" 1 "config reconnect" \
    cap_env CAP_STDERR="$CAP_AUTH" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"
run "rclone's own one-line refusal carries both phrases and is still an auth failure" 1 "[auth]" \
    cap_env CAP_STDERR="$CAP_AUTH_MIXED" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"

# ---------------------------------------------------------------- what is retried
# The retry loop spent the remaining attempts on every failure class, including
# the ones whose own hint says a rerun cannot help: two extra rclone invocations
# two minutes apart for a refused sign-in, an access-check abort, a tripped
# delete cap or an unknown rclone flag. The classifier that names the class is
# already there, so the loop can ask it.
title "retrying only the failures a rerun can clear"
RETRY_MAXDELETE='2026/01/01 00:00:00 ERROR : Safety abort: too many deletes (>50%, 150 of 200) on Path1'
RETRY_ACCESS='2026/01/01 00:00:00 ERROR : Access test failed: Path1 count 1, Path2 count 0 - RCLONE_TEST'
RETRY_OLD='Error: unknown flag: --resilient'

# retry_case <stderr> -- one run of three allowed attempts, DELAY one second.
# RETRY_COUNT is how many times rclone was invoked, RETRY_OUT its stderr.
retry_case() {
    cap_config 'RETRIES="3"
RETRY_DELAY="1"'
    : > "$WORK/cap-args"; : > "$CAP/sync.log"
    RETRY_OUT="$(cap_env CAP_STDERR="$1" CAP_RC=1 "$HOME/.local/bin/onedrive-sync" 2>&1)"
    RETRY_RC=$?
    RETRY_COUNT="$(wc -l < "$WORK/cap-args")"
}

retry_case "$CAP_EOF"
if [ "$RETRY_RC" -eq 1 ] && [ "$RETRY_COUNT" -eq 3 ]; then
    ok "a network failure is retried, all three attempts"
else
    bad "a network failure: exit $RETRY_RC after $RETRY_COUNT attempt(s)"
fi

retry_case "$CAP_AUTH"
if [ "$RETRY_RC" -eq 1 ] && [ "$RETRY_COUNT" -eq 1 ]; then
    ok "a refused sign-in is not retried"
else
    bad "a refused sign-in: exit $RETRY_RC after $RETRY_COUNT attempt(s)"
fi
retry_case "$CAP_AUTH_MIXED"
if [ "$RETRY_RC" -eq 1 ] && [ "$RETRY_COUNT" -eq 1 ]; then
    ok "and neither is the one-line refusal rclone writes, which also says network"
else
    bad "a one-line refusal: exit $RETRY_RC after $RETRY_COUNT attempt(s)"
fi
check "and the log says why the remaining attempts were dropped" \
    grep -qF "not retrying" "$CAP/sync.log"
if grep -qF "all 1 attempts failed" <<<"$RETRY_OUT"; then
    ok "and the closing line counts the attempts that were made, not the limit"
else
    bad "the closing line does not match the attempts made: $(tail -1 <<<"$RETRY_OUT")"
fi

retry_case "$RETRY_MAXDELETE"
check "a tripped delete cap is not retried" test "$RETRY_COUNT" -eq 1

retry_case "$RETRY_ACCESS"
check "an access-check abort is not retried" test "$RETRY_COUNT" -eq 1

retry_case "$RETRY_OLD"
check "an unknown rclone flag is not retried" test "$RETRY_COUNT" -eq 1

cap_config

# ------------------------------------------------- the help text and the flags
# Every script prints its own header comment as its help, extracted up to the
# first line that is not a comment. Two of them used a fixed line range instead,
# so their help ended with a line of bash. install.sh --prefix with nothing
# after it also died inside bash, naming a variable rather than the missing
# directory.
title "the help text, and a flag with no value"
for script in install.sh uninstall.sh setup.sh; do
    help_out="$(bash "$SRC_DIR/$script" --help 2>&1)"
    if grep -q '^set -' <<<"$help_out"; then
        bad "$script --help ends in shell code: $(grep '^set -' <<<"$help_out")"
    else
        ok "$script --help stops at the comment block"
    fi
done
run "onedrive-check-access --help says where the config is" 0 "Configuration:" \
    "$SRC_DIR/bin/onedrive-check-access" --help
run "install.sh --prefix with no value says what is missing" 1 \
    "--prefix needs a directory" bash "$SRC_DIR/install.sh" --prefix

# ------------------------------------------------------------ --resync anywhere
# --resync used to be read from the first position only, so the same run with
# its flags the other way round skipped the name check and left no NOTICE.
title "--resync in any position"
cap_config
: > "$WORK/cap-args"
: > "$CAP/sync.log"
cap_env "$HOME/.local/bin/onedrive-sync" --force --resync >/dev/null 2>&1 || true
resync_count="$(tr ' ' '\n' < "$WORK/cap-args" | grep -c '^--resync$' || true)"
if [ "$resync_count" = 1 ] && grep -q 'NOTICE: --resync requested' "$CAP/sync.log"; then
    ok "--force --resync checks the names, and --resync reaches rclone once"
else
    bad "--force --resync: $resync_count --resync on the command line, NOTICE $(grep -c 'NOTICE: --resync requested' "$CAP/sync.log" || true)"
fi

# ---------------------------------------------------------------- the doctor
# A sync that breaks is first taken to onedrive-doctor, so the diagnostic gets
# its own sandbox here: a fixture tree, stubs for rclone and systemctl, and a
# PATH assembled from symlinks so that a missing tool is really missing. One
# assertion per case.
title "onedrive-doctor"
DOCTOR_BIN="$HOME/.local/bin/onedrive-doctor"
DOC="$WORK/doctor"
DOC_STUBS="$WORK/doctor-stubs"
DOC_TOOLS="$WORK/doctor-tools"
DOC_NOFLOCK="$WORK/doctor-tools-noflock"
DOC_PATH_OVERRIDE=""
DOC_TIMER_ENABLED="enabled"
DOC_TIMER_ACTIVE="active"
mkdir -p "$DOC_STUBS" "$DOC_TOOLS" "$DOC_NOFLOCK"

# Every tool the doctor may call, symlinked so a case can cut one of them out.
# bash is in the list because the shebang looks it up through this PATH.
for tool in bash sed grep head cut tail date stat mktemp tr timeout flock pgrep \
            rm dirname basename sort cat; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$tool_path" ] || continue
    ln -sf "$tool_path" "$DOC_TOOLS/$tool"
    [ "$tool" = flock ] || ln -sf "$tool_path" "$DOC_NOFLOCK/$tool"
done

cat > "$DOC_STUBS/rclone" <<'STUB'
#!/bin/bash
case "$1" in
    version) echo "rclone v1.75.1" ;;
    lsd)
        # DOC_LSD_RC and DOC_LSD_ERR drive the remote probe: 1 with a network
        # error or an invalid_grant, 124 for the branch a real timeout reaches.
        if [ "${DOC_LSD_RC:-0}" = 0 ]; then
            echo "          -1 2026-01-01 00:00:00        -1 Notes"
        else
            [ -n "${DOC_LSD_ERR:-}" ] && printf '%s\n' "$DOC_LSD_ERR" >&2
        fi
        exit "${DOC_LSD_RC:-0}" ;;
    *)       : ;;
esac
exit 0
STUB
cat > "$DOC_STUBS/systemctl" <<'STUB'
#!/bin/bash
case "$*" in
    *"show -p FragmentPath"*) echo "/run/user/1000/systemd/user/docsync.timer" ;;
    # The watcher has its own state, so the WATCH=0 case can be exercised: the
    # generic patterns below answer for the timer alone.
    *"is-enabled "*watch.service*) echo "${DOC_WATCH_ENABLED:-disabled}" ;;
    *"is-active "*watch.service*)  echo "${DOC_WATCH_ACTIVE:-inactive}" ;;
    *"is-enabled "*) echo "${DOC_TIMER_ENABLED:-enabled}" ;;
    *"is-active "*)  echo "${DOC_TIMER_ACTIVE:-active}" ;;
    *"show -p NextElapseUSecMonotonic"*) echo "12min 3s" ;;
    *"show -p Result"*) echo "success" ;;
esac
exit 0
STUB
chmod +x "$DOC_STUBS/rclone" "$DOC_STUBS/systemctl"
# The tray check asks pgrep for onedrive-tray, and no fixture ever had one, so
# its "running (pid ...)" line was never printed. This stub answers only when a
# case sets DOC_TRAY_PID, which leaves every other fixture's tray verdict alone.
#
# It matches the way pgrep does, with an unanchored ERE over the command line,
# because the pattern is what decides whether a log tail whose path holds the
# name is read as a tray. DOC_TRAY_CMDS is a newline-separated list of command
# lines the case wants to exist; each match is answered with a pid counting up
# from 8001, so a case can tell which of them the doctor settled on.
cat > "$DOC_STUBS/pgrep" <<'STUB'
#!/bin/bash
pattern=""
for arg in "$@"; do pattern="$arg"; done
if [ -n "${DOC_TRAY_CMDS:-}" ]; then
    pid=8000
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        pid=$((pid + 1))
        if [[ "$line" =~ $pattern ]]; then printf '%s\n' "$pid"; fi
    done <<<"$DOC_TRAY_CMDS"
    exit 0
fi
[ -n "${DOC_TRAY_PID:-}" ] && printf '%s\n' "$DOC_TRAY_PID"
exit 0
STUB
chmod +x "$DOC_STUBS/pgrep"
DOCTOR_TMP="$WORK/doctor-tmp"
mkdir -p "$DOCTOR_TMP"

doc_slug() { printf '%s' "$1" | sed -e 's|^/||' -e 's|[/: ]|_|g'; }

# doc_fixture <name> [extra config lines] -- build the sandbox and point DOC_FX
# at it. The log starts with one clean line, so a case that wants a failure hint
# appends its own.
doc_fixture() {
    local d="$DOC/$1" extra="${2:-}"
    mkdir -p "$d/home" "$d/cfg/rclone-onedrive-tray" "$d/cache/rclone/bisync" \
             "$d/cache/rclone-onedrive-tray" "$d/data/rclone-onedrive-tray/icons" \
             "$d/local" "$d/bin" "$d/tmp"
    printf '*.tmp\n' > "$d/cfg/rclone-onedrive-tray/filters.txt"
    cp "$DOC_STUBS/rclone" "$DOC_STUBS/systemctl" "$DOC_STUBS/pgrep" "$d/bin/"
    chmod +x "$d/bin/rclone" "$d/bin/systemctl" "$d/bin/pgrep"
    cat > "$d/cfg/rclone-onedrive-tray/config" <<EOF
REMOTE="docfake:Vault"
LOCAL="$d/local"
UNIT_NAME="docsync"
LOG="$d/cache/sync.log"
FILTERS_FILE="$d/cfg/rclone-onedrive-tray/filters.txt"
WATCH="0"
$extra
EOF
    printf '%s INFO  : Bisync successful\n' "$(date '+%Y/%m/%d %H:%M:%S')" > "$d/cache/sync.log"
    printf '# bisync listing v1\n' > \
        "$d/cache/rclone/bisync/docfake_Vault..$(doc_slug "$d/local").path1.lst"
    DOC_FX="$d"
}

# doc_run <fixture> [doctor arguments...] -- the TMPDIR is inside the fixture so
# the read-only case below would notice a temporary file left behind.
doc_run() {
    local d="$1"; shift
    local path="$d/bin:$DOC_TOOLS"
    [ -n "$DOC_PATH_OVERRIDE" ] && path="$DOC_PATH_OVERRIDE"
    env HOME="$d/home" XDG_CONFIG_HOME="$d/cfg" XDG_CACHE_HOME="$d/cache" \
        XDG_DATA_HOME="$d/data" TMPDIR="$d/tmp" PATH="$path" \
        DOC_TIMER_ENABLED="$DOC_TIMER_ENABLED" DOC_TIMER_ACTIVE="$DOC_TIMER_ACTIVE" \
        DOC_WATCH_ENABLED="${DOC_WATCH_ENABLED:-disabled}" \
        DOC_WATCH_ACTIVE="${DOC_WATCH_ACTIVE:-inactive}" \
        DOC_LSD_RC="${DOC_LSD_RC:-0}" DOC_LSD_ERR="${DOC_LSD_ERR:-}" \
        DOC_TRAY_PID="${DOC_TRAY_PID:-}" \
        DOC_TRAY_CMDS="${DOC_TRAY_CMDS:-}" \
        "$DOCTOR_BIN" "$@"
}

# A healthy fixture: exit 0, every check line carrying a verdict, and a summary
# that says nothing failed. The lines that do not carry one are the header and
# the summary itself.
DOC_PATH_OVERRIDE=""; DOC_TIMER_ENABLED="enabled"; DOC_TIMER_ACTIVE="active"
doc_fixture healthy
DOCTOR_OUT="$(doc_run "$DOC_FX" 2>&1)"; DOCTOR_RC=$?
DOCTOR_BARE="$(printf '%s\n' "$DOCTOR_OUT" | grep -cvE '^(ok|warn|fail) |^onedrive-doctor: ' || true)"
if [ "$DOCTOR_RC" -eq 0 ] && grep -q "nothing failed" <<<"$DOCTOR_OUT" &&
        [ "$DOCTOR_BARE" -eq 0 ]; then
    ok "a healthy fixture: exit 0, one verdict line per check, nothing failed"
else
    bad "a healthy fixture: exit $DOCTOR_RC, $DOCTOR_BARE line(s) without a verdict"
    printf '%s\n' "$DOCTOR_OUT" | head -3 | sed 's/^/        /'
fi

# The ok line for a config that sources cleanly names the file and the two keys
# every check after it depends on. Replacing that message with another string
# left the case above passing, because only the exit status and the shape of the
# line are looked at there.
run "a clean config: the ok line names the file and both keys" 0 \
    "$DOC_FX/cfg/rclone-onedrive-tray/config sets REMOTE and LOCAL" \
    doc_run "$DOC_FX" --offline

# The tray check prints its one distinctive line only when pgrep finds a tray,
# and no fixture ever had one, so the line could be replaced with anything. The
# stub pgrep answers for this case alone, through DOC_TRAY_PID.
doc_fixture tray-running
DOC_TRAY_PID=8123
run "a running tray: the ok line names the pid and the icon directory" 0 \
    "running (pid 8123), icons in $DOC_FX/data/rclone-onedrive-tray/icons" \
    doc_run "$DOC_FX" --offline
DOC_TRAY_PID=""

# The tray check reads the whole command line, so the pattern decides whether the
# log tail this project's own documentation tells a user to run is mistaken for a
# tray. Both command lines are offered to the stub at once: only the second is a
# tray, and the pid it answers for is what says which one was found.
title "the tray probe finds a tray, not its name in any command line"
doc_fixture tray-or-tail
DOC_TRAY_CMDS='tail -f /home/u/.cache/rclone-onedrive-tray/sync.log
python3 /home/u/.local/bin/onedrive-tray'
run "the log tail is skipped and the tray behind it is the one reported" 0 \
    "running (pid 8002), icons in $DOC_FX/data/rclone-onedrive-tray/icons" \
    doc_run "$DOC_FX" --offline
DOC_TRAY_CMDS='tail -f /home/u/.cache/rclone-onedrive-tray/sync.log'
run "and a tail on its own is not a tray" 0 "no tray process" \
    doc_run "$DOC_FX" --offline
DOC_TRAY_CMDS=""

# The three keys onedrive-sync runs require_positive_int on. A value it refuses
# stops every scheduled run before rclone starts.
doc_fixture bad-retries 'RETRIES="0"'
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q "fail config" <<<"$DOCTOR_OUT" &&
        grep -q "RETRIES" <<<"$DOCTOR_OUT"; then
    ok "a RETRIES onedrive-sync refuses is a failed check, not a healthy config"
else
    bad "RETRIES=0: exit $DOCTOR_RC, $(grep -m1 config <<<"$DOCTOR_OUT")"
fi

# The log file is removed here on purpose: the check used to sit behind
# "does the log exist", so a key it refuses was invisible on a machine that had
# never synced, which is exactly when a fresh install gets it wrong.
doc_fixture bad-max-log 'MAX_LOG_BYTES="5MB"'
rm -f "$DOC_FX/cache/sync.log"
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q "MAX_LOG_BYTES" <<<"$DOCTOR_OUT"; then
    ok "a MAX_LOG_BYTES the wrapper refuses fails even with no log to look at"
else
    bad "MAX_LOG_BYTES=5MB without a log: exit $DOCTOR_RC, $(grep -m1 config <<<"$DOCTOR_OUT")"
fi

# And the other side: a config that does not mention the three keys at all is
# healthy, because the wrapper's own defaults apply. The healthy fixture at the
# top of this section is that case, so this one only pins the message.
doc_fixture bad-retry-delay 'RETRY_DELAY="60s"'
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q "RETRY_DELAY" <<<"$DOCTOR_OUT"; then
    ok "RETRY_DELAY with a unit suffix is refused too, and named"
else
    bad "RETRY_DELAY=60s: exit $DOCTOR_RC, $(grep -m1 config <<<"$DOCTOR_OUT")"
fi

doc_fixture no-config
rm -f "$DOC_FX/cfg/rclone-onedrive-tray/config"
run "no config: exit 1, and the line names the path it looked for" 1 \
    "$DOC_FX/cfg/rclone-onedrive-tray/config" doc_run "$DOC_FX" --quiet --offline

DOC_PATH_OVERRIDE="$DOC_TOOLS"
run "no rclone on PATH: exit 1, and the line names rclone" 1 "rclone is not on PATH" \
    doc_run "$DOC_FX" --quiet --offline

DOC_PATH_OVERRIDE="$DOC_FX/bin:$DOC_NOFLOCK"
run "no flock on PATH: exit 1" 1 "flock is missing" \
    doc_run "$DOC_FX" --quiet --offline
DOC_PATH_OVERRIDE=""

doc_fixture expired-signin
cat >> "$DOC_FX/cache/sync.log" <<'EOF'
2026/10/01 20:05:00 CRITICAL: Failed to refresh token: oauth2: cannot fetch token: 400 Bad Request: {"error":"invalid_grant","error_description":"AADSTS70043: The refresh token has expired"}
EOF
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q "expired sign-in" <<<"$DOCTOR_OUT" &&
        ! grep -q "network" <<<"$DOCTOR_OUT"; then
    ok "a log ending in invalid_grant is an expired sign-in, never a network problem"
else
    bad "invalid_grant: exit $DOCTOR_RC, $(head -1 <<<"$DOCTOR_OUT")"
fi

doc_fixture token-eof
cat >> "$DOC_FX/cache/sync.log" <<'EOF'
2026/10/01 20:05:00 CRITICAL: failed to get root: Get "https://graph.microsoft.com/v1.0/drives/X/root": couldn't fetch token: Post "https://login.microsoftonline.com/common/oauth2/v2.0/token": EOF
EOF
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 0 ] && grep -q "network problem" <<<"$DOCTOR_OUT" &&
        ! grep -q "expired" <<<"$DOCTOR_OUT"; then
    ok "a token fetch that never reached Microsoft is a network problem, not an expiry"
else
    bad "token EOF: exit $DOCTOR_RC, $(head -1 <<<"$DOCTOR_OUT")"
fi

# The shape rclone 1.75.1 really writes, one line carrying a network phrase and an
# auth marker. The tables are asked in an order, so the order is what decides
# whether the user is told the sign-in is not the problem.
doc_fixture mixed-signin
cat >> "$DOC_FX/cache/sync.log" <<'EOF'
2026/10/04 03:54:31 CRITICAL: Failed to create file system for "docfake:Vault": failed to get root: Get "https://graph.microsoft.com/v1.0/drives/b!/root": couldn't fetch token: invalid_grant: maybe token expired? - try refreshing with "rclone config reconnect docfake:"
EOF
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q "expired sign-in" <<<"$DOCTOR_OUT" &&
        ! grep -q "a network problem" <<<"$DOCTOR_OUT"; then
    ok "rclone's one-line refusal is an expired sign-in, not a network problem"
else
    bad "one-line refusal: exit $DOCTOR_RC, $(head -1 <<<"$DOCTOR_OUT")"
fi

# A network blip lands on top of the refusal that is the actual reason nothing
# syncs. Only reading the newest hint reported the blip, which clears itself, and
# said nothing about the sign-in, which does not.
doc_fixture signin-behind-network
cat >> "$DOC_FX/cache/sync.log" <<'EOF'
2026/10/01 20:05:00 CRITICAL: Failed to refresh token: oauth2: cannot fetch token: 400 Bad Request: {"error":"invalid_grant","error_description":"AADSTS70043: The refresh token has expired"}
2026/10/01 20:10:00 ERROR: failed to get root: Post "https://login.microsoftonline.com/common/oauth2/v2.0/token": EOF
EOF
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q "expired sign-in" <<<"$DOCTOR_OUT" &&
        ! grep -q "a network problem" <<<"$DOCTOR_OUT"; then
    ok "a refused sign-in is still reported when a newer network error hides it"
else
    bad "sign-in behind a network error: exit $DOCTOR_RC, $(head -1 <<<"$DOCTOR_OUT")"
fi
# The same log with a successful run after the refusal: the sign-in worked, so a
# case that keeps reporting it would send the user to reconnect a working remote.
doc_fixture signin-then-recovered
cat >> "$DOC_FX/cache/sync.log" <<'EOF'
2026/10/01 20:05:00 CRITICAL: Failed to refresh token: oauth2: cannot fetch token: 400 Bad Request: {"error":"invalid_grant","error_description":"AADSTS70043: The refresh token has expired"}
2026/10/01 21:00:00 INFO  : Bisync successful
EOF
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 0 ] && ! grep -q "expired sign-in" <<<"$DOCTOR_OUT"; then
    ok "a sign-in refusal a later run synced past is not reported as a live fault"
else
    bad "sign-in then recovered: exit $DOCTOR_RC, $(head -1 <<<"$DOCTOR_OUT")"
fi
# And the boundary: a cleared refusal must not come back when a network error
# follows the success. The refusal is older than the last run that worked, so the
# network hint is the one to report, even though it is not the only hint around.
doc_fixture signin-cleared-then-network
cat >> "$DOC_FX/cache/sync.log" <<'EOF'
2026/10/01 20:05:00 CRITICAL: Failed to refresh token: oauth2: cannot fetch token: 400 Bad Request: {"error":"invalid_grant","error_description":"AADSTS70043: The refresh token has expired"}
2026/10/01 21:00:00 INFO  : Bisync successful
2026/10/01 22:00:00 ERROR: failed to get root: Post "https://login.microsoftonline.com/common/oauth2/v2.0/token": EOF
EOF
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 0 ] && grep -q "a network problem" <<<"$DOCTOR_OUT" &&
        ! grep -q "expired sign-in" <<<"$DOCTOR_OUT"; then
    ok "a cleared refusal stays cleared when a later network error follows it"
else
    bad "cleared then network: exit $DOCTOR_RC, $(head -1 <<<"$DOCTOR_OUT")"
fi

doc_fixture timer-off
DOC_TIMER_ENABLED="disabled"
run "a disabled timer is a warning, and the run still exits 0" 0 "is disabled" \
    doc_run "$DOC_FX" --quiet --offline
DOC_TIMER_ENABLED="enabled"

# WATCH=0 used to be reported ok without asking systemd, so a watcher unit left
# running by an earlier WATCH=1 install kept starting syncs while the tool built
# to find that called it healthy.
doc_fixture watch-off-but-running 'WATCH="0"'
DOC_WATCH_ENABLED="enabled"; DOC_WATCH_ACTIVE="active"
run "a watcher left running while WATCH is off is a warning naming the command" 0 \
    "systemctl --user disable --now docsync-watch.service" \
    doc_run "$DOC_FX" --quiet --offline
DOC_WATCH_ENABLED=""; DOC_WATCH_ACTIVE=""

doc_fixture quiet
DOCTOR_FULL="$(doc_run "$DOC_FX" --offline 2>&1)"
DOCTOR_QUIET="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"
DOCTOR_FULL_OK="$(printf '%s\n' "$DOCTOR_FULL" | grep -c '^ok ' || true)"
DOCTOR_QUIET_OK="$(printf '%s\n' "$DOCTOR_QUIET" | grep -c '^ok ' || true)"
DOCTOR_COUNTED="$(printf '%s\n' "$DOCTOR_QUIET" |
    sed -n 's/^onedrive-doctor: \([0-9]*\) ok.*/\1/p')"
if [ "$DOCTOR_QUIET_OK" -eq 0 ] && [ -n "$DOCTOR_COUNTED" ] &&
        [ "$DOCTOR_COUNTED" = "$DOCTOR_FULL_OK" ] && [ "$DOCTOR_FULL_OK" -gt 0 ]; then
    ok "--quiet hides every ok line, and the summary still counts them"
else
    bad "--quiet: $DOCTOR_QUIET_OK ok line(s) printed, summary '$DOCTOR_COUNTED', full run $DOCTOR_FULL_OK"
fi

run "the doctor --help documents --offline" 0 "--offline" "$DOCTOR_BIN" --help

DOCTOR_OUT="$("$DOCTOR_BIN" --bogus 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 2 ] && grep -q '^usage:' <<<"$DOCTOR_OUT" &&
        [ "$(grep -c '' <<<"$DOCTOR_OUT")" -eq 1 ]; then
    ok "an unknown flag exits 2 with one usage line"
else
    bad "unknown flag: exit $DOCTOR_RC, $(head -1 <<<"$DOCTOR_OUT")"
fi

# The wrapper stops before it syncs when its log cannot be opened, so the doctor
# reports that as a failure. Flipping that verdict to ok went unnoticed, because
# no fixture ever made the log unwritable: the message, unlike the verdict, is
# the same either way.
doc_fixture unwritable-log
chmod 0444 "$DOC_FX/cache/sync.log"
run "an unwritable log is a failure, not an ok" 1 "fail logfile" \
    doc_run "$DOC_FX" --quiet --offline

# The whole point of the script is that it is safe to run at any time, so the
# tree, the config's contents and the config's mtime are compared around a run.
doc_fixture read-only
find "$DOC_FX" -printf '%P %s\n' | sort > "$WORK/doctor-tree-before"
DOCTOR_SUM_BEFORE="$(md5sum < "$DOC_FX/cfg/rclone-onedrive-tray/config")"
DOCTOR_MTIME_BEFORE="$(stat -c %Y "$DOC_FX/cfg/rclone-onedrive-tray/config")"
doc_run "$DOC_FX" --offline >/dev/null 2>&1
find "$DOC_FX" -printf '%P %s\n' | sort > "$WORK/doctor-tree-after"
DOCTOR_SUM_AFTER="$(md5sum < "$DOC_FX/cfg/rclone-onedrive-tray/config")"
DOCTOR_MTIME_AFTER="$(stat -c %Y "$DOC_FX/cfg/rclone-onedrive-tray/config")"
if [ "$DOCTOR_SUM_BEFORE" = "$DOCTOR_SUM_AFTER" ] &&
        [ "$DOCTOR_MTIME_BEFORE" = "$DOCTOR_MTIME_AFTER" ] &&
        cmp -s "$WORK/doctor-tree-before" "$WORK/doctor-tree-after"; then
    ok "a run leaves the config and every file in the tree untouched"
else
    bad "the doctor changed the sandbox"
    diff "$WORK/doctor-tree-before" "$WORK/doctor-tree-after" | head -5 | sed 's/^/        /'
fi

# ---------------------------------------------------------------- the remote probe
# Every doctor case above passes --offline, so the one check that leaves the
# machine had never run under test. Its verdicts follow the exit contract in the
# script's header: a network problem and a timeout are warnings, because the next
# run retries them, while a refused sign-in is a failure because it needs a
# person. The stub rclone answers the probe here, driven by DOC_LSD_RC and
# DOC_LSD_ERR.
title "the doctor's remote probe"
doc_fixture remote-probe
DOC_LSD_RC=0; DOC_LSD_ERR=""
DOCTOR_OUT="$(doc_run "$DOC_FX" 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 0 ] && grep -q '^ok   remote ' <<<"$DOCTOR_OUT"; then
    ok "a remote that answers is ok, and the run exits 0"
else
    bad "a remote that answers: exit $DOCTOR_RC, $(grep ' remote ' <<<"$DOCTOR_OUT" | head -1)"
fi

DOC_LSD_RC=1
DOC_LSD_ERR='2026/10/01 20:05:00 CRITICAL: failed to get root: Get "https://graph.microsoft.com/v1.0/drives/X/root": dial tcp 1.2.3.4:443: connect: network is unreachable'
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 0 ] && grep -q '^warn remote .*network problem' <<<"$DOCTOR_OUT"; then
    ok "an unreachable remote is a warning, so an offline laptop still exits 0"
else
    bad "unreachable remote: exit $DOCTOR_RC, $(grep ' remote ' <<<"$DOCTOR_OUT" | head -1)"
fi

DOC_LSD_RC=124; DOC_LSD_ERR=""
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 0 ] && grep -q '^warn remote .*did not answer within 20s' <<<"$DOCTOR_OUT"; then
    ok "a probe that times out is a warning too, not a failure"
else
    bad "timed-out probe: exit $DOCTOR_RC, $(grep ' remote ' <<<"$DOCTOR_OUT" | head -1)"
fi

DOC_LSD_RC=1
DOC_LSD_ERR='2026/10/01 20:05:00 CRITICAL: Failed to refresh token: oauth2: cannot fetch token: 400 Bad Request: {"error":"invalid_grant","error_description":"AADSTS70043: The refresh token has expired"}'
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q '^fail remote .*refused the sign-in' <<<"$DOCTOR_OUT"; then
    ok "a refused sign-in is a failure, because no rerun fixes it"
else
    bad "refused sign-in: exit $DOCTOR_RC, $(grep ' remote ' <<<"$DOCTOR_OUT" | head -1)"
fi

# The wrapper refuses to run with a MAX_LOG_BYTES that is not a positive integer,
# so the doctor has to say that rather than that the rotation is skipped. It used
# to say it on the logfile line and exit 0, which reads as "nothing failed" while
# nothing could sync; the config check fails on the same value now.
doc_fixture bad-max-log-bytes 'MAX_LOG_BYTES="5MB"'
DOC_LSD_RC=0; DOC_LSD_ERR=""
run "a MAX_LOG_BYTES the wrapper refuses is a failure, named as such" 1 \
    "onedrive-sync refuses to run" \
    doc_run "$DOC_FX" --quiet
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet 2>&1)"
check "and the logfile line still says what to put there instead" \
    grep -q "give it a byte count" <<<"$DOCTOR_OUT"
check "and the config line names the key, not only the value" \
    grep -q "^fail config.*MAX_LOG_BYTES" <<<"$DOCTOR_OUT"

# A remote name that is not set and an rclone that is not on PATH both stay
# failures: neither is something the next run changes.
doc_fixture no-remote 'REMOTE=""'
DOC_LSD_RC=0; DOC_LSD_ERR=""
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q '^fail remote.*REMOTE is not set' <<<"$DOCTOR_OUT"; then
    ok "an unset REMOTE fails the probe without contacting anything"
else
    bad "unset REMOTE: exit $DOCTOR_RC, $(grep ' remote ' <<<"$DOCTOR_OUT" | head -1)"
fi

doc_fixture no-rclone-probe
DOC_PATH_OVERRIDE="$DOC_TOOLS"
run "a missing rclone fails the probe as well as the version check" 1 \
    "rclone is not on PATH, so the remote cannot be probed" \
    doc_run "$DOC_FX" --quiet
DOC_PATH_OVERRIDE=""

# ---------------------------------------------------------------- uninstall
title "uninstall.sh"
# The tray stores the sync interval in <unit>.timer.d/interval.conf, and
# install.sh deliberately keeps an existing drop-in. Left behind by uninstall it
# makes the next install of the same unit name inherit the old interval.
mkdir -p "$UNIT_DIR/$UNIT.timer.d"
printf '[Timer]\nOnUnitInactiveSec=42min\n' > "$UNIT_DIR/$UNIT.timer.d/interval.conf"

# A unit pair left behind by an earlier UNIT_NAME. It fires on its own schedule
# at a script this run deletes, so the uninstaller has to turn it off rather than
# leave it running until somebody notices.
STALE="zz-stale-probe"
printf '[Unit]\nDescription=old install\n[Service]\nExecStart=%s/onedrive-sync\n' \
    "$HOME/.local/bin" > "$UNIT_DIR/$STALE.service"
printf '[Unit]\nDescription=old install\n[Timer]\nOnUnitInactiveSec=5min\n' \
    > "$UNIT_DIR/$STALE.timer"
# The stub above records `start` calls for the watcher case; from here on what it
# records is the systemctl this run asks for, so start it empty.
: > "$SYSTEMCTL_CALLS"
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
    "$HOME/.local/bin/onedrive-check-access" "$HOME/.local/bin/onedrive-doctor"
check_absent "removes the units" \
    "$UNIT_DIR/$UNIT.service" "$UNIT_DIR/$UNIT.timer" "$UNIT_DIR/$UNIT-watch.service"
check_absent "removes a unit pair left by an earlier name" \
    "$UNIT_DIR/$STALE.service" "$UNIT_DIR/$STALE.timer"
# The watcher half is a long-lived process: taking its unit file away while it
# is still enabled leaves systemd restarting a script this run has just deleted,
# so the uninstaller has to turn both halves of the pair off.
check "turns off the stale pair's watcher as well as its timer" \
    grep -qF -- "disable --now $STALE-watch.service" "$SYSTEMCTL_CALLS"
check "and says which one it was" \
    grep -qF "left by another name: $STALE" <<<"$UNINSTALL_OUT"
check_absent "removes the timer interval drop-in with the units" \
    "$UNIT_DIR/$UNIT.timer.d" "$UNIT_DIR/$UNIT.timer.d/interval.conf"
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

# --purge is the documented way to take the configuration with it, so the config
# directory has to go. The cache (the log, the wrapper lock, the tray's
# paused-until stamp) is a separate directory and stays.
PURGE_OUT="$(bash "$SRC_DIR/uninstall.sh" --prefix "$HOME/.local" --purge 2>&1)"
PURGE_RC=$?
if [ "$PURGE_RC" -eq 0 ]; then
    ok "a --purge run finishes"
else
    bad "--purge exits $PURGE_RC"
    printf '%s\n' "$PURGE_OUT" | head -3 | sed 's/^/        /'
fi
check_absent "--purge removes the configuration directory" "$CFG_DIR"
# The cache holds the log, the lock and the pause stamp: state that describes the
# install being removed rather than the user's data.
check_absent "--purge removes the cache directory" "$XDG_CACHE_HOME/rclone-onedrive-tray"

# The help promised "the configuration and filters" while the run also took the
# cache and the icon directory, and the final message has to list what it took.
# A plain run against a directory that is already gone said "configuration kept"
# about nothing.
run "the --purge help lists everything it removes" 0 "icon directory" \
    bash "$SRC_DIR/uninstall.sh" --help
if grep -qF 'removed' <<<"$PURGE_OUT" && grep -qF 'icon directory' <<<"$PURGE_OUT" &&
        grep -qF 'pause stamp' <<<"$PURGE_OUT"; then
    ok "and a --purge run says what it removed, cache and icons included"
else
    bad "the --purge run does not list what it removed"
    printf '%s\n' "$PURGE_OUT" | tail -4 | sed 's/^/        /'
fi
run "an uninstall with nothing left to keep says so" 0 "nothing to remove" \
    bash "$SRC_DIR/uninstall.sh" --prefix "$HOME/.local"

summary
