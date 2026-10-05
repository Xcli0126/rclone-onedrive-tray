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
# The NetworkManager hook is one machine-wide file. Naming its directory here,
# overridable like every other path in this script, is what lets a test drive the
# hook branches without writing into /etc; the default is what NetworkManager reads.
NM_DISPATCHER_DIR="${NM_DISPATCHER_DIR:-/etc/NetworkManager/dispatcher.d}"

# systemd reads ExecStart with its own quoting rules, expands %i, %n and friends
# inside a unit file, and expands $NAME as a variable reference; a literal dollar
# is written $$. A path that needs quoting is wrapped in double quotes (the
# templates do that) and its backslashes, quotes, percents and dollars are escaped
# here, so a prefix like "/home/x/My Files", one holding a % or one holding a $
# still starts the right program.
#
# The dollar rule is systemd's documented one, not a measured expansion: proving
# what systemd would do with it means starting a unit, and no test here does that.
systemd_exec_arg() {  # systemd_exec_arg <path>
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\"/\\\"}"
    text="${text//%/%%}"
    text="${text//\$/\$\$}"
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

# Read one config value the way the other readers do. The implementation is
# shared with uninstall.sh: see lib/config.sh. It is sourced rather than defined
# here because the two scripts used to carry a copy each, and a copy is how the
# escaping drifted the last time.
# shellcheck source=lib/config.sh
. "$SRC_DIR/lib/config.sh"

# config.example documents RCLONE as "the rclone binary to run, by name or by
# path. Change it to use a build outside PATH", and onedrive-sync and
# onedrive-doctor honour it. This script used to probe and version whatever
# `rclone` PATH held, so a user who followed that advice could not install, and
# one with an old rclone on PATH was warned about a binary the project never runs.
# The key is read here, before the probe, and read the same way UNIT_NAME is
# below. A first install has no config yet; the default is the name the shipped
# example carries.
RCLONE_BIN="rclone"
if [ -f "$CONFIG_DIR/config" ]; then
    parsed_rclone="$(config_value RCLONE)"
    if [ -n "$parsed_rclone" ]; then
        RCLONE_BIN="$parsed_rclone"
    fi
fi

if ! command -v "$RCLONE_BIN" >/dev/null 2>&1; then
    if [ "$RCLONE_BIN" = "rclone" ]; then
        missing+=("rclone")
    else
        missing+=("the rclone RCLONE names in $CONFIG_DIR/config ($RCLONE_BIN)")
    fi
fi

# UNIT_NAME becomes a unit file name and, with --with-nm-dispatcher, the value
# substituted into the machine-wide hook NetworkManager runs as root. It is read
# here, before anything is written, and checked with the allow-list setup.sh
# applies to its own --unit-name: systemd accepts letters, digits, ':', '_', '.',
# '-' and '@' and nothing else, and a name must not start with a dot. It used to
# be read only when the units were written and never checked, so a value holding
# a shell expansion was executed by the dispatcher's own shell, a value holding
# sed's '&' silently produced a hook that could not match a unit, and a value
# holding '|' killed the run inside sed without ever naming the key.
#
# A first install has no config yet; the default is the name the shipped example
# carries, so the value the units are written with is the same either way.
UNIT_NAME="onedrive-sync"
if [ -f "$CONFIG_DIR/config" ]; then
    parsed_unit="$(config_value UNIT_NAME)"
    if [ -n "$parsed_unit" ]; then
        UNIT_NAME="$parsed_unit"
    fi
fi
case "$UNIT_NAME" in
    ''|*[!A-Za-z0-9:_.@-]*)
        die "invalid UNIT_NAME in $CONFIG_DIR/config: '$UNIT_NAME' (allowed: letters, digits, and : _ . - @)" ;;
    .*)
        die "invalid UNIT_NAME in $CONFIG_DIR/config: '$UNIT_NAME' (a unit name must not start with a dot)" ;;
esac

# flock is not optional: without it onedrive-sync cannot serialise runs.
command -v flock >/dev/null 2>&1 || missing+=("util-linux (flock)")

py_has() { python3 -c "$1" >/dev/null 2>&1; }

