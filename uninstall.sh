#!/usr/bin/env bash
#
# Uninstaller for rclone-onedrive-tray.
#
#   ./uninstall.sh                 remove programs, units and autostart entry
#   ./uninstall.sh --prefix DIR    match a non-default install prefix
#   ./uninstall.sh --purge         also remove the configuration and filters
#
# Your synced folder, the rclone remote config, and any conflict/backup files
# bisync created are never touched.
#
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
PURGE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)   PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        --purge)    PURGE=1; shift ;;
        -h|--help)  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

BIN_DIR="$PREFIX/bin"
CONFIG_DIR="$XDG_CONFIG/rclone-onedrive-tray"
UNIT_DIR="$XDG_CONFIG/systemd/user"
AUTOSTART="$XDG_CONFIG/autostart/rclone-onedrive-tray.desktop"

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
rm -f "$AUTOSTART"
rm -f "$BIN_DIR/onedrive-sync" "$BIN_DIR/onedrive-tray" "$BIN_DIR/onedrive-watch"
rm -f "$BIN_DIR/onedrive-check"

systemctl --user daemon-reload 2>/dev/null || \
    warn "run 'systemctl --user daemon-reload' after your next login"

NM_TARGET="/etc/NetworkManager/dispatcher.d/90-rclone-onedrive-tray"
if [ -f "$NM_TARGET" ]; then
    say "Removing the NetworkManager hook (needs root)"
    if ! sudo rm -f "$NM_TARGET"; then
        warn "could not remove it; run: sudo rm -f $NM_TARGET"
    fi
fi

if [ "$PURGE" -eq 1 ]; then
    say "Removing configuration"
    rm -rf "$CONFIG_DIR"
    rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/rclone-onedrive-tray"
    warn "the rclone remote config (~/.config/rclone/rclone.conf) was kept"
else
    warn "configuration kept in $CONFIG_DIR (use --purge to remove it)"
fi

warn "Left untouched: your synced folder, and any *.conflict* / *-old files"
say "Done"
