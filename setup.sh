#!/usr/bin/env bash
#
# setup.sh: first-run configuration for rclone-onedrive-tray.
#
# Walks through the four choices that matter (which remote, which folder, where
# to keep it locally, what to leave out), writes the config, then hands over to
# install.sh. Run it before touching the config by hand.
#
#   ./setup.sh                                  interactive
#   ./setup.sh --remote onedrive:Notes \
#              --local ~/OneDrive --filters obsidian --yes     non-interactive
#   ./setup.sh --help
#
# Non-interactive flags:
#   --remote REMOTE[:PATH]   rclone remote, optionally with a sub-path
#   --local DIR              local directory to sync into
#   --filters default|obsidian|none
#   --interval MIN           minutes between timer runs (default 5)
#   --watch yes|no           enable realtime sync (default yes)
#   --unit-name NAME         systemd unit base name (default onedrive-sync)
#   --skip-folders "A,B"     top-level folders to leave off this machine
#   --yes                    do not prompt for anything; the flags are the
#                            answer, so an existing config is overwritten
#   --no-install             write the config only, do not run install.sh
#
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rclone-onedrive-tray"
CONFIG_FILE="$CONFIG_DIR/config"
FILTERS_FILE="$CONFIG_DIR/filters.txt"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rclone-onedrive-tray"

REMOTE_IN=""
LOCAL_IN=""
FILTERS_CHOICE=""
INTERVAL="5"
WATCH="yes"
UNIT_NAME="onedrive-sync"
SKIP_FOLDERS=""
ASSUME_YES=0
DO_INSTALL=1
# Whether the choice came from the command line (or a real answer at the
# prompt) rather than from ask() handing back its default. Only an explicit
# choice may replace a file that is already there.
FILTERS_GIVEN=0
SKIP_FOLDERS_GIVEN=0
# The two settings below reach the template as values, not as files, but they are
# the user's the same way the carried keys are: a re-run that does not mention
# them must leave what the config already has. The flags are what overrides.
INTERVAL_GIVEN=0
WATCH_GIVEN=0

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
# A usage error exits 2, the same status install.sh gives one, so a script can
# tell "I called it wrong" from "it ran and failed". A missing value is a bash
# ":?" error and keeps bash's status; both are named now.
usage_error() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 2; }

# The config file is read back with `.` by onedrive-sync, so a value holding a
# quote, a dollar or a backtick has to be escaped or it sources to something
# else. bin/onedrive-tray escapes the same four characters when its settings
# dialog writes the same file.
config_quote() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\"/\\\"}"
    text="${text//\$/\\\$}"
    text="${text//\`/\\\`}"
    printf '%s' "$text"
}

# The help is this file's header comment, up to the first line that is not a
# comment, so it cannot go stale when the block changes size.
usage() { sed -n '2,/^[^#]/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --remote)     REMOTE_IN="${2?--remote needs a value}"; shift 2 ;;
        --local)      LOCAL_IN="${2?--local needs a value}"; shift 2 ;;
        --filters)    FILTERS_CHOICE="${2?--filters needs a value}"; FILTERS_GIVEN=1; shift 2 ;;
        --interval)   INTERVAL="${2?--interval needs a value}"; INTERVAL_GIVEN=1; shift 2 ;;
        --watch)      WATCH="${2?--watch needs a value}"; WATCH_GIVEN=1; shift 2 ;;
        --unit-name)  UNIT_NAME="${2?--unit-name needs a value}"; shift 2 ;;
        --skip-folders) SKIP_FOLDERS="${2?--skip-folders needs a value}"; SKIP_FOLDERS_GIVEN=1; shift 2 ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        --no-install) DO_INSTALL=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage_error "unknown option: $1 (try --help)" ;;
    esac
done

