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

# The help is the comment block at the top of this file, up to the first line
# that is not a comment. A fixed line range prints shell code the moment the
# block grows or shrinks, which is what it used to do.
usage() { sed -n '2,/^[^#]/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)   PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        --no-start) START_TRAY=0; shift ;;
        --with-nm-dispatcher) NM_DISPATCHER=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

BIN_DIR="$PREFIX/bin"
XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="$XDG_CONFIG/rclone-onedrive-tray"
UNIT_DIR="$XDG_CONFIG/systemd/user"
AUTOSTART_DIR="$XDG_CONFIG/autostart"

# systemd reads ExecStart with its own quoting rules, and expands %i, %n and
# friends inside a unit file. A path that needs quoting is wrapped in double
# quotes (the templates do that) and its backslashes, quotes and percents are
# escaped here, so a prefix like "/home/x/My Files" or one holding a % still
# starts the right program.
systemd_exec_arg() {  # systemd_exec_arg <path>
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\"/\\\"}"
    text="${text//%/%%}"
    printf '%s' "$text"
}

# sed's replacement text gives \ and & a meaning of their own, and | ends the s
# command, so the value is escaped for sed before it goes in.
sed_replacement() {  # sed_replacement <text>
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//&/\\&}"
    text="${text//|/\\|}"
    printf '%s' "$text"
}
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
# Whether the tray was already here is one half of "is this a first install".
# setup.sh writes the config before it hands over, so on the documented first
# run the config exists by the time this script starts and cannot tell a first
# install from a re-run. A tray that was not installed before is the other half.
TRAY_WAS_INSTALLED=0
if [ -x "$BIN_DIR/onedrive-tray" ]; then TRAY_WAS_INSTALLED=1; fi

say "Installing scripts into $BIN_DIR"
mkdir -p "$BIN_DIR"
install -m 0755 "$SRC_DIR/bin/onedrive-sync" "$BIN_DIR/onedrive-sync"
install -m 0755 "$SRC_DIR/bin/onedrive-tray" "$BIN_DIR/onedrive-tray"
install -m 0755 "$SRC_DIR/bin/onedrive-watch" "$BIN_DIR/onedrive-watch"
install -m 0755 "$SRC_DIR/bin/onedrive-check" "$BIN_DIR/onedrive-check"
install -m 0755 "$SRC_DIR/bin/onedrive-check-access" "$BIN_DIR/onedrive-check-access"
install -m 0755 "$SRC_DIR/bin/onedrive-doctor" "$BIN_DIR/onedrive-doctor"

# --------------------------------------------------------------- config
say "Installing configuration into $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
CONFIG_EXISTED=0
if [ -f "$CONFIG_DIR/config" ]; then
    CONFIG_EXISTED=1
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

sed -e "s|%SYNC_SCRIPT%|$(sed_replacement "$(systemd_exec_arg "$BIN_DIR/onedrive-sync")")|g" \
    "$SRC_DIR/systemd/onedrive-sync.service.in" > "$UNIT_DIR/$UNIT_NAME.service"
sed -e "s|%INTERVAL%|$INTERVAL_MIN|g" \
    "$SRC_DIR/systemd/onedrive-sync.timer.in" > "$UNIT_DIR/$UNIT_NAME.timer"
chmod 0644 "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer"

WATCH="$(sed -n 's/^[[:space:]]*WATCH="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' \
         "$CONFIG_DIR/config" | tail -1)"
WATCH="${WATCH:-1}"
# The unit is written whether or not WATCH is on: the settings dialog's
# "Realtime sync" switch enables this unit, and it cannot enable one that was
# never created. Whether it runs is decided at the enable step below.
sed -e "s|%WATCH_SCRIPT%|$(sed_replacement "$(systemd_exec_arg "$BIN_DIR/onedrive-watch")")|g" \
    "$SRC_DIR/systemd/onedrive-watch.service.in" \
    > "$UNIT_DIR/$UNIT_NAME-watch.service"
chmod 0644 "$UNIT_DIR/$UNIT_NAME-watch.service"

# The timer is owned by this script, which writes it from INTERVAL_MIN on every
# run, while the tray's settings dialog writes OnUnitInactiveSec into a drop-in
# beside it. A drop-in wins over the unit, so an old one silently overrode a
# config edit. The config is the owner here: a drop-in that disagrees is brought
# back in line, and the run says which value is now in force.
TIMER_DROPIN="$UNIT_DIR/$UNIT_NAME.timer.d/interval.conf"
if [ -f "$TIMER_DROPIN" ]; then
    dropin_interval="$(sed -n \
        's/^[[:space:]]*OnUnitInactiveSec=\([0-9][0-9]*\)min.*/\1/p' \
        "$TIMER_DROPIN" | tail -1)"
    if [ -n "$dropin_interval" ] && [ "$dropin_interval" != "$INTERVAL_MIN" ]; then
        sed -i "s|^[[:space:]]*OnUnitInactiveSec=.*|OnUnitInactiveSec=${INTERVAL_MIN}min|" \
            "$TIMER_DROPIN"
        say "timer drop-in said ${dropin_interval}min; it now says ${INTERVAL_MIN}min, so INTERVAL_MIN in $CONFIG_DIR/config is what runs"
    elif [ -n "$dropin_interval" ]; then
        say "timer drop-in and INTERVAL_MIN agree on ${INTERVAL_MIN}min"
    fi