# The tray needs these; the sync half does not, and both the README and
# DEPENDENCIES.md tell a server user to run onedrive-sync and the timer. Blocking
# the whole install on a desktop stack made that advice impossible to follow:
# nothing was installed at all. They warn, and the icon is left out below.
tray_missing=()
py_has 'import gi' || tray_missing+=("python3-gi")
py_has 'import cairo' || tray_missing+=("python3-cairo")
py_has 'import gi; gi.require_version("Gtk","3.0"); from gi.repository import Gtk' \
    || tray_missing+=("gir1.2-gtk-3.0")

if ! py_has 'import gi; gi.require_version("AyatanaAppIndicator3","0.1"); from gi.repository import AyatanaAppIndicator3' \
   && ! py_has 'import gi; gi.require_version("AppIndicator3","0.1"); from gi.repository import AppIndicator3'; then
    tray_missing+=("gir1.2-ayatanaappindicator3-0.1")
fi

# These only take features away, so they are reported separately.
py_has 'import gi; gi.require_version("Notify","0.7"); from gi.repository import Notify' \
    || optional+=("gir1.2-notify-0.7 (desktop notifications)")
command -v xdg-open >/dev/null 2>&1 || optional+=("xdg-utils (open folder / view log)")

APT_LINE="sudo apt install rclone python3-gi python3-cairo gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7 inotify-tools"
APT_TRAY_LINE="python3-gi python3-cairo gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7"

if [ "${#missing[@]}" -gt 0 ]; then
    warn "Missing required dependencies:"
    printf '    - %s\n' "${missing[@]}" >&2
    cat >&2 <<EOF

On Debian/Ubuntu install them with:

    $APT_LINE

