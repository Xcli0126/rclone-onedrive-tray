#!/usr/bin/env bash
#
# Uninstaller for rclone-onedrive-tray.
#
#   ./uninstall.sh                 remove programs, units (including the timer's
#                                  interval drop-in) and the autostart entry
#   ./uninstall.sh --prefix DIR    match a non-default install prefix
#   ./uninstall.sh --purge         also remove the configuration and the filters,
#                                  the cache (the log, the lock, the pause stamp)
#                                  and the icon directory
#
# Your synced folder, the rclone remote config, and any conflict/backup files
# bisync created are never touched.
#
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
PURGE=0
PREFIX_GIVEN=0

# The help is this file's header comment, up to the first line that is not a
# comment, so it cannot go stale when the block changes size.
usage() { sed -n '2,/^[^#]/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)   PREFIX="${2:?--prefix needs a directory}"; PREFIX_GIVEN=1; shift 2 ;;
        --purge)    PURGE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

BIN_DIR="$PREFIX/bin"
CONFIG_DIR="$XDG_CONFIG/rclone-onedrive-tray"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rclone-onedrive-tray"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/rclone-onedrive-tray"
UNIT_DIR="$XDG_CONFIG/systemd/user"
AUTOSTART="$XDG_CONFIG/autostart/rclone-onedrive-tray.desktop"
# The NetworkManager hook is one machine-wide file. Its directory is overridable
# the way install.sh's is, so a test can point both at a sandbox hook instead of
# reaching for /etc.
NM_DISPATCHER_DIR="${NM_DISPATCHER_DIR:-/etc/NetworkManager/dispatcher.d}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

# Recover the unit base name from the config (may differ from the default).
UNIT_NAME="onedrive-sync"
if [ -f "$CONFIG_DIR/config" ]; then
    parsed="$(sed -n 's/^[[:space:]]*UNIT_NAME="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' \
              "$CONFIG_DIR/config" | tail -1)"
    if [ -n "$parsed" ]; then
        UNIT_NAME="$parsed"
    fi
fi

say "Stopping tray icon and watcher"
# Match the exact interpreter+path so no unrelated process is ever signalled.
pkill -x -f "python3 $BIN_DIR/onedrive-tray" 2>/dev/null || true
pkill -x -f "bash $BIN_DIR/onedrive-watch" 2>/dev/null || true

if systemctl --user show-environment >/dev/null 2>&1; then
    say "Disabling $UNIT_NAME units"
    systemctl --user disable --now "$UNIT_NAME.timer" 2>/dev/null || true
    systemctl --user disable --now "$UNIT_NAME-watch.service" 2>/dev/null || true
else
    warn "no user systemd session; skipping unit teardown"
fi

say "Removing files"
rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer"
rm -f "$UNIT_DIR/$UNIT_NAME-watch.service"
# The tray stores the sync interval in a drop-in beside the timer, and install.sh
# keeps an existing one on purpose. Left behind, it silently hands its interval to
# the next install of the same unit name, so it goes with the units it overrides.
rm -rf "$UNIT_DIR/$UNIT_NAME.timer.d"
rm -f "$AUTOSTART"
rm -f "$BIN_DIR/onedrive-sync" "$BIN_DIR/onedrive-tray" "$BIN_DIR/onedrive-watch"
rm -f "$BIN_DIR/onedrive-check"
rm -f "$BIN_DIR/onedrive-check-access"
rm -f "$BIN_DIR/onedrive-doctor"

# A unit pair left behind by an earlier UNIT_NAME still fires on its own schedule
# at an ExecStart this run has just deleted. install.sh only warns about it, and
# only while installing; the uninstaller is where it can actually be turned off.
for orphan in "$UNIT_DIR"/*.timer; do
    [ -e "$orphan" ] || continue
    case "$orphan" in
        "$UNIT_DIR/$UNIT_NAME.timer") continue ;;
    esac
    orphan_unit="$(basename "$orphan" .timer)"
    orphan_service="$UNIT_DIR/$orphan_unit.service"
    [ -e "$orphan_service" ] || continue
    # Only pairs that run something this project installed.
    grep -q "$BIN_DIR/onedrive-" "$orphan_service" 2>/dev/null || continue
    if systemctl --user show-environment >/dev/null 2>&1; then
        # Both halves: the watcher is a long-lived process, so removing its unit
        # file while it stays enabled leaves it restarting against a script this
        # run has just deleted.
        systemctl --user disable --now "$orphan_unit.timer" 2>/dev/null || true
        systemctl --user disable --now "$orphan_unit-watch.service" 2>/dev/null || true
    fi
    rm -f "$orphan" "$orphan_service" "$UNIT_DIR/$orphan_unit-watch.service"
    rm -rf "$UNIT_DIR/$orphan_unit.timer.d"
    warn "removed a unit pair left by another name: $orphan_unit"
done

systemctl --user daemon-reload 2>/dev/null || \
    warn "run 'systemctl --user daemon-reload' after your next login"

NM_TARGET="$NM_DISPATCHER_DIR/90-rclone-onedrive-tray"
# The hook is one file for the whole machine and it names a unit, so it is only
# this install's to remove when the install is the normal one and the hook names
# the unit being uninstalled. Without those checks, removing a test install from
# a scratch prefix would delete the working install's hook.
if [ -f "$NM_TARGET" ]; then
    # The real home from the password database, which does not move when a test
    # redirects HOME. A redirected HOME with the default unit name used to look
    # exactly like the main install and reached for this hook. The override is
    # what lets a test step past this guard and reach the two below it.
    real_home="${REAL_HOME_OVERRIDE:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}"
    if [ -n "$real_home" ] && [ "$HOME" != "$real_home" ]; then
        say "Leaving $NM_TARGET alone: HOME is redirected to $HOME"
    elif [ "$PREFIX_GIVEN" -eq 1 ] && [ "$PREFIX" != "$HOME/.local" ]; then
        say "Leaving $NM_TARGET alone: this uninstall is for $PREFIX"
    elif ! grep -q "$UNIT_NAME" "$NM_TARGET" 2>/dev/null; then
        say "Leaving $NM_TARGET alone: it does not mention $UNIT_NAME"
    else
        say "Removing the NetworkManager hook (needs root)"
        if ! sudo rm -f "$NM_TARGET"; then
            warn "could not remove it; run: sudo rm -f $NM_TARGET"
        fi
    fi
fi

if [ "$PURGE" -eq 1 ]; then
    say "Removing configuration, filters, cache and icons"
    # Say what was really there rather than what was meant to be: announcing
    # three removals on a machine that had none of them is how a report stops
    # being worth reading.
    purge_one() {  # purge_one <path> <what it is>
        if [ -e "$1" ]; then
            rm -rf "$1"
            say "removed $1 ($2)"
        else
            say "nothing at $1 ($2)"
        fi
    }
    purge_one "$CONFIG_DIR" "the configuration and the filters"
    purge_one "$DATA_DIR" "the icon directory"
    # The cache holds the sync log and the pause stamp. The lock is not here: the
    # tray keeps that in $XDG_RUNTIME_DIR, which the logout removes anyway.
    purge_one "$CACHE_DIR" "the sync log and the pause stamp"
    warn "the rclone remote config (~/.config/rclone/rclone.conf) was kept"
elif [ -d "$CONFIG_DIR" ]; then
    warn "configuration kept in $CONFIG_DIR (use --purge to remove it)"
else
    say "nothing to remove: $CONFIG_DIR does not exist"
fi

warn "Left untouched: your synced folder, and any *.conflict* / *-old files"
say "Done"