fi

# A UNIT_NAME that changed between installs leaves the old unit pair behind
# still enabled, and nothing said so. The timer is the entry point systemd
# starts, so it is the one named here.
for sibling in "$UNIT_DIR"/*.timer; do
    [ -e "$sibling" ] || continue
    sibling_name="$(basename "$sibling")"
    [ "$sibling_name" = "$UNIT_NAME.timer" ] && continue
    warn "$sibling_name is not the configured unit name; if an earlier install used it:"
    warn "    systemctl --user disable --now $sibling_name"
done

# --------------------------------------------------------------- autostart
# Exec= in a desktop entry is not a shell word list: the value is split on
# spaces, so an unquoted tray path under a prefix like "/home/x/My Files" became
# two arguments and the tray never started at login. The Desktop Entry
# specification wants such an argument enclosed in double quotes, with the double
# quote, backtick, dollar and backslash escaped inside it, and a literal percent
# written as %% because a single one is a field code. A path made only of
# unreserved characters is left bare, which is how the entry read before.
desktop_exec_arg() {  # desktop_exec_arg <path> -> the Exec argument
    local arg="$1"
    arg="${arg//%/%%}"
    case "$arg" in
        *[!A-Za-z0-9/._+:=@,^-]*)
            arg="${arg//\\/\\\\}"
            arg="${arg//\"/\\\"}"
            arg="${arg//\`/\\\`}"
            arg="${arg//\$/\\\$}"
            printf '"%s"' "$arg" ;;
        *) printf '%s' "$arg" ;;
    esac
}


# The entry is the tray's "Start tray at login" setting: the checkbox removes
# this file, and the tray reads its presence. Rewriting it on every run turned
# that setting back on after a `git pull && ./install.sh` with no message. The
# entry is written for a first install and refreshed when it is already there;
# on a re-run where it was removed, it stays removed.
AUTOSTART_FILE="$AUTOSTART_DIR/rclone-onedrive-tray.desktop"
if [ "$CONFIG_EXISTED" -eq 1 ] && [ "$TRAY_WAS_INSTALLED" -eq 1 ] &&
        [ ! -f "$AUTOSTART_FILE" ]; then
    say "autostart entry left absent: it was already removed, so 'Start tray at login' stays off"
else
    say "Installing autostart entry"
    mkdir -p "$AUTOSTART_DIR"
    tray_exec="$(desktop_exec_arg "$BIN_DIR/onedrive-tray")"
    sed -e "s|%TRAY_SCRIPT%|$(sed_replacement "$tray_exec")|g" \
        "$SRC_DIR/autostart/rclone-onedrive-tray.desktop.in" \
        > "$AUTOSTART_FILE"
    chmod 0644 "$AUTOSTART_FILE"
fi

# --------------------------------------------------------------- NM dispatcher
if [ "$NM_DISPATCHER" -eq 1 ]; then
    say "Installing the NetworkManager dispatcher hook"
    real_home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
    if [ -n "$real_home" ] && [ "$HOME" != "$real_home" ]; then
        warn "HOME is redirected to $HOME while this hook is machine-wide."
        warn "It would start $UNIT_NAME.timer for the real user, so it is not installed."
        NM_DISPATCHER=0
    elif [ "$PREFIX" != "$HOME/.local" ]; then
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
            # enable --now is a no-op on a unit that is already active, and the
            # watcher is a long-running loop, so an update would leave the old
            # code running until reboot. try-restart touches only a running unit
            # and does nothing when it is not there.
            systemctl --user try-restart "$UNIT_NAME-watch.service" 2>/dev/null || true
        elif [ "$WATCH" = "1" ]; then
            : # inotifywait is missing; the unit exists but cannot run (warned above)
        else
            # WATCH was turned off, by hand or through the wizard, and nothing
            # used to stop a watcher that was already running.
            systemctl --user disable --now "$UNIT_NAME-watch.service" 2>/dev/null || true
            say "watcher disabled: WATCH is not 1 in $CONFIG_DIR/config"
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
            $BIN_DIR/onedrive-check, $BIN_DIR/onedrive-check-access
            $BIN_DIR/onedrive-doctor
  config    $CONFIG_DIR/config
  filters   $CONFIG_DIR/filters.txt
  units     $UNIT_DIR/$UNIT_NAME.{service,timer}
            ${UNIT_DIR}/${UNIT_NAME}-watch.service (realtime; enabled when WATCH=1)
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