The rclone shipped by distributions is often too old: --recover, --max-lock,
--conflict-resolve and --conflict-loser, which the shipped BISYNC_ARGS uses,
all need rclone >= 1.66. Check with \`rclone version\`; if it is older, get
a current build from https://rclone.org/downloads/ and put the binary in
/usr/local/bin (which takes precedence over /usr/bin).

Full list, including what each absence causes: docs/DEPENDENCIES.md
EOF
    exit 1
fi

if [ "${#tray_missing[@]}" -gt 0 ]; then
    warn "The tray icon needs packages that are not installed:"
    printf '    - %s\n' "${tray_missing[@]}" >&2
    cat >&2 <<EOF

The sync half does not need them, so it is installed and the timer will run.
On Debian/Ubuntu the tray needs:

    sudo apt install $APT_TRAY_LINE

Without them the icon is not installed as an autostart entry, so nothing tries to
start a tray that cannot run. docs/DEPENDENCIES.md has the full list.
EOF
fi

if [ "${#optional[@]}" -gt 0 ]; then
    warn "Optional dependencies not present (those features will be off):"
    printf '    - %s\n' "${optional[@]}" >&2
fi

# The wrapper's default BISYNC_ARGS uses --recover, --max-lock,
# --conflict-resolve and --conflict-loser, and every one of those four arrived in
# rclone 1.66 (checked against rclone's cmd/bisync/cmd.go at the v1.65.0 and
# v1.66.0 tags). This check used to warn below 1.65 only, so 1.65 -- the version
# the docs blessed -- was told nothing and then failed every run on an unknown
# flag. A version string does not settle it either: a distribution may backport a
# flag, and RCLONE may name a build that reports a different version, so the
# binary is asked what it lists, the way onedrive-sync probes --resync-mode. Each
# flag it does not list is named, because "upgrade rclone" without the flag is
# advice a user cannot act on.
rclone_has_bisync_flag() {  # rclone_has_bisync_flag <help-text> <flag name>
    grep -qE "^[[:space:]]*(-[^,]+, )?--$2([[:space:]]|$)" <<<"$1"
}
RCLONE_VER="$("$RCLONE_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
RCLONE_HELP="$("$RCLONE_BIN" bisync --help 2>/dev/null || true)"
missing_bisync_flags=()
for bisync_flag in recover max-lock conflict-resolve conflict-loser; do
    rclone_has_bisync_flag "$RCLONE_HELP" "$bisync_flag" ||
        missing_bisync_flags+=("--$bisync_flag")
done
if [ -n "$RCLONE_HELP" ]; then
    if [ "${#missing_bisync_flags[@]}" -gt 0 ]; then
        warn "this rclone has no ${missing_bisync_flags[*]}, so the flags in"
        warn "BISYNC_ARGS that need them will be refused and every run will fail."
        warn "All four arrived in rclone 1.66; see docs/TROUBLESHOOTING.md."
    fi
elif [ -n "$RCLONE_VER" ]; then
    # The binary would not list its flags, so fall back to the version it
    # reports. 1.65 is the version that used to pass this check and fail the run.
    major="${RCLONE_VER%%.*}"; minor="${RCLONE_VER##*.}"
    if [ "$major" -eq 0 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 65 ]; }; then
        warn "rclone $RCLONE_VER is older than 1.65: automatic recovery from an"
        warn "interrupted sync (--recover) will not work. See docs/TROUBLESHOOTING.md."
    elif [ "$major" -eq 1 ] && [ "$minor" -lt 66 ]; then
        warn "rclone $RCLONE_VER may lack --recover, --max-lock, --conflict-resolve"
        warn "and --conflict-loser, which the default BISYNC_ARGS needs. They arrived"
        warn "in rclone 1.66. See docs/TROUBLESHOOTING.md."
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
# Every script this installer ships, in the order the summary reports them. The
# install loop and the "Installed" summary both read this one list, because the
# summary used to be written out by hand beside the loop and could name a script
# the loop had stopped installing -- or miss one it had just installed. The paths
# are written in full rather than built from a name, because tests/docs.sh reads
# the list out of this file and compares it with what uninstall.sh removes and
# what docs/UPDATING.md's loop names.
SCRIPTS=(
    "$SRC_DIR/bin/onedrive-sync"
    "$SRC_DIR/bin/onedrive-tray"
    "$SRC_DIR/bin/onedrive-watch"
    "$SRC_DIR/bin/onedrive-check"
    "$SRC_DIR/bin/onedrive-check-access"
    "$SRC_DIR/bin/onedrive-doctor"
)

# Whether the tray was already here is one half of "is this a first install".
# setup.sh writes the config before it hands over, so on the documented first
# run the config exists by the time this script starts and cannot tell a first
# install from a re-run. A tray that was not installed before is the other half.
# Whether the tray was installed before is asked of the things a prefix change does
# not move: the tray binary at this prefix, or the units at their one shared path. It
# used to be the binary alone, so an install from another prefix looked like a first
# install and the autostart entry a user had removed came back.
TRAY_WAS_INSTALLED=0
if [ -x "$BIN_DIR/onedrive-tray" ] || [ -f "$UNIT_DIR/$UNIT_NAME.service" ]; then
    TRAY_WAS_INSTALLED=1
fi

# Does a unit or desktop file name an executable, and is it one of ours? A file that
# names no path at all, or one that is not there, is stale rather than another install's:
# leaving it behind would keep a login or a timer pointing at something that is gone.
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
say "Installing scripts into $BIN_DIR"
mkdir -p "$BIN_DIR"
for script in "${SCRIPTS[@]}"; do
    install -m 0755 "$script" "$BIN_DIR/${script##*/}"
done

# --------------------------------------------------------------- config
say "Installing configuration into $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
CONFIG_EXISTED=0
if [ -f "$CONFIG_DIR/config" ]; then
    CONFIG_EXISTED=1
    warn "existing config kept: $CONFIG_DIR/config"
else
    install -m 0644 "$SRC_DIR/config/config.example" "$CONFIG_DIR/config"
fi
# The header comment in every script points at "config.example" beside the config,
# and nothing reads it. It used to be written only when there was no config, so it
# went stale on the first re-run; refreshing it costs one copy and keeps the file
# those comments point at matching the release that installed it.
install -m 0644 "$SRC_DIR/config/config.example" "$CONFIG_DIR/config.example"
if [ -f "$CONFIG_DIR/filters.txt" ]; then
    warn "existing filters kept: $CONFIG_DIR/filters.txt"
else
    install -m 0644 "$SRC_DIR/config/filters.example" "$CONFIG_DIR/filters.txt"
fi

# --------------------------------------------------------------- systemd units
say "Installing systemd user units into $UNIT_DIR"
mkdir -p "$UNIT_DIR"
# UNIT_NAME was read and validated before anything was written, so the units and
# the NetworkManager hook cannot be reached with a name systemd would reject.
INTERVAL_MIN="$(config_value INTERVAL_MIN)"
INTERVAL_MIN="${INTERVAL_MIN:-5}"
# The value goes straight into OnUnitInactiveSec=%INTERVAL%min, and systemd's
# answer to a value it cannot parse is a warning in the journal and a dropped
# directive. Dropping it leaves OnActiveSec=2min as the timer's only trigger,
# which fires once per activation and is then disabled: exactly one sync per
# login, with the timer still reported as active. A zero is parsed happily and
# means "as soon as the last run finished", which is a sync loop. The tray
# refuses an interval under a minute and setup.sh --interval refuses anything
# that is not a whole number; this is the third entry point into the same file,
# and a hand edit or a value carried over from an old config reaches it.
#
# Zero has more than one spelling to systemd: `systemd-analyze timespan` reads
# 0min, 00min and 000min as the same zero, so testing for the string "0" left
# 00 and 000 through with the timer still counting down from nothing. The test
# for every all-zero spelling is the one setup.sh --interval already uses: a
# digit that is not a zero.
case "$INTERVAL_MIN" in
    ''|*[!0-9]*)
        warn "INTERVAL_MIN in $CONFIG_DIR/config is not a whole number of minutes (\"$INTERVAL_MIN\"); using 5"
        INTERVAL_MIN=5 ;;
    *)
        [ -n "${INTERVAL_MIN//0/}" ] || {
            warn "INTERVAL_MIN in $CONFIG_DIR/config must be at least 1; using 5"
            INTERVAL_MIN=5
        } ;;
esac

# A unit directory is shared by every prefix on the machine, and the unit file holds an
# absolute ExecStart. Writing it for another prefix silently repoints an install that is
# already running from the old one, so the existing unit is read first and left alone
# when it belongs to a different prefix: moving an install is an uninstall and an
# install, not a second install from elsewhere.
UNIT_IS_OTHER=0
if [ -f "$UNIT_DIR/$UNIT_NAME.service" ] &&
        foreign_exec "$UNIT_DIR/$UNIT_NAME.service"; then
    UNIT_IS_OTHER=1
    warn "leaving the systemd units alone: $UNIT_DIR/$UNIT_NAME.service runs a different prefix, not $BIN_DIR"
    warn "  to move the install, run ./uninstall.sh --prefix <the old prefix> first"
fi
if [ "$UNIT_IS_OTHER" = 0 ]; then
sed -e "s|%SYNC_SCRIPT%|$(sed_replacement "$(systemd_exec_arg "$BIN_DIR/onedrive-sync")")|g" \
    "$SRC_DIR/systemd/onedrive-sync.service.in" > "$UNIT_DIR/$UNIT_NAME.service"
sed -e "s|%INTERVAL%|$INTERVAL_MIN|g" \
    "$SRC_DIR/systemd/onedrive-sync.timer.in" > "$UNIT_DIR/$UNIT_NAME.timer"
chmod 0644 "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer"
fi

WATCH="$(config_value WATCH)"
WATCH="${WATCH:-1}"

# The spellings that mean on are the same set onedrive-sync, onedrive-doctor and
# the tray's truthy() accept: 1|true|yes|on|enabled. This script tested for the
# literal "1", so a config saying WATCH="yes" -- which the wizard's own prompt
# accepts and the rest of the project reads as on -- had the installer disable a
# watcher it considered off. The off set is 0|false|no|off|disabled, and anything
# this does not recognise is off, the same way the tray treats an unknown value.
watch_on() {  # watch_on <value>
    case "$1" in
        1|true|yes|on|enabled) return 0 ;;
        *) return 1 ;;
    esac
}
# The unit is written whether or not WATCH is on: the settings dialog's
# "Realtime sync" switch enables this unit, and it cannot enable one that was
# never created. Whether it runs is decided at the enable step below.
if [ "$UNIT_IS_OTHER" = 0 ]; then
sed -e "s|%WATCH_SCRIPT%|$(sed_replacement "$(systemd_exec_arg "$BIN_DIR/onedrive-watch")")|g" \
    "$SRC_DIR/systemd/onedrive-watch.service.in" \
    > "$UNIT_DIR/$UNIT_NAME-watch.service"
chmod 0644 "$UNIT_DIR/$UNIT_NAME-watch.service"
fi

# The timer is owned by this script, which writes it from INTERVAL_MIN on every
# run, while the tray's settings dialog writes OnUnitInactiveSec into a drop-in
# beside it. A drop-in wins over the unit, so an old one silently overrode a
# config edit. The config is the owner here: a drop-in that disagrees is brought
# back in line, and the run says which value is now in force.
TIMER_DROPIN="$UNIT_DIR/$UNIT_NAME.timer.d/interval.conf"
# The comparison reads the whole value, not just a <digits>min spelling.
# systemd accepts "30" (thirty seconds), "2h", "90s" and " 5min " alike, and the
# old pattern matched none of those, so a hand-written drop-in kept overriding
# INTERVAL_MIN with nothing said: OnUnitInactiveSec=30 is a sync every thirty
# seconds. Anything that is not exactly the config's spelling is rewritten, and
# what the drop-in said is printed as it was written rather than with "min"
# glued on.
if [ -f "$TIMER_DROPIN" ]; then
    dropin_interval="$(sed -n \
        's/^[[:space:]]*OnUnitInactiveSec=\(.*\)$/\1/p' \
        "$TIMER_DROPIN" | tail -1)"
    # Trailing whitespace and a trailing comment are not part of the value.
    dropin_interval="${dropin_interval%%#*}"
    dropin_interval="${dropin_interval%"${dropin_interval##*[![:space:]]}"}"
    if [ -n "$dropin_interval" ] && [ "$dropin_interval" != "${INTERVAL_MIN}min" ]; then
        sed -i "s|^[[:space:]]*OnUnitInactiveSec=.*|OnUnitInactiveSec=${INTERVAL_MIN}min|" \
            "$TIMER_DROPIN"
        say "timer drop-in said \"${dropin_interval}\"; it now says ${INTERVAL_MIN}min, so INTERVAL_MIN in $CONFIG_DIR/config is what runs"
    elif [ -n "$dropin_interval" ]; then
        say "timer drop-in and INTERVAL_MIN agree on ${INTERVAL_MIN}min"
    fi
fi

# A UNIT_NAME that changed between installs leaves the old unit pair behind
# still enabled, and nothing said so. The timer is the entry point systemd
# starts, but naming only the timer was half a warning: the timer starts
# <name>.service, and <name>-watch.service is a loop that goes on syncing by
# itself, so a user who did what the line said kept a second sync path alive and
# never heard about it. Every file this installer writes under a unit name is
# listed, and the command that turns the pair off names both halves, which is
# what uninstall.sh already does. A unit name whose service runs something other
# than this project's scripts belongs to something else in the same directory,
# and this install is not the one to point at it. The search names the scripts
# rather than today's $BIN_DIR, because a reinstall under a different --prefix is
# the same migration: anchoring it to the prefix in use found nothing and said
# nothing.
for sibling in "$UNIT_DIR"/*.timer; do
    [ -e "$sibling" ] || continue
    sibling_name="$(basename "$sibling")"
    [ "$sibling_name" = "$UNIT_NAME.timer" ] && continue
    sibling_unit="${sibling_name%.timer}"
    grep -qE 'onedrive-(sync|watch)' "$UNIT_DIR/$sibling_unit.service" 2>/dev/null ||
        continue
    warn "$sibling_name is not the configured unit name; an earlier install of this script left it behind:"
    for part in "$sibling_unit.service" "$sibling_name" \
                "$sibling_unit-watch.service" "$sibling_name.d"; do
        if [ -e "$UNIT_DIR/$part" ]; then
            warn "    $UNIT_DIR/$part"
        fi
    done
    warn "    systemctl --user disable --now $sibling_name $sibling_unit-watch.service"
done

# --------------------------------------------------------------- autostart
# Exec= in a desktop entry is not a shell word list: the value is split on
# spaces, so an unquoted tray path under a prefix like "/home/x/My Files" became
# two arguments and the tray never started at login. The Desktop Entry
# specification wants such an argument enclosed in double quotes, with the double
# quote, backtick, dollar and backslash escaped inside it, and a literal percent
# written as %% because a single one is a field code. A path made only of
# unreserved characters is left bare, which is how the entry read before.
#
# The quoting layer is only half of it. A desktop entry is a key file, and the
# key-file reader unescapes the value once more before the Exec parser sees it, so
# the specification's general string-value rule doubles every backslash the
# quoting layer left behind. Without that second pass GLib refuses the file with
# "Key file contains key Exec which has a value that cannot be interpreted", and
# the desktop never starts the tray. This is the same rule the tray's own
# desktop_exec() applies; the two copies are pinned against GLib by the same list
# of paths in tests/install-flow.sh and tests/tray.sh.
desktop_exec_arg() {  # desktop_exec_arg <path> -> the Exec argument
    local arg="$1"
    arg="${arg//%/%%}"
    case "$arg" in
        *[!A-Za-z0-9/._+:=@,^-]*)
            arg="${arg//\\/\\\\}"
            arg="${arg//\"/\\\"}"
            arg="${arg//\`/\\\`}"
            arg="${arg//\$/\\\$}"
            arg="${arg//\\/\\\\}"
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
if [ -f "$AUTOSTART_FILE" ] && foreign_exec "$AUTOSTART_FILE"; then
    # One entry per desktop, and it holds an absolute Exec. Rewriting it here would
    # repoint a login that starts another prefix's tray.
    warn "leaving $AUTOSTART_FILE alone: it starts a different prefix, not $BIN_DIR/onedrive-tray"
elif [ "${#tray_missing[@]}" -gt 0 ]; then
    # An entry left behind by an earlier install would have the desktop try to
    # start a tray whose GTK stack is gone, once per login. Saying nothing about
    # it while leaving it there is the worst of both.
    if [ -f "$AUTOSTART_FILE" ]; then
        rm -f "$AUTOSTART_FILE"
        say "removed the autostart entry: the tray cannot run without the packages above"
    else
        say "no autostart entry: the tray cannot run without the packages above"
    fi
elif [ "$CONFIG_EXISTED" -eq 1 ] && [ "$TRAY_WAS_INSTALLED" -eq 1 ] &&
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
    # The real home comes from the password database, because a test that
    # redirects HOME is not the user this machine-wide hook would act for; the
    # override is what lets a test take the install path without /etc.
    real_home="${REAL_HOME_OVERRIDE:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}"
    if [ -n "$real_home" ] && [ "$HOME" != "$real_home" ]; then
        # This used to say "it is not installed" and then install it anyway: the
        # guard set NM_DISPATCHER=0 and the rest of the block ran regardless, so a
        # redirected HOME still wrote a machine-wide hook naming the unit of a
        # scratch config. Nothing below runs now.
        warn "HOME is redirected to $HOME while this hook is machine-wide."
        warn "It would start $UNIT_NAME.timer for the real user, so it is not installed."
        NM_DISPATCHER=0
    else
        if [ "$PREFIX" != "$HOME/.local" ]; then
            warn "this hook is machine-wide and will start $UNIT_NAME.timer,"
            warn "which lives outside $HOME/.local. Install the units normally if that is"
            warn "not what you meant."
        fi
        NM_TARGET="$NM_DISPATCHER_DIR/90-rclone-onedrive-tray"
        NM_TMP="$(mktemp)"
        # The value is escaped for sed like every other substitution in this
        # file. The unit-name check above is what keeps a shell expansion out of
        # the hook; this keeps sed's own metacharacters from reaching it.
        sed -e "s|%UNIT_NAME%|$(sed_replacement "$UNIT_NAME")|g" \
            "$SRC_DIR/extras/networkmanager-dispatcher.sh" > "$NM_TMP"
        if [ -d "$NM_DISPATCHER_DIR" ]; then
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
            warn "no $NM_DISPATCHER_DIR on this system; skipping."
            warn "NetworkManager will re-sync on the next timer tick instead."
        fi
        [ -n "$NM_TMP" ] && rm -f "$NM_TMP"
    fi
fi

# --------------------------------------------------------------- enable
if [ "$UNIT_IS_OTHER" = 1 ]; then
    # The units belong to another prefix, and `enable --now` is not a no-op on one
    # that was deliberately switched off: it would put that install back on a
    # schedule its owner took it off. The run says so and leaves the manager alone.
    warn "nothing enabled: the units at $UNIT_DIR belong to another install"
elif systemctl --user daemon-reload 2>/dev/null; then
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
        # systemctl's own sentence is the only thing that says why an enable
        # failed. It used to be thrown away and replaced with a guess ("no user
        # systemd session?"), so a masked or missing unit read as a manager
        # problem, and the repair command below was printed only by the other
        # branch. A failure now says what systemctl said and names the fix.
        enable_err="$(systemctl --user enable --now "$UNIT_NAME.timer" 2>&1)" || {
            warn "could not enable $UNIT_NAME.timer: ${enable_err:-systemctl printed nothing}"
            warn "run this yourself once the manager can see the unit:"
            warn "    systemctl --user daemon-reload && systemctl --user enable --now $UNIT_NAME.timer"
        }
        systemctl --user list-timers "$UNIT_NAME.timer" --no-pager 2>/dev/null | head -3 || true
        if watch_on "$WATCH" && [ "$HAVE_INOTIFY" -eq 1 ]; then
            watch_err="$(systemctl --user enable --now "$UNIT_NAME-watch.service" 2>&1)" || {
                warn "could not enable $UNIT_NAME-watch.service: ${watch_err:-systemctl printed nothing}"
                warn "    systemctl --user enable --now $UNIT_NAME-watch.service"
            }
            # enable --now is a no-op on a unit that is already active, and the
            # watcher is a long-running loop, so an update would leave the old
            # code running until reboot. try-restart touches only a running unit
            # and does nothing when it is not there. A refused restart used to
            # go to /dev/null, so this run reported a healthy watcher while the
            # process kept the code the update replaced.
            restart_err="$(systemctl --user try-restart "$UNIT_NAME-watch.service" 2>&1)" || {
                warn "could not restart $UNIT_NAME-watch.service: ${restart_err:-systemctl printed nothing}"
                warn "an already-running watcher keeps the code it started with:"
                warn "    systemctl --user restart $UNIT_NAME-watch.service"
            }
        elif watch_on "$WATCH"; then
            : # inotifywait is missing; the unit exists but cannot run (warned above)
        else
            # WATCH was turned off, by hand or through the wizard, and nothing
            # used to stop a watcher that was already running. The sentence
            # below is only true when systemctl agreed: it used to be printed
            # after a `|| true`, so a refused disable read as a done one.
            if disable_err="$(systemctl --user disable --now "$UNIT_NAME-watch.service" 2>&1)"; then
                say "watcher disabled: WATCH is off in $CONFIG_DIR/config"
            else
                warn "could not disable $UNIT_NAME-watch.service: ${disable_err:-systemctl printed nothing}"
                warn "WATCH is off in $CONFIG_DIR/config, so it must not run; stop it yourself with:"
                warn "    systemctl --user disable --now $UNIT_NAME-watch.service"
            fi
        fi
    fi
else
    warn "systemctl --user is unavailable; enable the timer yourself after logging in:"
    warn "    systemctl --user enable --now $UNIT_NAME.timer"
fi

# --------------------------------------------------------------- done
# The summary reads $SCRIPTS, the list the install loop above iterates, so the
# two cannot disagree about what was installed. Three per line is only a layout
# choice here; adding a script to the list adds it to both places at once.
scripts_summary() {
    local i=0 script
    printf '  scripts   '
    for script in "${SCRIPTS[@]}"; do
        if [ "$i" -gt 0 ]; then
            if [ $((i % 3)) -eq 0 ]; then
                printf '\n            '
            else
                printf ', '
            fi
        fi
        printf '%s/%s' "$BIN_DIR" "${script##*/}"
        i=$((i + 1))
    done
    printf '\n'
}

# The summary names what this run installed. A run that left another prefix's units and
# entry alone said so in warnings above; repeating them here as "units ..." and "autostart
# ..." told the user twice over that they were installed here, and the difference between
# the two is a working install and a broken one.
units_line="  units     $UNIT_DIR/$UNIT_NAME.{service,timer}
            ${UNIT_DIR}/${UNIT_NAME}-watch.service (realtime; enabled when WATCH=1)"
autostart_line="  autostart $AUTOSTART_DIR/rclone-onedrive-tray.desktop"
if [ "$UNIT_IS_OTHER" = 1 ]; then
    units_line="  units     left alone: $UNIT_DIR/$UNIT_NAME.* belongs to another prefix"
fi
if [ -f "$AUTOSTART_FILE" ] && foreign_exec "$AUTOSTART_FILE"; then
    autostart_line="  autostart left alone: $AUTOSTART_FILE starts another prefix's tray"
fi

cat <<EOF

$(say "Installed")

$(scripts_summary)
  config    $CONFIG_DIR/config
  filters   $CONFIG_DIR/filters.txt
$units_line
$autostart_line

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