# systemd accepts letters, digits, ':', '_', '.', '-' and '@' in a unit name, and
# nothing else; a space or a slash makes a unit file the manager refuses to load
# and the failure then shows up as a confusing message about the user manager.
# The interval reaches the timer template verbatim, so 0 or a word there makes a
# timer that never fires, or one systemd rejects.
case "$UNIT_NAME" in
    ''|*[!A-Za-z0-9:_.@-]*)
        die "invalid --unit-name value: '$UNIT_NAME' (allowed: letters, digits, and : _ . - @)" ;;
    .*)
        die "invalid --unit-name value: '$UNIT_NAME' (a unit name must not start with a dot)" ;;
esac
case "$INTERVAL" in
    ''|*[!0-9]*)
        die "invalid --interval value: '$INTERVAL' (a whole number of minutes is required)" ;;
esac
[ -n "${INTERVAL//0/}" ] ||
    die "invalid --interval value: '$INTERVAL' (it must be at least 1 minute)"

ask() {  # ask <prompt> <default>  -> echoes the answer
    local prompt="$1" default="$2" reply
    if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
        printf '%s\n' "$default"
        return
    fi
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " reply
    else
        read -r -p "$prompt: " reply
    fi
    printf '%s\n' "${reply:-$default}"
}

# config.example documents RCLONE as "the rclone binary to run, by name or by
# path", and install.sh reads it before it probes for rclone. The wizard is the
# first thing a user runs on a new machine, so it reads the same key: otherwise
# ./setup.sh refuses a machine whose rclone is outside PATH while the wrapper it
# installs would have worked. The key is read here because the config may already
# exist from an earlier run; on a bare machine there is nothing to read and the
# plain name is the only honest answer.
#
# Read through the same reader the installers use, so this key and the copy
# carry() writes back cannot disagree about the file: this one stripped at the
# first `"`, and would hand rclone a path the running install did not use.
# shellcheck source=lib/config.sh
. "$SRC_DIR/lib/config.sh"
RCLONE_BIN="$(config_value_from "$(cat "$CONFIG_DIR/config" 2>/dev/null || true)" RCLONE)"
RCLONE_BIN="${RCLONE_BIN:-rclone}"

command -v "$RCLONE_BIN" >/dev/null 2>&1 ||
    die "$RCLONE_BIN is not installed. See https://rclone.org/downloads/"

say "rclone-onedrive-tray setup"

# A config this run creates is a first install; one that is already there is an
# upgrade, and the two want different defaults for the access check below. The
# answer is taken before the overwrite question, because both branches rewrite
# the file.
CONFIG_EXISTED=0
[ -f "$CONFIG_FILE" ] && CONFIG_EXISTED=1

if [ -f "$CONFIG_FILE" ]; then
    warn "a config already exists: $CONFIG_FILE"
    # ask() answers with the default without reading anything under --yes or
    # when stdin is not a terminal, so the default is the answer in those runs.
    # With "n" there, --yes answered its own question with no and the only way
    # left to re-run the wizard was to delete the config by hand. --yes is an
    # instruction not to ask, and the flags beside it are what to do instead.
    # An interactive run keeps the "n" default and still stops on a bare Enter.
    overwrite_default=n
    [ "$ASSUME_YES" -eq 1 ] && overwrite_default=y
    case "$(ask 'Overwrite it? (y/N)' "$overwrite_default")" in
        [yY]*) : ;;
        *)     die "aborted; delete the file yourself to start over" ;;
    esac
fi

# --------------------------------------------------------------- 1. the remote
# A listing that failed is not a machine with no remotes. The stderr used to go
# to /dev/null, so an rclone that could not read its own config (a permission
# problem on rclone.conf, say) was reported as "No rclone remotes are configured
# yet" and the reader was sent to create a remote they already had.
remotes_err_file="$(mktemp)"
if ! REMOTES="$("$RCLONE_BIN" listremotes 2>"$remotes_err_file")"; then
    remotes_err="$(tail -1 "$remotes_err_file")"
    rm -f "$remotes_err_file"
    die "$RCLONE_BIN listremotes failed, so no remote could be listed: ${remotes_err:-it printed nothing to stderr}"
