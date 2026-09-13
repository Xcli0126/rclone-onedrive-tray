#!/usr/bin/env bash
#
# Installer for rclone-onedrive-tray (per-user, no root required).
#
#   ./install.sh                 install into ~/.local
#   ./install.sh --prefix DIR    install elsewhere
#   ./install.sh --no-start      do not launch the tray at the end
#   ./install.sh --with-nm-dispatcher
#                                also install the NetworkManager hook that
#                                syncs as soon as a connection comes up (needs
#                                root; the default install never does)
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
START_TRAY=1
NM_DISPATCHER=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)   PREFIX="$2"; shift 2 ;;
        --no-start) START_TRAY=0; shift ;;
        --with-nm-dispatcher) NM_DISPATCHER=1; shift ;;
        -h|--help)  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

BIN_DIR="$PREFIX/bin"
XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="$XDG_CONFIG/rclone-onedrive-tray"
UNIT_DIR="$XDG_CONFIG/systemd/user"
AUTOSTART_DIR="$XDG_CONFIG/autostart"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- dependencies
# Each piece is probed on its own so the report names the package that is really
# absent. A single combined probe would tell the reader to install a bundle and
# leave them to work out which part they were missing.
say "Checking dependencies"
missing=()
optional=()

command -v rclone >/dev/null 2>&1 || missing+=("rclone")

# flock is not optional: without it onedrive-sync cannot serialise runs.
command -v flock >/dev/null 2>&1 || missing+=("util-linux (flock)")

py_has() { python3 -c "$1" >/dev/null 2>&1; }

py_has 'import gi' || missing+=("python3-gi")
py_has 'import cairo' || missing+=("python3-cairo")
py_has 'import gi; gi.require_version("Gtk","3.0"); from gi.repository import Gtk' \
    || missing+=("gir1.2-gtk-3.0")

if ! py_has 'import gi; gi.require_version("AyatanaAppIndicator3","0.1"); from gi.repository import AyatanaAppIndicator3' \
   && ! py_has 'import gi; gi.require_version("AppIndicator3","0.1"); from gi.repository import AppIndicator3'; then
    missing+=("gir1.2-ayatanaappindicator3-0.1")
fi

# These only take features away, so they are reported separately.
py_has 'import gi; gi.require_version("Notify","0.7"); from gi.repository import Notify' \
    || optional+=("gir1.2-notify-0.7 (desktop notifications)")
command -v xdg-open >/dev/null 2>&1 || optional+=("xdg-utils (open folder / view log)")

APT_LINE="sudo apt install rclone python3-gi python3-cairo gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7 inotify-tools"

if [ "${#missing[@]}" -gt 0 ]; then
    warn "Missing required dependencies:"
    printf '    - %s\n' "${missing[@]}" >&2
    cat >&2 <<EOF

On Debian/Ubuntu install them with:

    $APT_LINE

