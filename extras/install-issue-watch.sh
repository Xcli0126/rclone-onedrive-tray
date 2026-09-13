#!/usr/bin/env bash
#
# install-issue-watch.sh: run extras/watch-issues.sh twice a day.
#
#     extras/install-issue-watch.sh
#     extras/install-issue-watch.sh --prefix /usr/local
#
# Installs a systemd user timer that asks the GitHub API for open issues every
# twelve hours and raises a desktop notification when something new appears.
# Nothing here touches the syncing; remove it with:
#
#     systemctl --user disable --now onedrive-issue-watch.timer
#     rm ~/.config/systemd/user/onedrive-issue-watch.{service,timer}
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
UNIT_NAME="onedrive-issue-watch"

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

BIN_DIR="$PREFIX/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

mkdir -p "$BIN_DIR" "$UNIT_DIR"
install -m 0755 "$SRC_DIR/extras/watch-issues.sh" "$BIN_DIR/watch-issues.sh"
say "installed $BIN_DIR/watch-issues.sh"

cat > "$UNIT_DIR/$UNIT_NAME.service" <<EOF
[Unit]
Description=Check rclone-onedrive-tray for new issues
Documentation=https://github.com/Xcli0126/rclone-onedrive-tray

[Service]
Type=oneshot
ExecStart=$BIN_DIR/watch-issues.sh
EOF

cat > "$UNIT_DIR/$UNIT_NAME.timer" <<'EOF'
[Unit]
Description=Check rclone-onedrive-tray for new issues twice a day

[Timer]
# Ten minutes after login, then every twelve hours measured from the last run.
OnBootSec=10min
OnUnitActiveSec=12h
AccuracySec=5min

[Install]
WantedBy=timers.target
EOF
chmod 0644 "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer"

if systemctl --user daemon-reload 2>/dev/null; then
    systemctl --user enable --now "$UNIT_NAME.timer" 2>/dev/null ||
        say "could not enable the timer; run: systemctl --user enable --now $UNIT_NAME.timer"
    systemctl --user list-timers "$UNIT_NAME.timer" --no-pager 2>/dev/null | head -3 || true
else
    say "no user systemd session; enable it after logging in:"
    say "    systemctl --user enable --now $UNIT_NAME.timer"
fi

say "First check runs in about ten minutes, then twice a day"
say "Reported issues are also appended to ~/.cache/rclone-onedrive-tray/issues.log"