fi
rm -f "$remotes_err_file"
if [ -z "$REMOTES" ]; then
    echo
    warn "No rclone remotes are configured yet."
    echo "    Creating one needs a browser to authorise your Microsoft account."
    echo "    Step by step, including work accounts and machines without a browser:"
    echo "        docs/SIGNING-IN.md"
    if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
        # The sign-in is interactive: it opens a browser and waits. Starting it
        # from a non-interactive run would block forever with nothing written.
        die "no rclone remote, and this run cannot open a browser for you.
    Create one first:      $RCLONE_BIN config create onedrive onedrive
    Or for a trial with no account at all:
                          $RCLONE_BIN config create trial alias remote /tmp/onedrive-trial
    Then re-run this script."
    fi
    name="$(ask 'Name for the new remote' 'onedrive')"
    say "Running: $RCLONE_BIN config create $name onedrive"
    echo "    (rclone will open your browser; complete the sign-in there)"
    if "$RCLONE_BIN" config create "$name" onedrive; then
        REMOTES="$("$RCLONE_BIN" listremotes 2>/dev/null)"
    else
        die "could not create the remote; see docs/SIGNING-IN.md, or run '$RCLONE_BIN config' by hand and re-run this script"
    fi
fi

if [ -z "$REMOTE_IN" ]; then
    echo
    echo "Configured remotes:"
    while IFS= read -r line; do
        [ -n "$line" ] && printf '  %s\n' "$line"
    done <<< "$REMOTES"
    REMOTE_IN="$(ask 'Which one should be synced?' "$(printf '%s' "$REMOTES" | head -1)")"
fi

# Split "remote:path" so the path can be offered separately.
remote_name="${REMOTE_IN%%:*}"
remote_path="${REMOTE_IN#*:}"
[ "$remote_path" = "$REMOTE_IN" ] && remote_path=""
[ -n "$remote_name" ] || die "no remote given"
"$RCLONE_BIN" listremotes | grep -qx "${remote_name}:" ||
    die "unknown remote: ${remote_name} (see '$RCLONE_BIN listremotes')"