The rclone shipped by distributions is often too old: --resilient/--recover
(which let an interrupted sync heal itself instead of demanding a manual
--resync) need rclone >= 1.65. Check with \`rclone version\`; if it is older, get
a current build from https://rclone.org/downloads/ and put the binary in
/usr/local/bin (which takes precedence over /usr/bin).

Full list, including what each absence causes: docs/DEPENDENCIES.md
EOF
    exit 1
fi

if [ "${#optional[@]}" -gt 0 ]; then
    warn "Optional dependencies not present (those features will be off):"
    printf '    - %s\n' "${optional[@]}" >&2
fi

RCLONE_VER="$(rclone version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
if [ -n "$RCLONE_VER" ]; then
    major="${RCLONE_VER%%.*}"; minor="${RCLONE_VER##*.}"
    if [ "$major" -eq 0 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 65 ]; }; then
        warn "rclone $RCLONE_VER is older than 1.65: automatic recovery from an"
        warn "interrupted sync (--recover) will not work. See docs/TROUBLESHOOTING.md."
    fi
else
    warn "Could not determine the rclone version."
fi

# inotify-tools only powers the realtime watcher, so its absence is a warning
# rather than a hard failure. Without it the timer still syncs everything.
HAVE_INOTIFY=1
command -v inotifywait >/dev/null 2>&1 || HAVE_INOTIFY=0
if [ "$HAVE_INOTIFY" -eq 0 ]; then
    warn "inotify-tools is missing, so realtime sync will not start."
    warn "The timer still runs. To enable realtime sync later:"
    warn "    sudo apt install inotify-tools"
fi

# --------------------------------------------------------------- scripts
say "Installing scripts into $BIN_DIR"
mkdir -p "$BIN_DIR"
install -m 0755 "$SRC_DIR/bin/onedrive-sync" "$BIN_DIR/onedrive-sync"
install -m 0755 "$SRC_DIR/bin/onedrive-tray" "$BIN_DIR/onedrive-tray"
install -m 0755 "$SRC_DIR/bin/onedrive-watch" "$BIN_DIR/onedrive-watch"
install -m 0755 "$SRC_DIR/bin/onedrive-check" "$BIN_DIR/onedrive-check"

# --------------------------------------------------------------- config
say "Installing configuration into $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_DIR/config" ]; then
    warn "existing config kept: $CONFIG_DIR/config"
else
    install -m 0644 "$SRC_DIR/config/config.example" "$CONFIG_DIR/config"
    cp -f "$CONFIG_DIR/config" "$CONFIG_DIR/config.example"
fi
if [ -f "$CONFIG_DIR/filters.txt" ]; then
    warn "existing filters kept: $CONFIG_DIR/filters.txt"
else
    install -m 0644 "$SRC_DIR/config/filters.example" "$CONFIG_DIR/filters.txt"
fi

# --------------------------------------------------------------- systemd units
say "Installing systemd user units into $UNIT_DIR"
mkdir -p "$UNIT_DIR"
UNIT_NAME="$(sed -n 's/^[[:space:]]*UNIT_NAME="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' \
             "$CONFIG_DIR/config" | tail -1)"
UNIT_NAME="${UNIT_NAME:-onedrive-sync}"
INTERVAL_MIN="$(sed -n 's/^[[:space:]]*INTERVAL_MIN="\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/p' \
                 "$CONFIG_DIR/config" | tail -1)"
INTERVAL_MIN="${INTERVAL_MIN:-5}"

sed -e "s|%SYNC_SCRIPT%|$BIN_DIR/onedrive-sync|g" \
    "$SRC_DIR/systemd/onedrive-sync.service.in" > "$UNIT_DIR/$UNIT_NAME.service"
sed -e "s|%INTERVAL%|$INTERVAL_MIN|g" \
    "$SRC_DIR/systemd/onedrive-sync.timer.in" > "$UNIT_DIR/$UNIT_NAME.timer"
chmod 0644 "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer"

WATCH="$(sed -n 's/^[[:space:]]*WATCH="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' \
         "$CONFIG_DIR/config" | tail -1)"
WATCH="${WATCH:-1}"
if [ "$WATCH" = "1" ]; then
    sed -e "s|%WATCH_SCRIPT%|$BIN_DIR/onedrive-watch|g" \
        "$SRC_DIR/systemd/onedrive-watch.service.in" \
        > "$UNIT_DIR/$UNIT_NAME-watch.service"
    chmod 0644 "$UNIT_DIR/$UNIT_NAME-watch.service"
fi

# --------------------------------------------------------------- autostart
say "Installing autostart entry"
mkdir -p "$AUTOSTART_DIR"
sed -e "s|%TRAY_SCRIPT%|$BIN_DIR/onedrive-tray|g" \
    "$SRC_DIR/autostart/rclone-onedrive-tray.desktop.in" \
    > "$AUTOSTART_DIR/rclone-onedrive-tray.desktop"
chmod 0644 "$AUTOSTART_DIR/rclone-onedrive-tray.desktop"

# --------------------------------------------------------------- NM dispatcher
if [ "$NM_DISPATCHER" -eq 1 ]; then
    say "Installing the NetworkManager dispatcher hook"
    if [ "$PREFIX" != "$HOME/.local" ]; then
        warn "this hook is machine-wide and will start $UNIT_NAME.timer,"
        warn "which lives outside $HOME/.local. Install the units normally if that is"
        warn "not what you meant."
    fi
    NM_TARGET="/etc/NetworkManager/dispatcher.d/90-rclone-onedrive-tray"
    NM_TMP="$(mktemp)"
    sed -e "s|%UNIT_NAME%|$UNIT_NAME|g" \
        "$SRC_DIR/extras/networkmanager-dispatcher.sh" > "$NM_TMP"
    if [ -d /etc/NetworkManager/dispatcher.d ]; then
        if sudo install -m 0755 -o root -g root "$NM_TMP" "$NM_TARGET"; then
            say "installed $NM_TARGET"
            say "a sync starts as soon as a connection comes up"
        else
            warn "could not install the hook. Run this yourself:"
            warn "    sudo install -m 0755 $NM_TMP $NM_TARGET"
            warn "the script has been left at $NM_TMP"
            NM_TMP=""
        fi
    else
        warn "no /etc/NetworkManager/dispatcher.d on this system; skipping."
        warn "NetworkManager will re-sync on the next timer tick instead."
    fi
    [ -n "$NM_TMP" ] && rm -f "$NM_TMP"
fi

# --------------------------------------------------------------- enable
if systemctl --user daemon-reload 2>/dev/null; then
    # The running manager reads its own unit search path, which is not always
    # $UNIT_DIR. Redirect XDG_CONFIG_HOME and the units land somewhere it never
    # looks, while a same-named unit from another install is still visible: an
    # unconditional `enable --now` would then start that one. Ask where the unit
    # actually is before touching it.
    seen="$(systemctl --user show -p FragmentPath --value "$UNIT_NAME.timer" 2>/dev/null || true)"
    if [ "$seen" != "$UNIT_DIR/$UNIT_NAME.timer" ]; then
        warn "the user systemd manager does not read $UNIT_DIR, so nothing was enabled"
        warn "  it reports: ${seen:-no $UNIT_NAME.timer at all}"
        warn "activate them yourself once the units are in its search path:"
        warn "    systemctl --user daemon-reload && systemctl --user enable --now $UNIT_NAME.timer"
    else
        systemctl --user enable --now "$UNIT_NAME.timer" 2>/dev/null || \
            warn "could not enable $UNIT_NAME.timer (no user systemd session?)"
        systemctl --user list-timers "$UNIT_NAME.timer" --no-pager 2>/dev/null | head -3 || true
        if [ "$WATCH" = "1" ] && [ "$HAVE_INOTIFY" -eq 1 ]; then
            systemctl --user enable --now "$UNIT_NAME-watch.service" 2>/dev/null || \
                warn "could not enable $UNIT_NAME-watch.service"
        fi
    fi
else
    warn "systemctl --user is unavailable; enable the timer yourself after logging in:"
    warn "    systemctl --user enable --now $UNIT_NAME.timer"
fi

# --------------------------------------------------------------- done
cat <<EOF

$(say "Installed")

  scripts   $BIN_DIR/onedrive-sync, $BIN_DIR/onedrive-tray, $BIN_DIR/onedrive-watch
  config    $CONFIG_DIR/config
  filters   $CONFIG_DIR/filters.txt
  units     $UNIT_DIR/$UNIT_NAME.{service,timer}
            ${UNIT_DIR}/${UNIT_NAME}-watch.service (realtime, when WATCH=1)
  autostart $AUTOSTART_DIR/rclone-onedrive-tray.desktop

Next steps:

  (./setup.sh walks through all of the below interactively.)

  1. Make sure the rclone remote in your config exists and is authorised:

         rclone config          # create/authorise e.g. "onedrive"
         rclone lsd onedrive:   # should list your files

  2. Build the sync baseline once (first run downloads everything):

         onedrive-sync --resync

  3. Start the tray icon (it will also start automatically at next login):

         onedrive-tray &

  Check the log any time with:

      tail -f ~/.cache/rclone-onedrive-tray/sync.log

  Full troubleshooting notes: docs/TROUBLESHOOTING.md

EOF

if [ "$START_TRAY" -eq 1 ]; then
    say "Starting the tray icon (an already-running instance keeps running)"
    setsid "$BIN_DIR/onedrive-tray" >/dev/null 2>&1 &
fi
