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

# This script's own directory, for the shared config reader below. install.sh
# carries the same variable.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Recover the unit base name from the config (may differ from the default). The
# reader is install.sh's, from lib/config.sh, so a change to the format cannot land
# in one of the two scripts and not the other.
# shellcheck source=lib/config.sh
. "$SRC_DIR/lib/config.sh"

UNIT_NAME="onedrive-sync"
if [ -f "$CONFIG_DIR/config" ]; then
    parsed="$(config_value UNIT_NAME)"
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
    # A refused disable used to be swallowed, and the run still ended on "Done"
    # with the units enabled and their scripts already deleted. The same rule as
    # the stale pair below: systemd's own sentence is the whole signal.
    for target in "$UNIT_NAME.timer" "$UNIT_NAME-watch.service"; do
        if ! disable_err="$(systemctl --user disable --now "$target" 2>&1)"; then
            warn "could not disable $target: ${disable_err:-systemctl printed nothing}"
            warn "    systemctl --user disable --now $target"
        fi
    done
else
    warn "no user systemd session; skipping unit teardown"
fi

say "Removing files"
# The units, the drop-in and the autostart entry live at paths that do not depend on
# --prefix: the units carry an absolute ExecStart, and the autostart entry an absolute
# Exec. Removing them for a scratch prefix therefore tears down whatever install is
# actually running from them, which is the same hazard the NetworkManager hook below is
# guarded against. So each file goes only when it names this prefix's scripts.
# A file is another install's only when it runs an executable that is there and is not
# ours. One that names nothing, or names a path that is gone, is stale: leaving it behind
# would keep a timer or a login pointing at something that no longer exists.
# The two writers escape the same prefix differently, so undoing it has to know which
# file it is reading. systemd doubles a `\`, a `%` and a `$` and quotes the word; the
# desktop entry escapes with backslashes and then doubles those, because the value
# crosses the key-file reader before the word splitter. Comparing raw text against the
# path this run would write called another prefix's file ours whenever its path held one
# of those characters, and the fix for a scratch prefix then removed or repointed the
# wrong install's files.
exec_path() {  # exec_path <file> -> the executable it runs, unescaped
    local line key value other
    line="$(grep -m1 -e '^ExecStart=' -e '^Exec=' "$1" 2>/dev/null)" || true
    case "$line" in
        ExecStart=*) key=systemd; value="${line#ExecStart=}" ;;
        Exec=*)      key=desktop; value="${line#Exec=}" ;;
        *)           return 0 ;;
    esac
    value="${value#-}"
    case "$value" in
        \"*) other="$(printf '%s' "$value" | sed -e 's/^"//' -e 's/\([^\\]\)".*/\1/')" ;;
        *)   other="${value%% *}" ;;
    esac
    case "$key" in
        systemd)
            # `\\` is a backslash and `$$` a literal dollar, both doubled by
            # systemd_exec_arg, and `%%` is a literal `%`.
            other="$(printf '%s' "$other" | sed -e 's/\\\(.\)/\1/g')"
            other="${other//\$\$/\$}" ;;
        desktop)
            # Two layers to undo: the word splitter's escapes, and then the key-file
            # reader's doubling of them. One pass left `\\$` as `\$`, a path the file
            # does not name.
            other="$(printf '%s' "$other" | sed -e 's/\\\(["\\`$]\)/\1/g')"
            other="$(printf '%s' "$other" | sed -e 's/\\\(["\\`$]\)/\1/g')" ;;
    esac
    # `%%` is a literal `%` in both formats; a `%` left on its own is a systemd
    # specifier or a desktop field code, which names something this cannot resolve.
    case "${other//%%/}" in
        *%*) printf '%s' ""; return 0 ;;
    esac
    other="${other//%%/%}"
    printf '%s' "$other"
}

foreign_exec() {  # foreign_exec <file>: 0 when it runs something that exists elsewhere
    local other
    other="$(exec_path "$1")"
    [ -n "$other" ] || return 1
    case "$other" in
        "$BIN_DIR"/*) return 1 ;;
    esac
    [ -x "$other" ]
}
owns_unit() {  # owns_unit <file> -- is this unit ours to remove?
    [ -f "$1" ] || return 1
    foreign_exec "$1" && return 1
    return 0
}
owns_autostart() {  # owns_autostart <file> -- is this entry ours to remove?
    [ -f "$1" ] || return 1
    foreign_exec "$1" && return 1
    return 0
}
kept_units=0
# The service and the timer are one install: the timer names the service and has no
# ExecStart of its own, so it goes whenever the service does.
service_file="$UNIT_DIR/$UNIT_NAME.service"
if [ -f "$service_file" ]; then
    if owns_unit "$service_file"; then
        rm -f "$service_file"
    else
        warn "leaving $service_file alone: it runs another install's script"
        kept_units=1
    fi
fi
if [ "$kept_units" = 0 ]; then
    rm -f "$UNIT_DIR/$UNIT_NAME.timer"
fi
watch_file="$UNIT_DIR/$UNIT_NAME-watch.service"
if [ -f "$watch_file" ]; then
    if owns_unit "$watch_file"; then
        rm -f "$watch_file"
    else
        warn "leaving $watch_file alone: it runs another install's script"
        kept_units=1
    fi
fi
# The tray stores the sync interval in a drop-in beside the timer, and install.sh
# keeps an existing one on purpose. Left behind, it silently hands its interval to
# the next install of the same unit name, so it goes with the units it overrides -
# and not when those units belong to another install.
if [ "$kept_units" = 0 ]; then
    rm -rf "$UNIT_DIR/$UNIT_NAME.timer.d"
else
    warn "leaving $UNIT_DIR/$UNIT_NAME.timer.d alone: its units belong to another install"
fi
if [ -f "$AUTOSTART" ]; then
    if owns_autostart "$AUTOSTART"; then
        rm -f "$AUTOSTART"
    else
        warn "leaving $AUTOSTART alone: it starts another install's tray"
    fi
fi
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
    # Only pairs that run something this project installed, and the scripts are
    # what is named rather than this run's $BIN_DIR: a pair left by an install
    # under a different --prefix names the same script, and anchoring the search
    # to the prefix in use left its timer firing at a script this run deletes.
    grep -qE 'onedrive-(sync|watch)' "$orphan_service" 2>/dev/null || continue
    if systemctl --user show-environment >/dev/null 2>&1; then
        # Both halves: the watcher is a long-lived process, so removing its unit
        # file while it stays enabled leaves it restarting against a script this
        # run has just deleted. A refusal is reported for the same reason the
        # units above are: "removed a unit pair" must not be said over a unit
        # systemd would not let go of.
        for target in "$orphan_unit.timer" "$orphan_unit-watch.service"; do
            if ! disable_err="$(systemctl --user disable --now "$target" 2>&1)"; then
                warn "could not disable $target: ${disable_err:-systemctl printed nothing}"
                warn "    systemctl --user disable --now $target"
            fi
        done
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