# --------------------------------------------------------------- 2. the folder
if [ -z "$remote_path" ] && [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
    echo
    say "Top level of ${remote_name}: (picking nothing syncs the whole drive)"
    "$RCLONE_BIN" lsd "${remote_name}:" 2>/dev/null | head -20 | awk '{ $1=""; $2=""; $3=""; $4=""; sub(/^ +/,""); print "  " $0 }'
    remote_path="$(ask 'Sub-folder to sync (blank = everything)' '')"
fi

REMOTE="${remote_name}:${remote_path}"

# --------------------------------------------------------------- 3. local dir
if [ -z "$LOCAL_IN" ]; then
    leaf="${remote_path##*/}"
    LOCAL_IN="$(ask 'Local directory' "$HOME/OneDrive${leaf:+/$leaf}")"
fi
LOCAL_IN="${LOCAL_IN/#\~/$HOME}"

# --------------------------------------------------------------- 4. filters
if [ -z "$FILTERS_CHOICE" ]; then
    echo
    echo "Exclusions. The defaults skip caches and per-machine state:"
    echo "  - /.rag/**                     regenerated vector indexes"
    echo "  - /.obsidian/workspace.json    editor layout that fights between machines"
    FILTERS_CHOICE="$(ask 'Use them? (default/none)' 'default')"
    # An answer typed at the prompt is a choice. The default ask() returns
    # without prompting anything (--yes, or no terminal) is not: a scripted
    # re-run has to leave a hand-written file alone.
    if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
        FILTERS_GIVEN=1
    fi
fi

mkdir -p "$CONFIG_DIR"

# --------------------------------------------------------------- 4b. folders
# Everything syncs by default; this is where you drop the folders you do not
# want on this machine. The cloud keeps them either way.
EXCLUDE_FOLDERS_FILE="$CONFIG_DIR/exclude-folders.txt"
if [ -z "$SKIP_FOLDERS" ] && [ "$SKIP_FOLDERS_GIVEN" -eq 0 ] &&
        [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
    echo
    say "Folders inside $REMOTE"
    listing="$("$RCLONE_BIN" lsf --dirs-only --max-depth 1 "$REMOTE" 2>/dev/null | sed 's:/$::')"
    if [ -n "$listing" ]; then
        printf '%s\n' "$listing" | nl -w2 -s') ' | sed 's/^/  /'
        echo "  Everything is synced unless you say otherwise here."
        SKIP_FOLDERS="$(ask 'Folders to LEAVE OFF this machine (comma separated)' '')"
        SKIP_FOLDERS_GIVEN=1
    else
        echo "  (none found, or the remote is empty)"
    fi
fi

# Both files are hand-edited between runs, so a run that did not ask for a
# replacement keeps what is there. install.sh already treats them that way; the
# wizard used to truncate the list and copy the example over the filters on
# every scripted re-run.
kept=()
if [ "$SKIP_FOLDERS_GIVEN" -eq 0 ] && [ -f "$EXCLUDE_FOLDERS_FILE" ]; then
    kept+=("$EXCLUDE_FOLDERS_FILE")
else
    : > "$EXCLUDE_FOLDERS_FILE"
    if [ -n "$SKIP_FOLDERS" ]; then
        # Both readers of this file drop a line starting with # and strip the
        # line's edges, so a folder named "#Archive" was written as a comment:
        # the menu showed it as excluded while the sync kept running. The tray
        # refuses that name with an explanation (exclusion_problem) and this is
        # the same rule, so a name the file cannot express is named and left out
        # instead of being written as a line nobody reads. The edges are trimmed
        # first because the readers trim them too, which is the only reading of
        # " Notes" that can be expressed at all.
        rest="$SKIP_FOLDERS"
        while [ -n "$rest" ]; do
            case "$rest" in
                *,*) item="${rest%%,*}"; rest="${rest#*,}" ;;
                *)   item="$rest"; rest="" ;;
            esac
            name="$(printf '%s' "$item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            [ -n "$name" ] || continue
            case "$name" in
                '#'*)            problem="a name starting with # is read as a comment" ;;
                *$'\n'*|*$'\r'*) problem="the folder name has a line break in it" ;;
                *)               problem="" ;;
            esac
            if [ -n "$problem" ]; then
                warn "Cannot leave $name out of the sync: $problem"
                continue
            fi
            printf '%s\n' "$name" >> "$EXCLUDE_FOLDERS_FILE"
            if [ -n "${listing:-}" ] && ! printf '%s\n' "$listing" | grep -qxF "$name"; then
                warn "no folder named '$name' at the top level of $REMOTE"
            fi
        done
    fi
fi

if [ "$FILTERS_GIVEN" -eq 0 ] && [ -f "$FILTERS_FILE" ]; then
    kept+=("$FILTERS_FILE")
else
    case "$FILTERS_CHOICE" in
        obsidian|default) cp -f "$SRC_DIR/config/filters.example" "$FILTERS_FILE" ;;
        none)             printf '# no exclusions\n' > "$FILTERS_FILE" ;;
        *)                die "unknown --filters value: $FILTERS_CHOICE" ;;
    esac
fi

