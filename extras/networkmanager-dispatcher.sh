#!/bin/sh
#
# NetworkManager dispatcher entry for rclone-onedrive-tray.
#
# NetworkManager runs this as root whenever an interface changes state. When a
# connection comes up (waking from suspend, joining wifi, plugging in a dock) it
# asks the sync service to run, so a machine that has been offline catches up in
# seconds instead of waiting for the next timer tick.
#
# Copied to /etc/NetworkManager/dispatcher.d/90-rclone-onedrive-tray by
# `install.sh --with-nm-dispatcher`. Remove that file to disable it.
#
# $1 is the interface name (empty for connectivity-change), $2 is the action.

UNIT="%UNIT_NAME%.service"

case "$2" in
    up|connectivity-change|dhcp4-change|dhcp6-change) ;;
    *) exit 0 ;;
esac

# Only the user who installed this has the unit, and only logged-in users have a
# runtime directory to talk to. Check both before poking systemd.
for runtime in /run/user/*; do
    [ -d "$runtime" ] || continue
    uid="${runtime##*/}"
    case "$uid" in
        ''|*[!0-9]*) continue ;;
    esac

    user="$(id -nu "$uid" 2>/dev/null)" || continue
    [ -n "$user" ] || continue

    home="$(getent passwd "$user" | cut -d: -f6)"
    [ -n "$home" ] || continue
    [ -f "$home/.config/systemd/user/$UNIT" ] || continue

    # --no-block matters: NetworkManager kills dispatcher scripts that overrun,
    # and a plain `systemctl start` on a oneshot unit waits for the whole sync.
    runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime" \
        systemctl --user start --no-block "$UNIT" >/dev/null 2>&1 || true
done

exit 0