# Keys the wizard does not ask about are carried over from a config that is already
# there. It used to write the whole file from this template, so a re-run reset every
# value it did not prompt for (a bandwidth cap, an access check, the log size, the
# notification setting) and dropped the keys it did not know about at all, RCLONE
# among them, which is the one a user sets to point at a build outside PATH. The
# flags own REMOTE, LOCAL, UNIT_NAME, INTERVAL_MIN, WATCH and the two file paths;
# everything else is the user's unless the file gives no value for it.
#
# The file is read into a variable first because the redirection on the heredoc
# below truncates it before any command substitution inside the body runs, so a
# carry() that read the path would find an empty file. That snapshot goes through
# config_value_from(), the same reader install.sh and uninstall.sh use, so a value
# the tray escaped is read back the way the wrapper reads it: the copy that used to
# live here stripped at the first `"` and at any `#`, and a re-run of the wizard
# wrote the truncated path into the config.
#
# The flag string below is the same one bin/onedrive-sync ships as its default, and
# tests/docs.sh compares this constant with that one and with config.example. It is
# a constant rather than an inline value because the template writes whatever the
# config already had.
DEFAULT_BISYNC_ARGS="--resilient --recover --max-lock 2m --conflict-resolve none --conflict-loser num --stats 2s"
OLD_CONFIG="$(cat "$CONFIG_FILE" 2>/dev/null || true)"
carry_assign() {  # carry_assign <KEY> <default> -> the whole assignment, as written
    # The old file's own line for this key, so what it already quoted stays quoted
    # the way it was. Reading the value and writing it back through config_quote()
    # escaped the `$` of a value like LOG="${XDG_CACHE_HOME:-$HOME/.cache}/sync.log",
    # and the wrapper then read a literal directory name where it used to expand one:
    # a wizard re-run broke the log path of an install that was working. A key the
    # file does not set gets the default, quoted the way every written value is.
    local key="$1" default="$2" line
    line="$(printf '%s\n' "$OLD_CONFIG" |
        grep -E "^[[:space:]]*(export[[:space:]]+)?$key=" | tail -1 |
        sed -e 's/^[[:space:]]*//' -e 's/^export[[:space:]]\{1,\}//')"
    # Only a line that is the whole assignment is carried: the key, then either one
    # double-quoted string with no quote or backslash inside it, or a bare word of
    # characters a value plausibly uses. Anything else falls back to the value the
    # reader can see, which is what the writer did before. A value written over two
    # lines is valid shell, and copying only its first line produced a config that
    # was not: measured on the version that took any matching line,
    # OPEN_APP_CMD="one<newline>two" came back with the first line alone, bash -n
    # refused the result, and the wizard still printed "Wrote". A trailing comment,
    # a continuation, a CR and an unterminated quote are excluded the same way, and
    # bash -n below is the net for anything this pattern still lets through.
    if ! printf '%s' "$line" |
            grep -qE "^${key}=(\"([^\"\\\\]*)\"|[A-Za-z0-9_@%+=:,./-]*)$"; then
        line=""
    fi
    if [ -n "$line" ]; then
        printf '%s' "$line"
    else
        # The value the reader can see, quoted the way every written value is, so a
        # line this function will not copy whole is still carried the way the writer
        # carried it before: a multi-line value and a broken quote both come back as
        # the empty string the reader answers, not as the template default.
        printf '%s="%s"' "$key" "$(config_quote "$(carry "$key" "$default")")"
    fi
}

carry() {  # carry <KEY> <default> -> the value already in the config, or the default
    local key="$1" default="$2"
    # An empty quoted value is a value, so only a key the file does not set at all
    # falls back to the default; the reader answers "" for both, which is why the
    # presence of the key is asked about first.
    if printf '%s\n' "$OLD_CONFIG" |
            grep -qE "^[[:space:]]*(export[[:space:]]+)?$key="; then
        config_value_from "$OLD_CONFIG" "$key"
    else
        printf '%s' "$default"
    fi
}

# The interval and the realtime switch are carried over by the same rule as the
# keys above when the run did not ask for them. Written from the template
# unconditionally, they reset a changed interval to 5 and turned realtime sync
# back on during a documented re-run that passed only --remote/--local/--unit-name,
# while every key beside them was preserved. Measured by a reviewer:
# INTERVAL_MIN="15" and WATCH="0" became "5" and "1".
if [ "$INTERVAL_GIVEN" -eq 0 ]; then
    INTERVAL="$(carry INTERVAL_MIN 5)"
fi
if [ "$WATCH_GIVEN" -eq 1 ]; then
    WATCH="$([ "$WATCH" = "yes" ] && echo 1 || echo 0)"
else
    WATCH="$(carry WATCH 1)"
fi

# Written to a side file and moved into place only once bash agrees it is shell.
# The heredoc carries the old file's own lines through, so a value this project has
# never seen is a way to write a config nothing can source; refusing leaves the
# previous file untouched instead.
CONFIG_NEW="$CONFIG_FILE.new$$"
cat > "$CONFIG_NEW" <<EOF
# Written by setup.sh on $(date '+%Y-%m-%d %H:%M')
REMOTE="$(config_quote "$REMOTE")"
LOCAL="$(config_quote "$LOCAL_IN")"
UNIT_NAME="$(config_quote "$UNIT_NAME")"
INTERVAL_MIN="$INTERVAL"
$(carry_assign MAX_DELETE 100)
# Bandwidth cap in rclone size syntax (1M, 500k, 1.5M). Empty means unlimited.
$(carry_assign BW_LIMIT "")
# The access check aborts a run when the marker file is missing on one side,
# which is what a network or mount problem looks like from the other side. Off
# until you create the markers: onedrive-check-access
$(carry_assign CHECK_ACCESS 0)
$(carry_assign CHECK_FILENAME "")
$(carry_assign BISYNC_ARGS "$DEFAULT_BISYNC_ARGS")
FILTERS_FILE="$(config_quote "$FILTERS_FILE")"
EXCLUDE_FOLDERS_FILE="$(config_quote "$EXCLUDE_FOLDERS_FILE")"

$(carry_assign LOG "$CACHE_DIR/sync.log")
$(carry_assign OPEN_APP_CMD "")
$(carry_assign OPEN_APP_NAME "the app")
$(carry_assign UI_LANG "")

WATCH="$WATCH"
$(carry_assign WATCH_DEBOUNCE 8)
$(carry_assign WATCH_SETTLE 12)
$(carry_assign WATCH_EXCLUDE "")

$(carry_assign RETRIES 3)
$(carry_assign RETRY_DELAY 60)
$(carry_assign MAX_LOG_BYTES 5242880)
$(carry_assign SHOW_ICON 1)
$(carry_assign NOTIFY_ON_SUCCESS 1)
# The rclone binary to run, by name or by path.
$(carry_assign RCLONE "")
EOF
if ! bash -n "$CONFIG_NEW" 2>"$CONFIG_FILE.syntax"; then
    printf '%s\n' "$(sed -n '1,3p' "$CONFIG_FILE.syntax")" >&2
    rm -f "$CONFIG_NEW" "$CONFIG_FILE.syntax"
    die "refusing to replace $CONFIG_FILE: the config this run would write is not shell (the line above is bash's complaint). The file on disk is unchanged."
fi
rm -f "$CONFIG_FILE.syntax"
chmod 0644 "$CONFIG_NEW" "$FILTERS_FILE"
mv -f "$CONFIG_NEW" "$CONFIG_FILE"

echo
say "Wrote $CONFIG_FILE"
printf '  %-14s %s\n' "remote" "$REMOTE"
printf '  %-14s %s\n' "local" "$LOCAL_IN"
printf '  %-14s %s\n' "interval" "$INTERVAL min"
printf '  %-14s %s\n' "realtime" "$WATCH"
printf '  %-14s %s\n' "filters" "$FILTERS_FILE ($(grep -c '^-' "$FILTERS_FILE") rules)"

# Say what was left alone, so a scripted re-run never looks like it rewrote a
# file it silently kept.
for kept_file in "${kept[@]}"; do
    warn "kept the existing $(basename "$kept_file"): $kept_file"
done
if [ "${#kept[@]}" -gt 0 ]; then
    warn "  pass --filters / --skip-folders to replace them"
fi

# --------------------------------------------------------------- access check
# The helper rewrites one key in the config this run just wrote. The heredoc above
# has already run carry(), so a re-run's CHECK_ACCESS survived it; this is the one
# place a fresh install can end up with 1, and the value is written here rather
# than from a second template so the keys around it are not written twice.
set_config_key() {  # set_config_key <KEY> <value>
    local key="$1" value="$2" tmp="$CONFIG_FILE.tmp$$"
    awk -v k="$key" -v v="$value" '
        $0 ~ "^" k "=" { print k "=\"" v "\""; next }
        { print }
    ' "$CONFIG_FILE" > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$CONFIG_FILE"
}

# LOCAL is where the sync goes, and a first install names a directory that does
# not exist yet. bin/onedrive-sync refuses a missing LOCAL rather than creating it
# (a typo or an unmounted share would otherwise become the sync root), so a wizard
# that writes this path is what has to create it, and only on the run that creates
# the config: a re-run whose tree is gone is the trap, not the first install.
if [ "$CONFIG_EXISTED" -eq 0 ] && [ ! -d "$LOCAL_IN" ]; then
    mkdir -p "$LOCAL_IN" && say "Created the local sync directory: $LOCAL_IN"
fi

# CHECK_ACCESS is the only guard that stops a run treating an unreadable side as
# a mass deletion, and it ships off because turning it on for a config that
# already exists aborts that install's next run until the marker files are there.
# A config this run creates has no such history, so the offer belongs here and
# nowhere else. The markers are not built inline: onedrive-check-access is the
# helper that knows the file name, both sides and the rclone calls.
if [ "$CONFIG_EXISTED" -eq 0 ]; then
    CHECK_WANTED=0
    if [ "$ASSUME_YES" -eq 1 ]; then
        # The markers are written to the remote, and --yes is an instruction not
        # to be asked about side effects, so the answer is the quiet one and the
        # command to do it later is named, as the first-sync prompt does.
        echo "    With --yes the access check is left to you:  onedrive-check-access"
    elif [ ! -t 0 ]; then
        echo "    With no terminal to answer the prompt the access check is left to you:  onedrive-check-access"
    else
        case "$(ask 'Create the access-check marker files now? (Y/n)' 'y')" in
            [yY]*) CHECK_WANTED=1 ;;
        esac
    fi
    if [ "$CHECK_WANTED" -eq 1 ]; then
        if ! "$SRC_DIR/bin/onedrive-check-access"; then
            warn "the marker files were not created; CHECK_ACCESS stays \"0\""
        elif set_config_key CHECK_ACCESS 1; then
            say "Access check on: CHECK_ACCESS=\"1\" in $CONFIG_FILE"
        else
            warn "the marker files are there but CHECK_ACCESS could not be written; set it by hand in $CONFIG_FILE"
        fi
    fi
fi

if [ "$DO_INSTALL" -eq 1 ]; then
    echo
    say "Installing"
    "$SRC_DIR/install.sh" --no-start || die "install.sh failed"
fi

# --------------------------------------------------------------- first sync
# A wrapper this run did not install is not there to run: answering the (Y/n)
# prompt with its default used to invoke a missing file, which printed a shell
# error and then "Done" over it.
SYNC_WRAPPER="${PREFIX:-$HOME/.local}/bin/onedrive-sync"
echo
if [ ! -x "$SYNC_WRAPPER" ]; then
    say "skipping the first sync: $SYNC_WRAPPER is not installed"
else
    echo "The first sync builds the baseline and downloads everything, which can take"
    echo "a while on a large folder. It must not be interrupted."
    RUN_RESYNC=0
    if [ "$ASSUME_YES" -eq 1 ]; then
        # Never start a long, uninterruptible first sync off the back of --yes.
        echo "    With --yes this is left to you:  onedrive-sync --resync"
    elif [ ! -t 0 ]; then
        # The same reasoning, for the other way nobody is there to answer: ask()
        # hands back the prompt's default when stdin is not a terminal, and the
        # default here is yes. A wizard run from a script, a pipe or cron started
        # the full baseline sync on its own.
        echo "    With no terminal to answer the prompt this is left to you:  onedrive-sync --resync"
    else
        # The prompt advertises (Y/n), so both spellings of yes have to mean yes:
        # this compared the answer with "y" alone, and the capital it shows the user
        # meant "no".
        case "$(ask 'Run it now? (Y/n)' 'y')" in
            [yY]*) RUN_RESYNC=1 ;;
        esac
    fi
    if [ "$RUN_RESYNC" -eq 1 ]; then
        "$SYNC_WRAPPER" --resync
    fi
fi

echo
say "Done"
echo "    Start the tray:      onedrive-tray &"
echo "    Watch the log:       tail -f ~/.cache/rclone-onedrive-tray/sync.log"
echo "    Reconfigure later:   edit $CONFIG_FILE, then run 'onedrive-sync --resync'"
