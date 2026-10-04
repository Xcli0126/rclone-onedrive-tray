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
mkdir -p "$HOME" "$WORK/stubs" "$WORK/calls" "$LOCAL_DIR"

CFG_DIR="$XDG_CONFIG_HOME/rclone-onedrive-tray"
CFG="$CFG_DIR/config"
UNIT_DIR="$XDG_CONFIG_HOME/systemd/user"
CALLS="$WORK/rclone-calls"
SYSTEMCTL_CALLS="$WORK/systemctl-calls"

# The one thing this suite must not do for real is talk to a remote. bisync
# --help is the wrapper's one-off question about the flags this rclone knows,
# and this stub answers it the way the version it reports would: every flag the
# wrapper's default set needs, plus --resync-mode. It is answered here rather
# than recorded, because the recorded lines are the syncs and the cases below
# count them.
cat > "$WORK/stubs/rclone" <<EOF
#!/bin/bash
if [ "\$1" = bisync ] && [ "\$2" = --help ]; then
    printf '%s\\n' '      --recover                          Skip --resync and recover from an interrupted run'
    printf '%s\\n' '      --max-lock duration                Consider lock files older than this to be stale (default 2m0s)'
    printf '%s\\n' '      --conflict-resolve string          How to resolve conflicting files'
    printf '%s\\n' '      --conflict-loser string            What to do with the losing file'
    printf '%s\\n' '      --resync-mode string   During resync, prefer the version that is: path1, path2, newer, older, larger, smaller'
    exit 0
fi
case "\$1" in
    version)     echo "rclone v1.75.1" ;;
    listremotes)
        # A listing that fails is not a machine with no remotes. The marker is
        # what the wizard case below sets to get rclone's own refusal, which
        # setup.sh used to send to /dev/null.
        if [ -f "$WORK/calls/rclone-listremotes-fail" ]; then
            printf '%s\\n' 'CRITICAL: Failed to load config file: permission denied' >&2
            exit 1
        fi
        echo "probefake:" ;;
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
        disable)   printf '%s\\n' "\$*" >> "$SYSTEMCTL_CALLS"
                   # A user manager that refuses, which is what the marker is
                   # for: both install.sh and uninstall.sh used to send that
                   # refusal to /dev/null and print a success sentence over it.
                   [ -f "$WORK/calls/systemctl-disable-fail" ] &&
                       { printf '%s\\n' 'mock systemctl disable failure' >&2; exit 1; }
                   exit 0 ;;
        try-restart) printf '%s\\n' "\$*" >> "$SYSTEMCTL_CALLS"
                   [ -f "$WORK/calls/systemctl-restart-fail" ] &&
                       { printf '%s\\n' 'mock systemctl try-restart failure' >&2; exit 1; }
                   exit 0 ;;
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

# setup.sh read the remote list with `rclone listremotes 2>/dev/null`, so an
# rclone that could not read its own config was reported as a machine with no
# remotes at all, and the reader was told to create one. rclone's own sentence
# names the file and the reason, and it is the only signal there is.
title "a remote listing that fails"
LISTFAIL_HOME="$WORK/listfail-home"
rm -rf "$LISTFAIL_HOME"; mkdir -p "$LISTFAIL_HOME"
: > "$WORK/calls/rclone-listremotes-fail"
LISTFAIL_OUT="$(env HOME="$LISTFAIL_HOME" XDG_CONFIG_HOME="$LISTFAIL_HOME/.config" \
    XDG_CACHE_HOME="$LISTFAIL_HOME/.cache" \
    bash "$SRC_DIR/setup.sh" --yes --no-install \
        --remote "$REMOTE" --local "$LISTFAIL_HOME/OneDrive" 2>&1)"
rm -f "$WORK/calls/rclone-listremotes-fail"
if grep -qF 'permission denied' <<<"$LISTFAIL_OUT"; then
    ok "a failed remote listing is reported with rclone's own reason"
else
    bad "a failed remote listing was swallowed"
    printf '%s\n' "$LISTFAIL_OUT" | head -4 | sed 's/^/        /'
fi
if grep -qF 'No rclone remotes are configured yet' <<<"$LISTFAIL_OUT"; then
    bad "a failed listing was read as a machine with no remotes"
else
    ok "and it is not read as a machine with no remotes"
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

# The same re-run rewrote every key the wizard never asks about from its template,
# and dropped the ones its template did not know: a hand-set bandwidth cap, access
# check, log size, icon and notification setting were reset to their defaults on a
# documented re-run, and RCLONE, the key a user sets to point at a build outside
# PATH, was deleted. The flags own REMOTE, LOCAL, UNIT_NAME, INTERVAL_MIN, WATCH
# and the two file paths; the rest are the user's unless the file gives no value.
title "what the wizard keeps of the config it is not asking about"
HAND_HOME="$WORK/hand-home"
HAND_CFG="$HAND_HOME/.config/rclone-onedrive-tray/config"
rm -rf "$HAND_HOME"; mkdir -p "$HAND_HOME/.config/rclone-onedrive-tray" "$HAND_HOME/bin"
cat > "$HAND_HOME/bin/rclone-custom" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "$HOME/rclone-calls"
case "$1" in
    listremotes) echo "handfake:" ;;
    lsd) echo "          -1 2026-01-01 00:00:00        -1 Notes" ;;
    *) : ;;
esac
exit 0
STUB
chmod +x "$HAND_HOME/bin/rclone-custom"
cat > "$HAND_CFG" <<EOF
REMOTE="handfake:"
LOCAL="$HAND_HOME/OneDrive"
UNIT_NAME="zz-hand-probe"
RCLONE="$HAND_HOME/bin/rclone-custom"
MAX_DELETE="42"
BW_LIMIT="1M"
CHECK_ACCESS="1"
MAX_LOG_BYTES="1048576"
SHOW_ICON="0"
NOTIFY_ON_SUCCESS="0"
RETRIES="5"
EOF
# The key is read before the probe, so a machine whose rclone is outside PATH can
# still run the wizard: with a PATH holding no rclone at all, the config's binary is
# the only one that can answer, and the stub records that it did.
rm -f "$HAND_HOME/rclone-calls"
WIZARD_PATH="$WORK/wizard-path"; mkdir -p "$WIZARD_PATH"
run "the wizard runs the binary the config names when PATH has no rclone" 0 "Wrote" \
    env -i PATH="$WIZARD_PATH:/usr/bin:/bin" HOME="$HAND_HOME" \
        XDG_CONFIG_HOME="$HAND_HOME/.config" XDG_CACHE_HOME="$HAND_HOME/.cache" \
    bash "$SRC_DIR/setup.sh" --remote handfake: --local "$HAND_HOME/OneDrive" \
        --filters none --interval 11 --unit-name zz-hand-probe --yes --no-install
check "and the binary it names is the one that was asked for the remotes" \
    grep -qx 'listremotes' "$HAND_HOME/rclone-calls"
run "a re-run of the wizard finishes with the config it was given" 0 "Wrote" \
    env HOME="$HAND_HOME" XDG_CONFIG_HOME="$HAND_HOME/.config" \
        XDG_CACHE_HOME="$HAND_HOME/.cache" \
    bash "$SRC_DIR/setup.sh" --remote handfake: --local "$HAND_HOME/OneDrive" \
        --filters none --interval 11 --unit-name zz-hand-probe --yes --no-install
check "and the bandwidth cap the user set is still there" \
    grep -qxF 'BW_LIMIT="1M"' "$HAND_CFG"
check "and so is the access check" grep -qxF 'CHECK_ACCESS="1"' "$HAND_CFG"
check "and the delete cap the wizard never asks about" \
    grep -qxF 'MAX_DELETE="42"' "$HAND_CFG"
check "and the log size, which its template did not even carry" \
    grep -qxF 'MAX_LOG_BYTES="1048576"' "$HAND_CFG"
check "and the icon setting" grep -qxF 'SHOW_ICON="0"' "$HAND_CFG"
check "and the notification setting" grep -qxF 'NOTIFY_ON_SUCCESS="0"' "$HAND_CFG"
check "and RCLONE, which a re-run used to delete" \
    grep -qxF "RCLONE=\"$HAND_HOME/bin/rclone-custom\"" "$HAND_CFG"
check "and the wrapper's retry count" grep -qxF 'RETRIES="5"' "$HAND_CFG"
check "while the key the flag owns follows the flag" \
    grep -qxF 'INTERVAL_MIN="11"' "$HAND_CFG"

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

# ------------------------------------------------- the settings a re-run keeps
# INTERVAL_MIN and WATCH were written out of the template unconditionally, so the
# documented re-run that passes only --remote/--local/--unit-name reset a changed
# interval to 5 and turned realtime sync back on, while every key beside them went
# through carry(). Measured by a reviewer: INTERVAL_MIN="15" and WATCH="0" became
# "5" and "1". The flags still own both keys when they are given.
title "the interval and realtime settings a re-run is not asked about"
CARRY_HOME="$WORK/carry-home"
CARRY_CFG="$CARRY_HOME/.config/rclone-onedrive-tray/config"
rm -rf "$CARRY_HOME"; mkdir -p "$CARRY_HOME"
wizard_run() {  # wizard_run [extra setup.sh arguments...]
    env HOME="$CARRY_HOME" XDG_CONFIG_HOME="$CARRY_HOME/.config" \
        XDG_CACHE_HOME="$CARRY_HOME/.cache" \
    bash "$SRC_DIR/setup.sh" --remote "$REMOTE" --local "$CARRY_HOME/OneDrive" \
        --filters none --unit-name zz-carry-probe --yes --no-install "$@"
}
run "the first run writes the interval and realtime the flags asked for" 0 "Wrote" \
    wizard_run --interval 9 --watch yes
check "and the interval is the flag's value" grep -qxF 'INTERVAL_MIN="9"' "$CARRY_CFG"
check "and realtime sync is on" grep -qxF 'WATCH="1"' "$CARRY_CFG"
# The settings window, or an editor, changes them between runs.
sed -i 's/^INTERVAL_MIN=.*/INTERVAL_MIN="15"/; s/^WATCH=.*/WATCH="0"/' "$CARRY_CFG"
run "a re-run that passes only remote, local and unit-name finishes" 0 "Wrote" \
    wizard_run
check "and the interval the file had is still there" \
    grep -qxF 'INTERVAL_MIN="15"' "$CARRY_CFG"
check "and realtime sync is still off" grep -qxF 'WATCH="0"' "$CARRY_CFG"
# The other half: the flags still own both keys when they are passed.
run "a re-run that does pass both flags changes them" 0 "Wrote" \
    wizard_run --interval 11 --watch yes
check "and the interval follows the flag again" grep -qxF 'INTERVAL_MIN="11"' "$CARRY_CFG"
check "and so does realtime sync" grep -qxF 'WATCH="1"' "$CARRY_CFG"

# A carried value was read out and written back through config_quote(), which
# escapes the `$` it finds: LOG="${XDG_CACHE_HOME:-$HOME/.cache}/sync.log" came
# back as LOG="\${XDG_CACHE_HOME:-$HOME/.cache}/sync.log". The wrapper does not
# expand a literal like that, so a re-run of the wizard moved the log to a
# directory named "${XDG_CACHE_HOME:-$HOME/.cache}" under the working directory,
# on an install whose log path worked before. A re-run now writes the old file's
# own line for every key it carries, so what the user wrote stays what it says.
title "a re-run writes carried values the way the file had them"
# shellcheck disable=SC2016  # the ${VAR} in both strings is the text under test
sed -i 's|^LOG=.*|LOG="${XDG_CACHE_HOME:-$HOME/.cache}/sync.log"|' "$CARRY_CFG"
run "a re-run over a config whose LOG holds a variable finishes" 0 "Wrote" \
    wizard_run --interval 9
# shellcheck disable=SC2016  # the ${VAR} is what the check looks for in the file
check "and the variable in LOG is still written as a variable" \
    grep -qxF 'LOG="${XDG_CACHE_HOME:-$HOME/.cache}/sync.log"' "$CARRY_CFG"
# Sourcing it is the point: this is what bin/onedrive-sync does with the file, so
# the check is the log path bash resolves rather than the text in the file.
# shellcheck disable=SC2016  # $LOG belongs to the sourcing shell, not this one
check "and sourcing the config expands LOG to the cache directory" \
    grep -qxF "LOG=\"$CARRY_HOME/.cache/sync.log\"" \
    <(env HOME="$CARRY_HOME" XDG_CACHE_HOME="$CARRY_HOME/.cache" bash -c \
        '. "$1"; echo "LOG=\"$LOG\""' _ "$CARRY_CFG")
# A key the file does not set at all still lands from the template. The probe
# config has no BW_LIMIT of its own, so it is the one that proves the default
# path is not affected by carrying lines instead of values.
run "a re-run over a config without a key finishes" 0 "Wrote" \
    wizard_run --interval 9
check "and a key the file never set is written from the template" \
    grep -qxF 'BW_LIMIT=""' "$CARRY_CFG"
check "and a quoted default is still quoted" \
    grep -qxF 'OPEN_APP_NAME="the app"' "$CARRY_CFG"

# A carried line is copied only when it is the whole assignment. A value written
# over two lines is valid shell, and the first version of carry_assign copied its
# first physical line alone: the new config ended at OPEN_APP_CMD="one, bash -n
# refused it, and the wizard printed "Wrote" and exited 0 over a file that no
# longer sourced. The reader can see only the first line either, so the fallback
# is the empty value the writer before it produced.
title "a carried line that is not a whole assignment"
{ grep -v '^OPEN_APP_CMD=' "$CARRY_CFG"; printf 'OPEN_APP_CMD="one\ntwo"\n'; } \
    > "$CARRY_CFG.new" && mv -f "$CARRY_CFG.new" "$CARRY_CFG"
run "a re-run over a config whose value spans two lines finishes" 0 "Wrote" \
    wizard_run --interval 9
check "and the config it wrote is still shell" bash -n "$CARRY_CFG"
check "and the value it could not carry is the empty one the reader sees" \
    grep -qxF 'OPEN_APP_CMD=""' "$CARRY_CFG"
# An unterminated quote in the old file is the same class: the value is not
# something this writer can reproduce, so it falls back rather than copying it.
sed -i 's|^LOG=.*|LOG="/tmp/unterminated|' "$CARRY_CFG"
run "a re-run over a config with an unterminated quote finishes" 0 "Wrote" \
    wizard_run --interval 9
check "and that config is shell too" bash -n "$CARRY_CFG"
check "and the key with the broken quote came back quoted and closed" \
    grep -qxF 'LOG=""' "$CARRY_CFG"
# And the writer refuses rather than replacing a working config when the result is
# not shell: a value whose bare form is not a word this grammar carries goes through
# the quoting path, which closes it.
sed -i 's|^MAX_DELETE=.*|MAX_DELETE=1(x|' "$CARRY_CFG"
run "a re-run over a config with a value no shell word can hold finishes" 0 "Wrote" \
    wizard_run --interval 9
check "and it wrote that value quoted rather than bare" \
    grep -qxF 'MAX_DELETE="1(x"' "$CARRY_CFG"
check "and the file is still shell" bash -n "$CARRY_CFG"

# A carried line that is shell syntax rather than one quoted string is copied as it
# stands. The first version of carry_assign accepted only KEY="one string" and a
# bare word, and sent everything else through the value path, which escapes `$`:
# measured on that version, these three lines came back as a frozen literal, a
# frozen $HOME, and a value truncated at the space.
title "the lines a carried value is allowed to be"
carry_line() {  # carry_line <line> -> the wizard's result for it, on stdout
    { grep -v '^LOG=' "$CARRY_CFG"
      printf '%s\n' "$1"
    } > "$CARRY_CFG.new" && mv -f "$CARRY_CFG.new" "$CARRY_CFG"
    wizard_run --interval 9 >/dev/null 2>&1
    grep -m1 '^LOG=' "$CARRY_CFG"
}
# shellcheck disable=SC2016  # the ${VAR} is the text under test, not this shell's
check "an unquoted \${VAR} path is carried as the file wrote it" \
    grep -qxF 'LOG=${XDG_CACHE_HOME:-$HOME/.cache}/sync.log' \
    <(carry_line 'LOG=${XDG_CACHE_HOME:-$HOME/.cache}/sync.log')
# shellcheck disable=SC2016  # $LOG is the sourcing shell's, not this one's
check "and sourcing that still expands it to the cache directory" \
    grep -qxF "LOG=$CARRY_HOME/.cache/sync.log" \
    <(env HOME="$CARRY_HOME" XDG_CACHE_HOME="$CARRY_HOME/.cache" bash -c \
        '. "$1"; echo "LOG=$LOG"' _ "$CARRY_CFG")
check "and the config is shell" bash -n "$CARRY_CFG"

# An escaped quote and a variable in the same value: both have to survive.
# Written with printf rather than sed: a backslash in a sed replacement is dropped
# before the quote, so the file would have held an unescaped quote and this case
# would have been about a different value.
{ grep -v '^OPEN_APP_CMD=' "$CARRY_CFG"
  # shellcheck disable=SC2016  # $HOME is the text the config holds, not this shell's
  printf '%s\n' 'OPEN_APP_CMD="obsidian \"$HOME/Notes\""'
} > "$CARRY_CFG.new" && mv -f "$CARRY_CFG.new" "$CARRY_CFG"
run "a re-run over a value with an escaped quote and a variable finishes" 0 "Wrote" \
    wizard_run --interval 9
# shellcheck disable=SC2016  # same: the $HOME is inside the value under test
check "and that line is written as the file had it" \
    grep -qxF 'OPEN_APP_CMD="obsidian \"$HOME/Notes\""' "$CARRY_CFG"
# shellcheck disable=SC2016  # $HOME belongs to the sourcing shell
check "and sourcing it expands the variable inside the quoted value" \
    grep -qxF "OPEN_APP_CMD=obsidian \"$CARRY_HOME/Notes\"" \
    <(env HOME="$CARRY_HOME" bash -c '. "$1"; echo "OPEN_APP_CMD=$OPEN_APP_CMD"' _ "$CARRY_CFG")

# A single-quoted value with a space in it. The reader stops an unquoted value at
# the first space, so the fallback used to write "'single" and the value was gone.
sed -i "s|^OPEN_APP_NAME=.*|OPEN_APP_NAME='single quoted'|" "$CARRY_CFG"
run "a re-run over a single-quoted value with a space finishes" 0 "Wrote" \
    wizard_run --interval 9
check "and the whole value is still there, quotes and all" \
    grep -qxF "OPEN_APP_NAME='single quoted'" "$CARRY_CFG"
check "and it still reads as one value" \
    grep -qxF "OPEN_APP_NAME=single quoted" \
    <(bash -c '. "$1"; echo "OPEN_APP_NAME=$OPEN_APP_NAME"' _ "$CARRY_CFG")

# The two scalars the wizard writes unquoted are validated rather than carried
# blind: a hand-written WATCH is not a 0 or a 1, and an INTERVAL_MIN holding shell
# syntax would otherwise be assembled into a file the wrapper sources. The marker
# is the sharp end of it: if the wizard wrote that value through, sourcing the
# config runs the command in it.
title "the values the wizard writes unquoted"
rm -f "$CARRY_CFG.sourced-marker"
sed -i "s|^WATCH=.*|WATCH='a\"b'|" "$CARRY_CFG"
run "a re-run over a WATCH that is not 0 or 1 finishes" 0 "Wrote" \
    wizard_run --interval 9
check "and it says what it did with it" \
    grep -qF 'WATCH=' "$CARRY_CFG"
check "and the file is shell" bash -n "$CARRY_CFG"
check "and WATCH is a switch again" grep -qxF 'WATCH="1"' "$CARRY_CFG"
{ grep -v '^INTERVAL_MIN=' "$CARRY_CFG"
  printf "INTERVAL_MIN='5\"; touch %s; \"'\n" "$CARRY_CFG.sourced-marker"
} > "$CARRY_CFG.new" && mv -f "$CARRY_CFG.new" "$CARRY_CFG"
# No --interval here: the flag owns the value when it is given, and the point of
# this case is the value the file already holds.
run "a re-run over an INTERVAL_MIN holding shell syntax finishes" 0 "Wrote" \
    wizard_run
check "and INTERVAL_MIN is a number again" grep -qxF 'INTERVAL_MIN="5"' "$CARRY_CFG"
check "and the file is shell" bash -n "$CARRY_CFG"
check_absent "and sourcing it runs nothing that was in the old value" \
    "$CARRY_CFG.sourced-marker"

# A line can be valid shell on its own and still change how the rest of the file is
# read, which is the hole `bash -n` alone leaves: OPEN_APP_CMD=<<X is a here-doc
# opener, and the heredoc swallowed every key after it. The sharp assertion is that
# a key written after that line is still set when the config is sourced.
title "a carried line that would change the rest of the file"
{ grep -v '^OPEN_APP_CMD=' "$CARRY_CFG"
  printf '%s\n' 'OPEN_APP_CMD=<<X'
} > "$CARRY_CFG.new" && mv -f "$CARRY_CFG.new" "$CARRY_CFG"
run "a re-run over a here-doc opener finishes" 0 "Wrote" wizard_run
# shellcheck disable=SC2016  # $1 belongs to the inner bash
check "and that line is not what the new config says" \
    bash -c '! grep -qxF "OPEN_APP_CMD=<<X" "$1"' _ "$CARRY_CFG"
check "and the file is still shell" bash -n "$CARRY_CFG"
# Set, not non-empty: RCLONE is empty by default, so `[ -n ... ]` failed for the
# right config for the wrong reason.
# shellcheck disable=SC2016  # the ${...} are the inner bash's own parameters
check "and every key after that line is still set when it is sourced" \
    bash -c '. "$1"; [ "${WATCH+set}" = set ] && [ "${RETRIES+set}" = set ] \
             && [ "${RCLONE+set}" = set ] && [ "${SHOW_ICON+set}" = set ]' _ "$CARRY_CFG"
rm -f "$CARRY_CFG.sourced-marker"

# ------------------------------------------------- every hand-written shape
# The general form of both carry defects the reviews found, rather than one case per
# defect: whatever the old file held, what the wizard writes has to source with every
# key the template writes still set, and where the old file already did that, with the
# values bash read from it. A line that was valid on its own and swallowed the keys
# after it (a here-doc opener) fails the first half; a frozen `$VAR`, a truncated
# single-quoted value and a value a scanner rejected fail the second.
title "a hand-written value, through the wizard and into bash"
# The general form of both carry defects the reviews found, rather than one case per
# defect: whatever the old file held, what the wizard writes has to source with every
# key the template writes still set, and where the old file already did that, with the
# values bash read from it. A line that was valid on its own and swallowed the keys
# after it (a here-doc opener) fails the first half; a frozen `$VAR`, a truncated
# single-quoted value and a value a scanner rejected fail the second.
#
# Each shape starts from the same seed config, so a shape the wizard refuses cannot
# leave a broken file for the next one to be measured against. The dumps say
# `<UNSET>` for a key that is not there: `${!key-}` answers the empty string for an
# unset variable and for an empty one, and the difference is what the first half is
# about.
SHAPE_KEYS="REMOTE LOCAL UNIT_NAME INTERVAL_MIN WATCH MAX_DELETE BW_LIMIT CHECK_ACCESS CHECK_FILENAME BISYNC_ARGS FILTERS_FILE EXCLUDE_FOLDERS_FILE LOG OPEN_APP_CMD OPEN_APP_NAME UI_LANG WATCH_DEBOUNCE WATCH_SETTLE WATCH_EXCLUDE RETRIES RETRY_DELAY MAX_LOG_BYTES SHOW_ICON NOTIFY_ON_SUCCESS RCLONE"
CARRY_KEYS="MAX_DELETE BW_LIMIT CHECK_ACCESS CHECK_FILENAME BISYNC_ARGS LOG OPEN_APP_CMD OPEN_APP_NAME UI_LANG WATCH_DEBOUNCE WATCH_SETTLE WATCH_EXCLUDE RETRIES RETRY_DELAY MAX_LOG_BYTES SHOW_ICON NOTIFY_ON_SUCCESS RCLONE"

bash_dump() {  # bash_dump <config> -> KEY=<value> or KEY=<UNSET>, nothing when it is not shell
    # shellcheck disable=SC2016  # the loop and ${!key+set} belong to the inner bash
    env HOME="$CARRY_HOME" XDG_CACHE_HOME="$CARRY_HOME/.cache" bash -c '
        . "$1" >/dev/null 2>&1 || exit 1
        for key in $2; do
            if [ "${!key+set}" = set ]; then printf "%s=<%s>\n" "$key" "${!key}"
            else printf "%s=<UNSET>\n" "$key"; fi
        done' _ "$1" "$SHAPE_KEYS"
}

shape_ok() {  # shape_ok <line> [preserve] -- the invariant, printing what broke first
    # The shape goes where a person would put it: the first two keys, then the edited
    # line, then the rest of the file. Appending it at the end would hide the defect the
    # invariant exists for - a line that swallows the keys after it - because there
    # would be no keys after it.
    #
    # `preserve` is 0 for the shapes that are not a plain assignment to bash at all: a
    # here-doc opener with no body assigns "" and reads stdin, and a trailing backslash
    # joins the line after it. The wizard refuses both and writes the value its own
    # reader sees, which is a repair rather than a reproduction, so those are held to
    # the weaker half (nothing that was set before may be unset after) rather than to
    # the values.
    local line="$1" preserve="${2:-1}" key before after
    local shape_key="${line%%=*}"
    { head -2 "$SHAPE_SEED"
      printf '%s\n' "$line"
      tail -n +3 "$SHAPE_SEED" | grep -v "^$shape_key="
    } > "$CARRY_CFG"
    before="$(bash_dump "$CARRY_CFG" || true)"
    if ! wizard_run --interval 9 >/dev/null 2>&1; then
        echo "the wizard refused a config holding: $line"
        return 1
    fi
    after="$(bash_dump "$CARRY_CFG" || true)"
    if [ -z "$after" ]; then
        echo "the config it wrote does not source: $line"
        bash -n "$CARRY_CFG" 2>&1 | head -2
        return 1
    fi
    # Nothing the shell could read before may be gone after it: that half holds for
    # every shape, including one whose own line is not a plain assignment.
    if [ -n "$before" ]; then
        for key in $CARRY_KEYS; do
            case "$before" in *"$key=<UNSET>"*) continue ;; esac
            case "$after" in
                *"$key=<UNSET>"*) echo "$key was set before and is unset after: $line"; return 1 ;;
            esac
        done
    fi
    # And for a line bash reads as a plain assignment, every value has to be the one
    # bash read from the old file. The comparison carries the `<UNSET>` markers with
    # it, so a key that stopped being set is a difference here too.
    if [ "$preserve" = 1 ] && [ -n "$before" ]; then
        for key in $CARRY_KEYS; do
            if [ "$(grep "^$key=" <<<"$before")" != "$(grep "^$key=" <<<"$after")" ]; then
                echo "bash read $(grep "^$key=" <<<"$before") from: $line"
                echo "and        $(grep "^$key=" <<<"$after") from the wizard's config"
                return 1
            fi
        done
    fi
}

# The seed: what the wizard writes when there is no config at all. Every shape is
# measured against this rather than against whatever the shape before it left behind.
SHAPE_SEED="$CARRY_HOME/.shape-seed"
rm -f "$SHAPE_SEED"
wizard_run --interval 9 >/dev/null 2>&1
cp -f "$CARRY_CFG" "$SHAPE_SEED"

while IFS= read -r shape; do
    [ -n "$shape" ] || continue
    preserve=1
    case "$shape" in
        # Not a plain assignment to bash: a here-doc opener with no body, a
        # continuation, and a value followed by more words (which the shell runs as
        # commands, leaving the key unset).
        *'<<'*|*\\) preserve=0 ;;
        BISYNC_ARGS=*' '*) preserve=0 ;;
    esac
    check "a config holding $(printf '%s' "$shape" | cut -c1-40) survives a re-run" \
        shape_ok "$shape" "$preserve"
done <<'SHAPES'
LOG=${XDG_CACHE_HOME:-$HOME/.cache}/sync.log
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/sync.log"
LOG=~/sync.log
LOG="~/sync.log"
LOG=/tmp/plain.log
LOG="a b.log"
LOG=/tmp/a\ b.log
LOG=${HOME}/logs/sync.log
OPEN_APP_CMD="obsidian \"$HOME/Notes\""
OPEN_APP_NAME='single quoted'
OPEN_APP_NAME="the app"
OPEN_APP_CMD=$HOME/bin/open.sh
OPEN_APP_CMD=$(command -v rclone)
OPEN_APP_CMD=`echo hi`
LOG=$(id)
MAX_DELETE=$((1+1))
BISYNC_ARGS=--resilient --recover --max-lock 2m
OPEN_APP_CMD=~/bin/open.sh
OPEN_APP_CMD=<<X
OPEN_APP_CMD="one
OPEN_APP_CMD=abc\
LOG="/tmp/unterminated
BW_LIMIT=1M
BW_LIMIT="1M"
BW_LIMIT=
BISYNC_ARGS="--resilient --recover"
BISYNC_ARGS=--resilient
MAX_DELETE=100
MAX_DELETE="1(x"
CHECK_FILENAME='RCLONE_TEST'
SHOW_ICON=1
CHECK_ACCESS=1
WATCH_DEBOUNCE=20
WATCH_SETTLE=30
WATCH_EXCLUDE="node_modules,.venv"
RETRIES=5
RETRY_DELAY=120
MAX_LOG_BYTES=1048576
NOTIFY_ON_SUCCESS=0
UI_LANG=zh
SHAPES

# ------------------------------------------------- the shipped config and XDG
# install.sh copies config/config.example verbatim when no config exists, and the
# example hardcoded $HOME/.config and $HOME/.cache while every script resolves
# those through ${XDG_CONFIG_HOME:-$HOME/.config} and
# ${XDG_CACHE_HOME:-$HOME/.cache}. On a machine with the XDG directories
# redirected (the README's no-account trial sets both) the installed config then
# pointed at paths nothing created: the filters were silently not applied, and the
# doctor failed the paths check on a file that could never appear.
title "the shipped config follows the XDG directories"
XDG5="$WORK/xdg-example"
xdg_example_paths() {  # the three path keys as bash resolves them from the example
    # The single quotes are the point: the variables in there belong to the inner
    # shell, which is the one that sources the example under the redirected XDG
    # directories this case passes in.
    # shellcheck disable=SC2016
    "$@" bash -c 'set -u; . "$1"; printf "%s\n%s\n%s\n" "$FILTERS_FILE" "$EXCLUDE_FOLDERS_FILE" "$LOG"' \
        _ "$SRC_DIR/config/config.example"
}
XDG5_GOT="$(xdg_example_paths env HOME="$XDG5/home" XDG_CONFIG_HOME="$XDG5/config" \
    XDG_CACHE_HOME="$XDG5/cache")"
XDG5_WANT="$XDG5/config/rclone-onedrive-tray/filters.txt
$XDG5/config/rclone-onedrive-tray/exclude-folders.txt
$XDG5/cache/rclone-onedrive-tray/sync.log"
if [ "$XDG5_GOT" = "$XDG5_WANT" ]; then
    ok "the three path keys resolve inside the redirected XDG directories"
else
    bad "the example's paths do not follow the reconfigured XDG directories"
    printf '        want: %s\n        got:  %s\n' "$XDG5_WANT" "$XDG5_GOT"
fi
# And with the XDG variables unset, the usual state of a desktop session, the
# same three lines fall back to the paths the file documents.
XDG5_GOT="$(xdg_example_paths env -u XDG_CONFIG_HOME -u XDG_CACHE_HOME HOME="$XDG5/home")"
XDG5_WANT="$XDG5/home/.config/rclone-onedrive-tray/filters.txt
$XDG5/home/.config/rclone-onedrive-tray/exclude-folders.txt
$XDG5/home/.cache/rclone-onedrive-tray/sync.log"
if [ "$XDG5_GOT" = "$XDG5_WANT" ]; then
    ok "and with XDG unset they fall back to \$HOME/.config and \$HOME/.cache"
else
    bad "the fallback paths are not the documented ones"
    printf '        want: %s\n        got:  %s\n' "$XDG5_WANT" "$XDG5_GOT"
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

# ------------------------------------------------- the access check on a fresh install
# CHECK_ACCESS is the one guard that stops a run treating an unreadable side as a
# mass deletion, and the key ships off because turning it on for an install that
# already exists aborts that install's next run until the marker files are there.
# A config this run creates has no such history, so the offer belongs on a first
# install; a re-run keeps whatever the file already holds, through carry(), like
# every other key the wizard does not ask about. The marker files themselves are
# not built here: the wizard runs the shipped helper, bin/onedrive-check-access.
title "the access check on a first install"
ACC_HOME="$WORK/acc-home"
ACC_CFG="$ACC_HOME/.config/rclone-onedrive-tray/config"
acc_wizard() {  # the wizard, in this case's own HOME
    env HOME="$ACC_HOME" XDG_CONFIG_HOME="$ACC_HOME/.config" \
        XDG_CACHE_HOME="$ACC_HOME/.cache" \
    bash "$SRC_DIR/setup.sh" --remote "$REMOTE" --local "$ACC_HOME/OneDrive" \
        --filters none --unit-name zz-acc-probe --yes --no-install
}
rm -rf "$ACC_HOME"
run "a fresh --yes run decides the access check and says so" 0 \
    "the access check is left to you" acc_wizard
# shellcheck disable=SC2016  # $REMOTE/$LOCAL belong to the sourcing shell
check "and the config it wrote is a working one" \
    bash -c 'set -u; . "$1"; test -n "$REMOTE" && test -n "$LOCAL"' _ "$ACC_CFG"
check "and the access check is off in it" grep -qxF 'CHECK_ACCESS="0"' "$ACC_CFG"
# A first install names a directory that does not exist yet. The wrapper refuses a
# missing LOCAL rather than inventing a sync root, so the wizard is what creates it.
check "and the directory it will sync into exists" test -d "$ACC_HOME/OneDrive"

# The offer is for a config that did not exist. A re-run is the upgrade case the
# off-by-default reason is about, so it must not ask again, and the value the file
# holds has to survive whether it is 0 or 1.
ACC_RERUN="$(acc_wizard 2>&1)"; ACC_RERUN_RC=$?
if [ "$ACC_RERUN_RC" -eq 0 ] && ! grep -qF 'access check' <<<"$ACC_RERUN"; then
    ok "a re-run does not offer the access check again"
else
    bad "a re-run offered the access check (rc=$ACC_RERUN_RC)"
    printf '%s\n' "$ACC_RERUN" | grep -F 'access check' | head -2 | sed 's/^/        /'
fi
sed -i 's/^CHECK_ACCESS=.*/CHECK_ACCESS="0"/' "$ACC_CFG"
acc_wizard >/dev/null 2>&1 || true
check "a re-run leaves a hand-set CHECK_ACCESS=0 alone" \
    grep -qxF 'CHECK_ACCESS="0"' "$ACC_CFG"
sed -i 's/^CHECK_ACCESS=.*/CHECK_ACCESS="1"/' "$ACC_CFG"
acc_wizard >/dev/null 2>&1 || true
check "and a hand-set CHECK_ACCESS=1 is not turned back off" \
    grep -qxF 'CHECK_ACCESS="1"' "$ACC_CFG"

# Taking the offer, driven on a terminal: the marker files are what makes the check
# work at all, so the run has to create them and only then write the key. The rclone
# here answers the helper's copyto/lsf as well as the wizard's probes, which the
# shared stub cannot: it reports one fixed listing.
ACC_STUB="$WORK/acc-stub"
ACC_MARKERS="$WORK/acc-markers"
mkdir -p "$ACC_STUB"
cat > "$ACC_STUB/rclone" <<EOF
#!/bin/bash
case "\$1" in
    listremotes) printf '%s\n' 'accfake:' ;;
    copyto)      cp -- "\$2" "$ACC_MARKERS/\${3##*/}" ;;
    lsf)         ls -1 "$ACC_MARKERS" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$ACC_STUB/rclone"
ACC_PTY_HOME="$WORK/acc-pty-home"
rm -rf "$ACC_PTY_HOME" "$ACC_MARKERS"; mkdir -p "$ACC_MARKERS"
printf 'y\n' | timeout 60 script -qec \
    "env HOME=$ACC_PTY_HOME XDG_CONFIG_HOME=$ACC_PTY_HOME/.config XDG_CACHE_HOME=$ACC_PTY_HOME/.cache PATH=$ACC_STUB:\$PATH bash $SRC_DIR/setup.sh --remote accfake:Vault --local $ACC_PTY_HOME/OneDrive --filters none --unit-name zz-acc-pty --skip-folders x --no-install" \
    /dev/null >"$WORK/acc-pty-out.txt" 2>&1
check "the run that took the offer turned the access check on" \
    grep -qxF 'CHECK_ACCESS="1"' "$ACC_PTY_HOME/.config/rclone-onedrive-tray/config"
check "and the local marker file is there" \
    test -f "$ACC_PTY_HOME/OneDrive/RCLONE_TEST"
check "and the remote marker file is there" \
    test -f "$ACC_MARKERS/RCLONE_TEST"
check "and the run said what it did" \
    grep -qiF 'access check on' "$WORK/acc-pty-out.txt"

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

# The "Installed" summary is the only place a user reads what was put where, and
# the scripts line used to be a second hand-written copy of the list the install
# loop iterates: a script could be installed and then left out of the report. The
# summary now reads that list, and this is the check that it names every entry at
# the path it was really installed to -- an earlier draft of the shared line
# printed $BIN_DIR/bin/<name>, which nothing else noticed.
INSTALL_OUT="$(bash "$SRC_DIR/install.sh" --prefix "$HOME/.local" --no-start 2>&1)"
for s in onedrive-sync onedrive-tray onedrive-watch onedrive-check \
         onedrive-check-access onedrive-doctor; do
    check "the Installed summary names $s at its installed path" \
        grep -qF "$HOME/.local/bin/$s" <<<"$INSTALL_OUT"
done

# systemd-analyze ships with systemd, which a container or a non-systemd
# distribution may not have. The three cases below are what catch a unit file the
# manager would refuse, so they run everywhere: where the real tool is absent a
# stub stands in earlier on PATH, held to the part it can see (the file exists and
# is not empty) and named in the output. The skip this replaces dropped three
# passes on such a machine, which is what pushed the suite under its floor.
if ! command -v systemd-analyze >/dev/null 2>&1; then
    SDA_STUB="$WORK/systemd-analyze-stub"
    mkdir -p "$SDA_STUB"
    cat > "$SDA_STUB/systemd-analyze" <<'STUB'
#!/bin/bash
# Stands in for the real verifier only where systemd is not installed: it refuses
# a unit file that is missing or empty, which is what the cases below need to see.
for a in "$@"; do
    case "$a" in
        *.service|*.timer)
            [ -s "$a" ] || {
                printf 'stub systemd-analyze: %s is missing or empty\n' "$a" >&2
                exit 1
            } ;;
    esac
done
exit 0
STUB
    chmod +x "$SDA_STUB/systemd-analyze"
    PATH="$SDA_STUB:$PATH"
    export PATH
    printf '  \033[33mnote\033[0m  systemd-analyze is absent; a stub checks that each unit file exists\n'
fi
check "systemd accepts $UNIT.service" \
    systemd-analyze --user verify "$UNIT_DIR/$UNIT.service"
check "systemd accepts $UNIT.timer" \
    systemd-analyze --user verify "$UNIT_DIR/$UNIT.timer"
check "systemd accepts $UNIT-watch.service" \
    systemd-analyze --user verify "$UNIT_DIR/$UNIT-watch.service"

# The timer's interval comes from INTERVAL_MIN through a unit template, and
# systemd's answer to a value it cannot parse is a warning in the journal and a
# dropped directive: dropping OnUnitInactiveSec leaves OnActiveSec=2min as the
# timer's only trigger, which fires once and then stays disabled, so a machine with
# INTERVAL_MIN="abc" syncs once per login while the timer still reports active. A
# zero is parsed and means "as soon as the last run finished", which is a loop, and
# zero has more than one spelling: `systemd-analyze timespan` reads 0, 00 and 000
# as the same value, so `00` is in this list and a guard written for the string "0"
# would leave it through.
title "an INTERVAL_MIN systemd cannot use"
BAD_INTERVAL_HOME="$WORK/bad-interval"
for bad in abc 0 00 -5 5.5; do
    rm -rf "$BAD_INTERVAL_HOME"
    mkdir -p "$BAD_INTERVAL_HOME/.config/rclone-onedrive-tray"
    cat > "$BAD_INTERVAL_HOME/.config/rclone-onedrive-tray/config" <<EOF
REMOTE="$REMOTE"
LOCAL="$BAD_INTERVAL_HOME/OneDrive"
UNIT_NAME="zz-interval-probe"
INTERVAL_MIN="$bad"
WATCH="0"
EOF
    BAD_OUT="$(env HOME="$BAD_INTERVAL_HOME" XDG_CONFIG_HOME="$BAD_INTERVAL_HOME/.config" \
        XDG_CACHE_HOME="$BAD_INTERVAL_HOME/.cache" XDG_DATA_HOME="$BAD_INTERVAL_HOME/.data" \
        bash "$SRC_DIR/install.sh" --prefix "$BAD_INTERVAL_HOME/.local" --no-start 2>&1)"
    BAD_UNIT="$BAD_INTERVAL_HOME/.config/systemd/user/zz-interval-probe.timer"
    if grep -qxF 'OnUnitInactiveSec=5min' "$BAD_UNIT" &&
            grep -qE 'is not a whole number of minutes|must be at least 1' <<<"$BAD_OUT"; then
        ok "INTERVAL_MIN=$bad is refused and 5 takes its place"
    else
        bad "INTERVAL_MIN=$bad: unit says '$(grep -m1 OnUnitInactiveSec "$BAD_UNIT" 2>/dev/null)', install said '$(grep -m1 INTERVAL_MIN <<<"$BAD_OUT")'"
    fi
done

# A drop-in is what the tray's settings dialog writes, and the comparison used to
# understand one spelling of the value: `OnUnitInactiveSec=30` is thirty seconds to
# systemd and matched nothing, so it stayed and outranked INTERVAL_MIN in silence.
DROPIN_ALT="$WORK/dropin-alt"
rm -rf "$DROPIN_ALT"
mkdir -p "$DROPIN_ALT/.config/rclone-onedrive-tray" \
         "$DROPIN_ALT/.config/systemd/user/zz-alt-probe.timer.d"
cat > "$DROPIN_ALT/.config/rclone-onedrive-tray/config" <<EOF
REMOTE="$REMOTE"
LOCAL="$DROPIN_ALT/OneDrive"
UNIT_NAME="zz-alt-probe"
INTERVAL_MIN="5"
WATCH="0"
EOF
# A trailing comment and trailing whitespace are not part of the value either: the
# strip is what keeps `45min   # the wizard wrote this` from being compared as
# "45min # the wizard wrote this" and rewritten with the comment still on it.
printf '[Timer]\nOnUnitInactiveSec=45min   # the wizard wrote this\n' \
    > "$DROPIN_ALT/.config/systemd/user/zz-alt-probe.timer.d/interval.conf"
ALT_OUT="$(env HOME="$DROPIN_ALT" XDG_CONFIG_HOME="$DROPIN_ALT/.config" \
    XDG_CACHE_HOME="$DROPIN_ALT/.cache" XDG_DATA_HOME="$DROPIN_ALT/.data" \
    bash "$SRC_DIR/install.sh" --prefix "$DROPIN_ALT/.local" --no-start 2>&1)"
if grep -qxF 'OnUnitInactiveSec=5min' \
        "$DROPIN_ALT/.config/systemd/user/zz-alt-probe.timer.d/interval.conf" &&
        grep -qF 'timer drop-in said "45min"' <<<"$ALT_OUT"; then
    ok "a drop-in with a trailing comment is read without it and brought in line"
else
    bad "commented drop-in: $(tr '\n' ' ' < "$DROPIN_ALT/.config/systemd/user/zz-alt-probe.timer.d/interval.conf" 2>/dev/null)"
fi

printf '[Timer]\nOnUnitInactiveSec=30\n' \
    > "$DROPIN_ALT/.config/systemd/user/zz-alt-probe.timer.d/interval.conf"
ALT_OUT="$(env HOME="$DROPIN_ALT" XDG_CONFIG_HOME="$DROPIN_ALT/.config" \
    XDG_CACHE_HOME="$DROPIN_ALT/.cache" XDG_DATA_HOME="$DROPIN_ALT/.data" \
    bash "$SRC_DIR/install.sh" --prefix "$DROPIN_ALT/.local" --no-start 2>&1)"
if grep -qxF 'OnUnitInactiveSec=5min' \
        "$DROPIN_ALT/.config/systemd/user/zz-alt-probe.timer.d/interval.conf" &&
        grep -qF 'timer drop-in said "30"' <<<"$ALT_OUT"; then
    ok "a drop-in in another spelling is brought back in line and quoted as written"
else
    bad "drop-in: $(tr '\n' ' ' < "$DROPIN_ALT/.config/systemd/user/zz-alt-probe.timer.d/interval.conf" 2>/dev/null)"
fi

# A sync in flight when the manager stops is stopped with SIGTERM and killed when
# the stop times out: the manager's default for a oneshot is 90 seconds, which a
# bisync of a large tree can exceed. The cap is explicit so the number is a
# decision, and the start cap has to stay as well, because it is what the unit adds
# (a oneshot has no start timeout of its own) and a hung bisync would hold the next
# tick off forever.
title "the sync service's own timeouts"
if grep -qxF 'TimeoutStopSec=300' "$UNIT_DIR/$UNIT.service" &&
        grep -qxF 'TimeoutStartSec=1800' "$UNIT_DIR/$UNIT.service"; then
    ok "the sync unit caps both how long it may start and how long it may stop"
else
    bad "the sync unit's timeouts: $(grep -E '^Timeout' "$UNIT_DIR/$UNIT.service" | tr '\n' ' ')"
fi

# The watcher is the project's only Restart=always, and it exits 1 on purpose
# after three permanent inotifywait failures. Without a start limit of its own the
# cycle is the three failures plus RestartSec, about nine seconds, so one
# unparseable exclude pattern meant thousands of restarts and tens of megabytes of
# journal a day. systemd's default limit is five starts in ten seconds, which that
# cycle never trips.
title "the watcher's restart bound"
if grep -qE '^StartLimitIntervalSec=([3-9][0-9]{2,}|[0-9]{4,})$' \
        "$UNIT_DIR/$UNIT-watch.service" &&
        grep -qE '^StartLimitBurst=[0-9]+$' "$UNIT_DIR/$UNIT-watch.service"; then
    ok "the watcher unit bounds its own restarts"
else
    bad "the watcher unit has no start limit, so a permanent failure restarts it forever: $(grep -c '' "$UNIT_DIR/$UNIT-watch.service") lines"
fi
if awk '/^\[Unit\]/{unit=1} /^\[Service\]/{unit=0} unit' \
        "$UNIT_DIR/$UNIT-watch.service" | grep -q '^StartLimit'; then
    ok "and the limit is in [Unit], where systemd reads it"
else
    bad "the start limit is not in the [Unit] section"
fi

# ---------------------------------------------------------------- the autostart entry
# The entry is the tray's "Start tray at login" setting: unticking the box
# removes the file and the tray reads its presence. install.sh rewrote it on
# every run, so `git pull && ./install.sh` turned the setting back on with no
# message. It is written for a first install and refreshed when it is already
# there; on a re-run whose entry was removed, it stays removed.
title "the autostart entry on a re-run"
AUTOSTART_FILE="$XDG_CONFIG_HOME/autostart/rclone-onedrive-tray.desktop"
# The entry install.sh writes is the same file the tray's own "Start tray at
# login" box writes, and a desktop entry is a key file: GLib looks Name up for the
# session's locale. Without a [zh] entry a Chinese desktop lists it in English
# while the box that wrote it reads 开机自动启动托盘 in the same window.
if [ -f "$AUTOSTART_FILE" ] &&
        grep -qxF 'Name[zh]=OneDrive 状态图标' "$AUTOSTART_FILE" &&
        grep -qxF 'Comment[zh]=rclone bisync 托盘图标' "$AUTOSTART_FILE"; then
    ok "the installed autostart entry carries a Chinese name and comment"
else
    bad "the autostart entry has no [zh] name: $( [ -f "$AUTOSTART_FILE" ] && grep -c '' "$AUTOSTART_FILE" || echo absent ) lines"
fi
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
# The two markers are what the "a systemctl that refuses the watcher calls" case
# below sets: a user manager that refuses the disable or the try-restart.
cat > "$WATCH_STUB_DIR/systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WATCH_CALLS"
case "\$*" in
    *"show -p FragmentPath"*) printf '%s\n' "$WATCH_UNIT_DIR/$WATCH_PROBE.timer" ;;
esac
case "\$*" in
    *"disable --now $WATCH_PROBE-watch.service"*)
        [ -f "$WORK/calls/systemctl-disable-fail" ] &&
            { printf '%s\n' 'mock systemctl disable failure' >&2; exit 1; } ;;
    *"try-restart $WATCH_PROBE-watch.service"*)
        [ -f "$WORK/calls/systemctl-restart-fail" ] &&
            { printf '%s\n' 'mock systemctl try-restart failure' >&2; exit 1; } ;;
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

# A systemctl that refuses the watcher calls. Both branches used to be
# `... 2>/dev/null || true`: the WATCH=0 run then printed "watcher disabled" over
# a watcher systemd had just refused to disable, and the WATCH=1 run said nothing
# at all while the running watcher kept the code the update replaced.
title "a systemctl that refuses the watcher calls"
watch_fail_run() {  # watch_fail_run <WATCH value>
    sed -i "s/^WATCH=.*/WATCH=\"$1\"/" "$WATCH_CFG_DIR/config"
    env HOME="$WATCH_HOME" XDG_CONFIG_HOME="$WATCH_HOME/.config" \
        XDG_CACHE_HOME="$WATCH_HOME/.cache" XDG_DATA_HOME="$WATCH_HOME/.data" \
        PATH="$WATCH_STUB_DIR:$PATH" \
        bash "$SRC_DIR/install.sh" --prefix "$WATCH_HOME/.local" --no-start 2>&1
}
: > "$WORK/calls/systemctl-disable-fail"
WATCH_FAIL_OUT="$(watch_fail_run 0)"
rm -f "$WORK/calls/systemctl-disable-fail"
if grep -qF 'mock systemctl disable failure' <<<"$WATCH_FAIL_OUT"; then
    ok "a refused watcher disable is reported in systemctl's own words"
else
    bad "a refused watcher disable was not reported"
    grep -i watch <<<"$WATCH_FAIL_OUT" | head -3 | sed 's/^/        /'
fi
if grep -qF 'watcher disabled' <<<"$WATCH_FAIL_OUT"; then
    bad "a refused disable was still announced as 'watcher disabled'"
else
    ok "and it is not announced as a successful disable"
fi

: > "$WORK/calls/systemctl-restart-fail"
WATCH_FAIL_OUT="$(watch_fail_run 1)"
rm -f "$WORK/calls/systemctl-restart-fail"
if grep -qF 'could not restart' <<<"$WATCH_FAIL_OUT" &&
        grep -qF 'mock systemctl try-restart failure' <<<"$WATCH_FAIL_OUT"; then
    ok "a refused watcher restart is reported, so an old watcher is not left silent"
else
    bad "a refused try-restart went unreported"
    grep -i watch <<<"$WATCH_FAIL_OUT" | head -3 | sed 's/^/        /'
fi

# The on-spellings are written down in four places and three of them agree on
# 1|true|yes|on|enabled; install.sh tested for the literal "1". A config saying
# WATCH="yes" therefore had the installer disable a watcher that onedrive-sync,
# onedrive-doctor and the tray all consider on.
sed -i 's/^WATCH=.*/WATCH="yes"/' "$WATCH_CFG_DIR/config"
: > "$WATCH_CALLS"
env HOME="$WATCH_HOME" XDG_CONFIG_HOME="$WATCH_HOME/.config" \
    XDG_CACHE_HOME="$WATCH_HOME/.cache" XDG_DATA_HOME="$WATCH_HOME/.data" \
    PATH="$WATCH_STUB_DIR:$PATH" \
    bash "$SRC_DIR/install.sh" --prefix "$WATCH_HOME/.local" --no-start \
    >"$WORK/watch-yes-out.txt" 2>&1
if grep -qF -- "enable --now $WATCH_PROBE-watch.service" "$WATCH_CALLS"; then
    ok "WATCH=yes enables the watcher, the spelling the rest of the project takes"
else
    bad "WATCH=yes left the watcher disabled"
    grep -i 'watch' "$WORK/watch-yes-out.txt" | head -3 | sed 's/^/        /'
fi

# A UNIT_NAME changed between installs leaves the old unit pair enabled forever,
# and nothing said so. Naming the timer alone was half the warning: the timer
# starts <name>.service, and <name>-watch.service is a loop that goes on syncing
# by itself, so a user who followed the advice kept a second sync path alive.
title "a unit pair left by an earlier unit name"
# Every file this installer would have written under the old name.
printf '[Unit]\nDescription=old install\n[Service]\nExecStart=%s/onedrive-sync\n' \
    "$WATCH_HOME/.local/bin" > "$WATCH_UNIT_DIR/zz-old-name.service"
printf '[Timer]\nOnUnitInactiveSec=9min\n' > "$WATCH_UNIT_DIR/zz-old-name.timer"
printf '[Unit]\nDescription=old watcher\n[Service]\nExecStart=%s/onedrive-watch\n' \
    "$WATCH_HOME/.local/bin" > "$WATCH_UNIT_DIR/zz-old-name-watch.service"
mkdir -p "$WATCH_UNIT_DIR/zz-old-name.timer.d"
printf '[Timer]\nOnUnitInactiveSec=9min\n' \
    > "$WATCH_UNIT_DIR/zz-old-name.timer.d/interval.conf"
# Another program's timer sits in the same directory. It is not this script's to
# point at, and uninstall.sh applies the same test before it turns a pair off.
printf '[Unit]\nDescription=something else\n[Service]\nExecStart=/usr/bin/true\n' \
    > "$WATCH_UNIT_DIR/zz-not-ours.service"
printf '[Timer]\nOnUnitInactiveSec=9min\n' > "$WATCH_UNIT_DIR/zz-not-ours.timer"
# A pair from an install that used a different --prefix, which is the same
# migration as a renamed unit: the search for the old pair was anchored to the
# prefix this run installs into, so this one was never reported.
printf '[Unit]\nDescription=old install\n[Service]\nExecStart=%s/bin/onedrive-sync\n' \
    "$WATCH_HOME/.local-old" > "$WATCH_UNIT_DIR/zz-old-prefix.service"
printf '[Timer]\nOnUnitInactiveSec=9min\n' > "$WATCH_UNIT_DIR/zz-old-prefix.timer"
SIBLING_OUT="$(env HOME="$WATCH_HOME" XDG_CONFIG_HOME="$WATCH_HOME/.config" \
    XDG_CACHE_HOME="$WATCH_HOME/.cache" XDG_DATA_HOME="$WATCH_HOME/.data" \
    PATH="$WATCH_STUB_DIR:$PATH" \
    bash "$SRC_DIR/install.sh" --prefix "$WATCH_HOME/.local" --no-start 2>&1)"
SIBLING_RC=$?
if [ "$SIBLING_RC" -eq 0 ]; then
    ok "a leftover unit name does not stop the install"
else
    bad "an install beside a leftover unit name exits $SIBLING_RC"
    printf '%s\n' "$SIBLING_OUT" | head -3 | sed 's/^/        /'
fi
if grep -qF -- "disable --now zz-old-name.timer zz-old-name-watch.service" \
    <<<"$SIBLING_OUT"; then
    ok "the warning turns off both halves of the leftover pair"
else
    bad "the warning leaves the leftover watcher enabled"
    printf '%s\n' "$SIBLING_OUT" | grep -F 'old-name' | head -4 | sed 's/^/        /'
fi
if grep -qF "zz-old-name.timer.d" <<<"$SIBLING_OUT"; then
    ok "and names the interval drop-in that goes with the pair"
else
    bad "the warning never mentions the leftover drop-in directory"
fi
if grep -qF "zz-not-ours" <<<"$SIBLING_OUT"; then
    bad "another program's timer was reported as this install's leftover"
    printf '%s\n' "$SIBLING_OUT" | grep -F 'zz-not-ours' | head -2 | sed 's/^/        /'
else
    ok "another program's timer in the same directory is left alone"
fi
if grep -qF -- "disable --now zz-old-prefix.timer" <<<"$SIBLING_OUT"; then
    ok "and a pair installed under an older prefix is named as well"
else
    bad "a pair left by an install under another prefix went unreported"
    printf '%s\n' "$SIBLING_OUT" | grep -i 'prefix' | head -3 | sed 's/^/        /'
fi

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

# systemd documents a dollar in ExecStart as the start of a variable reference,
# with $$ written for a literal one. This case asserts the documented rule rather
# than a measured expansion: proving what systemd would expand means starting a
# unit, and this suite never touches the service manager.
DOL_HOME="$WORK/dollar\$home"
rm -rf "$DOL_HOME"; mkdir -p "$DOL_HOME"
env HOME="$DOL_HOME" XDG_CONFIG_HOME="$DOL_HOME/.config" \
    XDG_CACHE_HOME="$DOL_HOME/.cache" XDG_DATA_HOME="$DOL_HOME/.data" \
    bash "$SRC_DIR/install.sh" --no-start >"$WORK/dollar-out.txt" 2>&1
DOL_UNIT="$DOL_HOME/.config/systemd/user/onedrive-sync.service"
DOL_EXPECT="$(printf '%s' "$DOL_HOME" | sed 's/\$/$$/g')"
check "a dollar in the path is written \$\$ in ExecStart, per systemd's documented rule" \
    grep -qxF "ExecStart=\"$DOL_EXPECT/.local/bin/onedrive-sync\"" "$DOL_UNIT"

# The tray writes the same file through its own copy of the rule, and tests/tray.sh
# pins that copy against GLib. install.sh's copy escaped the same characters in one
# pass and wrapped the result in quotes, which is one pass short: GLib's key-file
# reader refuses `\$` with "Key file contains key Exec which has a value that cannot
# be interpreted", and a file that does not load is a tray that never starts at
# login while the "Start tray at login" checkbox still reports the setting as on.
# The list is the tray suite's, plus a backtick, which that list does not carry.
check "install.sh's Exec line parses with GLib for every path the tray suite uses" \
    python3 - "$SRC_DIR" "$WORK/exec-quoting" <<'PY'
import os
import subprocess
import sys

import gi
gi.require_version("GLib", "2.0")
from gi.repository import GLib

src, work = sys.argv[1], sys.argv[2]
os.makedirs(work, exist_ok=True)
# The same shapes tests/tray.sh hands the tray's writer, plus a backtick.
suffixes = ["my user", "100%", "a\\b", 'o"d', "a$b", "space% and\\slash", "a`b"]
problems = []
for index, suffix in enumerate(suffixes):
    prefix = os.path.join(work, "prefix-%d" % index, suffix)
    home = os.path.join(work, "home-%d" % index)
    cfg = os.path.join(work, "cfg-%d" % index)
    os.makedirs(home, exist_ok=True)
    env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=cfg,
               XDG_CACHE_HOME=cfg + "-cache", XDG_DATA_HOME=cfg + "-data")
    proc = subprocess.run(["bash", os.path.join(src, "install.sh"),
                           "--prefix", prefix, "--no-start"],
                          env=env, capture_output=True, text=True)
    entry = os.path.join(cfg, "autostart", "rclone-onedrive-tray.desktop")
    path = os.path.join(prefix, "bin", "onedrive-tray")
    if not os.path.exists(entry):
        problems.append("%r: no entry was written (rc=%d) %s"
                        % (prefix, proc.returncode, proc.stdout[-300:]))
        continue
    line = [x for x in open(entry, encoding="utf-8").read().splitlines()
            if x.startswith("Exec=")][0]
    value = line[len("Exec="):]
    if not (value.startswith('"') and value.endswith('"')):
        problems.append("%r was written unquoted: %s" % (path, line))
        continue
    key_file = GLib.KeyFile()
    try:
        key_file.load_from_file(entry, GLib.KeyFileFlags.NONE)
        raw = key_file.get_string("Desktop Entry", "Exec")
        _, argv = GLib.shell_parse_argv(raw)
    except Exception as exc:                      # noqa: BLE001
        problems.append("%r does not parse: %s" % (path, exc))
        continue
    argv = [arg.replace("%%", "%") for arg in argv]
    if argv != [path]:
        problems.append("%r reads back as %r" % (path, argv))
if problems:
    print("; ".join(problems))
    raise SystemExit(1)
PY

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

# inotifywait's stderr used to go to /dev/null and every failure meant "sleep 5
# and try the same thing again". A WATCH_EXCLUDE that is not a valid regular
# expression fails on every attempt, so the unit stayed active forever, systemd's
# Restart=always never fired, and the journal held the startup banner alone while
# the watcher did nothing at all. Measured with inotifywait 4.23.9 and
# WATCH_EXCLUDE="[": the tool prints "Error in `exclude' regular expression." on
# stderr and exits 1, and the watcher was still spinning after 12 seconds with
# nothing else ever printed.
title "onedrive-watch when inotifywait fails for good"
WATCH_PERM="$WORK/watch-permanent"
rm -rf "$WATCH_PERM"
mkdir -p "$WATCH_PERM/cfg/rclone-onedrive-tray" "$WATCH_PERM/local" "$WATCH_PERM/cache"
cat > "$WATCH_PERM/cfg/rclone-onedrive-tray/config" <<EOF
LOCAL="$WATCH_PERM/local"
UNIT_NAME="zz-watch-perm"
WATCH_EXCLUDE="["
WATCH_DEBOUNCE="1"
WATCH_SETTLE="1"
EOF
WATCH_PERM_ERR="$WORK/watch-permanent.err"
env PATH="$PATH" HOME="$WATCH_PERM" XDG_CONFIG_HOME="$WATCH_PERM/cfg" \
    XDG_CACHE_HOME="$WATCH_PERM/cache" TMPDIR="$WATCH_PERM" \
    "$HOME/.local/bin/onedrive-watch" >/dev/null 2>"$WATCH_PERM_ERR" &
WATCH_PERM_PID=$!
for _ in $(seq 1 60); do
    kill -0 "$WATCH_PERM_PID" 2>/dev/null || break
    sleep 0.5
done
if kill -0 "$WATCH_PERM_PID" 2>/dev/null; then
    kill "$WATCH_PERM_PID" 2>/dev/null
    wait "$WATCH_PERM_PID" 2>/dev/null
    bad "an invalid WATCH_EXCLUDE left the watcher spinning instead of exiting"
else
    wait "$WATCH_PERM_PID" 2>/dev/null
    WATCH_PERM_RC=$?
    if [ "$WATCH_PERM_RC" -ne 0 ] && grep -qF 'regular expression' "$WATCH_PERM_ERR"; then
        ok "an invalid WATCH_EXCLUDE reports inotifywait's message and exits non-zero"
    else
        bad "invalid WATCH_EXCLUDE: exit $WATCH_PERM_RC, $(head -2 "$WATCH_PERM_ERR" | tr '\n' ' ')"
    fi
fi

# The other half of that decision: a tree that is not there any more is the one
# failure that clears itself. inotifywait exits 1 with nothing on stderr when its
# directory is removed, so a watcher that counted that as permanent would exit on
# a tree somebody moved for a moment. Here the tree goes away, comes back, and an
# edit after it has to reach systemd.
title "onedrive-watch when the tree comes back"
WATCH_TRANS="$WORK/watch-transient"
rm -rf "$WATCH_TRANS"
mkdir -p "$WATCH_TRANS/cfg/rclone-onedrive-tray" "$WATCH_TRANS/local" "$WATCH_TRANS/cache"
cat > "$WATCH_TRANS/cfg/rclone-onedrive-tray/config" <<EOF
LOCAL="$WATCH_TRANS/local"
UNIT_NAME="zz-watch-trans"
WATCH_DEBOUNCE="1"
WATCH_SETTLE="1"
EOF
: > "$SYSTEMCTL_CALLS"
env PATH="$PATH" HOME="$WATCH_TRANS" XDG_CONFIG_HOME="$WATCH_TRANS/cfg" \
    XDG_CACHE_HOME="$WATCH_TRANS/cache" TMPDIR="$WATCH_TRANS" \
    "$HOME/.local/bin/onedrive-watch" >/dev/null 2>"$WORK/watch-transient.err" &
WATCH_TRANS_PID=$!
sleep 2
rmdir "$WATCH_TRANS/local"          # the tree vanishes under the watcher
sleep 3
mkdir -p "$WATCH_TRANS/local"       # and comes back before its next retry
sleep 5
touch "$WATCH_TRANS/local/note.md"
for _ in $(seq 1 40); do
    [ -s "$SYSTEMCTL_CALLS" ] && break
    sleep 0.5
done
if kill -0 "$WATCH_TRANS_PID" 2>/dev/null &&
        grep -q "start .*zz-watch-trans" "$SYSTEMCTL_CALLS" 2>/dev/null; then
    ok "a directory that goes away and comes back leaves the watcher working"
else
    bad "the watcher did not survive a tree that vanished: $(head -2 "$WORK/watch-transient.err" | tr '\n' ' ')"
fi
kill "$WATCH_TRANS_PID" 2>/dev/null
wait "$WATCH_TRANS_PID" 2>/dev/null

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

# onedrive-check documents 1 for findings and 2 for a usage or configuration
# problem -- a LOCAL that does not exist, a config it cannot read. The wrapper
# treated every non-zero as findings, so a broken configuration was announced as
# "names or paths OneDrive will refuse were found", which sends a reader through
# their filenames for a fault that is in their config. The checker's own sentence
# is the one to repeat; the claim about names belongs to exit 1 alone.
title "the wrapper reads onedrive-check's exit status"
CHK="$WORK/check-status"
rm -rf "$CHK"
mkdir -p "$CHK/bin" "$CHK/cfg/rclone-onedrive-tray" "$CHK/cache/rclone/bisync" "$CHK/local"
# A copy of the wrapper beside a stub checker, because the wrapper prefers the
# checker in its own directory: that is how the installed pair is laid out.
cp "$HOME/.local/bin/onedrive-sync" "$CHK/bin/"
cat > "$CHK/bin/onedrive-check" <<'STUB'
#!/bin/bash
printf '%s\n' "${CHECK_MSG:-stub checker output}"
exit "${CHECK_RC:-1}"
STUB
cat > "$CHK/rclone" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$CHK/bin/onedrive-check" "$CHK/rclone"
cat > "$CHK/cfg/rclone-onedrive-tray/config" <<EOF
REMOTE="checkfake:Vault"
LOCAL="$CHK/local"
LOG="$CHK/cache/sync.log"
RCLONE="rclone"
MAX_DELETE="0"
RETRIES="1"
EOF
chk_env() { env PATH="$CHK:$PATH" XDG_CONFIG_HOME="$CHK/cfg" \
    XDG_CACHE_HOME="$CHK/cache" "$@"; }

: > "$CHK/cache/sync.log"
CHECK_OUT="$(chk_env CHECK_RC=1 CHECK_MSG='onedrive-check: reserved name: CON' \
    "$CHK/bin/onedrive-sync" --resync 2>&1)"; CHECK_WRAPPER_RC=$?
if [ "$CHECK_WRAPPER_RC" -eq 0 ] &&
        grep -qF 'names or paths OneDrive will refuse were found' "$CHK/cache/sync.log"; then
    ok "exit 1 from the checker is reported as names OneDrive will refuse"
else
    bad "checker exit 1: wrapper exit $CHECK_WRAPPER_RC, $(grep -m1 WARNING "$CHK/cache/sync.log"); $(tail -1 <<<"$CHECK_OUT")"
fi

: > "$CHK/cache/sync.log"
CHECK_OUT="$(chk_env CHECK_RC=2 \
    CHECK_MSG='onedrive-check: sync directory not found: /nowhere (fix LOCAL and run --resync)' \
    "$CHK/bin/onedrive-sync" --resync 2>&1)"; CHECK_WRAPPER_RC=$?
if [ "$CHECK_WRAPPER_RC" -eq 0 ] &&
        grep -qF 'sync directory not found: /nowhere' "$CHK/cache/sync.log" &&
        ! grep -qF 'names or paths OneDrive will refuse' "$CHK/cache/sync.log"; then
    ok "exit 2 is a configuration fault: the checker's sentence, without the claim about names"
else
    bad "checker exit 2: wrapper exit $CHECK_WRAPPER_RC, $(grep -m1 WARNING "$CHK/cache/sync.log"); $(tail -1 <<<"$CHECK_OUT")"
fi

# The check is documented to run before a resync, and a helper that is missing or
# not executable used to mean it silently did not run: the resync carried on and
# ended with a synced marker, so nothing anywhere said the names had not been
# looked at. PATH is narrowed to the stub directory and the system, so a real
# install of the helper on this machine cannot answer for the one missing here.
rm -f "$CHK/bin/onedrive-check"
: > "$CHK/cache/sync.log"
CHECK_OUT="$(env PATH="$CHK:/usr/bin:/bin" XDG_CONFIG_HOME="$CHK/cfg" \
    XDG_CACHE_HOME="$CHK/cache" "$CHK/bin/onedrive-sync" --resync 2>&1)"
if grep -qF 'onedrive-check was not found' "$CHK/cache/sync.log" &&
        grep -qF 'NOT checked before this resync' "$CHK/cache/sync.log" &&
        grep -qF 'onedrive-check was not found' <<<"$CHECK_OUT"; then
    ok "a missing checker is reported instead of skipping the check in silence"
else
    bad "the resync ran with no checker and said nothing: $(tail -1 "$CHK/cache/sync.log")"
fi


# ------------------------------------------------------------ the pause
# A pause is the tray's stamp and nothing else: the units are never touched, so
# the timer keeps ticking and every run it starts lands here and has to be turned
# away. That is what makes a pause survive a reboot and need no tray to end it,
# and what this checks: a run while the stamp is in the future does not invoke
# rclone, says why in the log, and a stamp that has run out is gone by the time the
# run it allowed has finished.
title "a wrapper run during a pause"
PAUSED="$WORK/paused"
rm -rf "$PAUSED"
mkdir -p "$PAUSED/bin" "$PAUSED/cfg/rclone-onedrive-tray" \
         "$PAUSED/cache/rclone-onedrive-tray" "$PAUSED/local"
cp "$SRC_DIR/bin/onedrive-sync" "$PAUSED/bin/"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/called"\nexit 0\n' "$PAUSED" \
    > "$PAUSED/rclone"
chmod +x "$PAUSED/rclone"
cat > "$PAUSED/cfg/rclone-onedrive-tray/config" <<EOF
REMOTE="pausefake:Vault"
LOCAL="$PAUSED/local"
LOG="$PAUSED/cache/sync.log"
RCLONE="rclone"
MAX_DELETE="0"
RETRIES="1"
EOF
paused_run() {
    env PATH="$PAUSED:/usr/bin:/bin" XDG_CONFIG_HOME="$PAUSED/cfg" \
        XDG_CACHE_HOME="$PAUSED/cache" "$PAUSED/bin/onedrive-sync"
}
# The wrapper's cache directory is $XDG_CACHE_HOME/rclone-onedrive-tray, which is
# the tray's as well: the stamp has to be written where the tray would write it.
STAMP="$PAUSED/cache/rclone-onedrive-tray/paused-until"
printf '%s' "$(( $(date +%s) + 600 ))" > "$STAMP"
: > "$PAUSED/called"
paused_run >"$WORK/paused-out.txt" 2>&1
# The capability probe asks rclone `bisync --help` before anything else, so what a
# pause has to stop is the sync itself, not every call to the binary.
if grep -q 'bisync' "$PAUSED/called"; then
    bad "a paused run invoked rclone: $(head -1 "$PAUSED/called")"
else
    ok "a run while the pause is in force does not sync"
fi
if grep -qF 'automatic sync is paused until' "$PAUSED/cache/sync.log"; then
    ok "and says so in the log, with the time it resumes"
else
    bad "the paused run said nothing: $(tail -1 "$PAUSED/cache/sync.log")"
fi
# A value longer than ten digits is later than any clock this will meet, and the
# wrapper has to read it as a pause rather than let the comparison error out and
# treat it as an expired one (which deletes the stamp and syncs).
printf '%s' "9999999999999999999" > "$STAMP"
: > "$PAUSED/called"
paused_run >/dev/null 2>&1
if grep -q 'bisync pausefake:Vault' "$PAUSED/called"; then
    bad "a long stamp was read as expired and the run synced"
else
    ok "a stamp of more digits than a clock has is a pause, not an expiry"
fi
printf '%s' "$(( $(date +%s) - 60 ))" > "$STAMP"
: > "$PAUSED/called"
paused_run >/dev/null 2>&1
if grep -q 'bisync pausefake:Vault' "$PAUSED/called" && [ ! -e "$STAMP" ]; then
    ok "a pause that has run out is dropped, and the run syncs"
else
    bad "an expired pause: rclone called=$([ -s "$PAUSED/called" ] && echo yes || echo no), stamp left=$([ -e "$STAMP" ] && echo yes || echo no)"
fi

# ------------------------------------------------------------ the log cap
# The cap is only a cap while the rotation happens, and the size used to be read
# with `stat -c%s` and its failure turned into a zero by the `|| echo 0` beside
# it. On a userland without GNU stat the log stopped rotating and nothing said so;
# a size that cannot be read is a warning now, and wc reads it everywhere.
title "the log cap and the rotation"
ROT="$WORK/rotate"
rm -rf "$ROT"
mkdir -p "$ROT/bin" "$ROT/cfg/rclone-onedrive-tray" "$ROT/cache" "$ROT/local"
cp "$SRC_DIR/bin/onedrive-sync" "$ROT/bin/"
printf '#!/bin/bash\nexit 0\n' > "$ROT/rclone"
chmod +x "$ROT/rclone"
rot_config() {  # rot_config <MAX_LOG_BYTES>
    cat > "$ROT/cfg/rclone-onedrive-tray/config" <<EOF
REMOTE="rotfake:Vault"
LOCAL="$ROT/local"
LOG="$ROT/cache/sync.log"
RCLONE="rclone"
MAX_DELETE="0"
RETRIES="1"
MAX_LOG_BYTES="$1"
EOF
}
rot_run() {  # the wrapper against the rotation fixture, no arguments
    env PATH="$ROT:/usr/bin:/bin" XDG_CONFIG_HOME="$ROT/cfg" \
        XDG_CACHE_HOME="$ROT/cache" "$ROT/bin/onedrive-sync"
}
rot_config 100
printf 'x%.0s' $(seq 1 200) > "$ROT/cache/sync.log"
printf '\n' >> "$ROT/cache/sync.log"
rm -f "$ROT/cache/sync.log.1"
rot_run >/dev/null 2>&1
if [ -f "$ROT/cache/sync.log.1" ] &&
        [ "$(wc -c < "$ROT/cache/sync.log.1")" -gt 100 ] &&
        [ ! -e "$ROT/cache/sync.log.2" ]; then
    ok "a log over MAX_LOG_BYTES is rotated to .1 and the run starts a fresh one"
else
    bad "the log was not rotated: $(cd "$ROT/cache" && printf '%s ' *)"
fi

# A directory the wrapper may write to but not read: the append in the log check
# succeeds and the size cannot be taken, which is exactly the case the old line
# read as an empty log.
rot_config 100
printf 'y\n' > "$ROT/cache/sync.log"
rm -f "$ROT/cache/sync.log.1"
chmod 200 "$ROT/cache/sync.log"
rot_run >/dev/null 2>&1
chmod 600 "$ROT/cache/sync.log"
if grep -qF 'cannot read the size of' "$ROT/cache/sync.log" &&
        [ ! -e "$ROT/cache/sync.log.1" ]; then
    ok "a log whose size cannot be read says so instead of passing for empty"
else
    bad "an unreadable log size was silent: rotation $( [ -e "$ROT/cache/sync.log.1" ] && echo happened || echo did not happen )"
fi

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
# The stub is also asked one question that is not a sync: the wrapper runs
# `bisync --help` once per run to learn which of the four newer bisync flags the
# installed rclone actually has. The answer is what an rclone 1.75.1, the version
# this stub reports elsewhere, prints; CAP_BISYNC_HELP replaces it whole, so a
# case can pin an older rclone: nothing printed (the flags are absent), or a list
# holding only some of them. The call is recorded in CAP_ARGS.help rather than in
# the argv file, so every row's recorded command line is exactly what it was.
cat > "$CAP/rclone" <<'STUB'
#!/bin/bash
if [ "$1" = bisync ] && [ "$2" = --help ]; then
    [ -n "${CAP_ARGS:-}" ] && printf 'help %s\n' "$*" >> "$CAP_ARGS.help"
    if [ -n "${CAP_BISYNC_HELP+x}" ]; then
        printf '%s\n' "$CAP_BISYNC_HELP"
    else
        printf '%s\n' '      --recover                          Skip --resync and recover from an interrupted run'
        printf '%s\n' '      --max-lock duration                Consider lock files older than this to be stale (default 2m0s)'
        printf '%s\n' '      --conflict-resolve string          How to resolve conflicting files'
        printf '%s\n' '      --conflict-loser string            What to do with the losing file'
    fi
    exit 0
fi
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
# rclone takes a whole percentage (measured: --max-delete 0.5 is refused with
# "parsing \"0.5\" as int64 failed"), so a count below one percent of the pair has
# no exact translation: MAX_DELETE=1 over 200 files becomes --max-delete 1%, which
# allows two deletions. Measured on rclone 1.75.1 with a 397-file pair,
# --max-delete 1% let three deletions through with rc 0 and the run tripped at
# five ("Safety abort: too many deletes (>1%, 5 of 397)"). The count is therefore
# translated as before and the log says what the percentage really allows.
check "MAX_DELETE=1 over 200 files still passes the smallest percentage" \
    test "$(cap_case 1)" = 1
check "and the log says how many deletions that percentage really allows" \
    grep -qF 'allows about 2 deletion(s), not 1' "$CAP/sync.log"
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
# A 0500 directory is the documented fixture, but root ignores the mode bits, so
# the old case skipped there and gave up four passes. Where 0500 turns out still
# writable, a regular file stands where the log's directory should be: mkdir and
# open both fail on it for every uid, so the same wrapper branch is reached and
# the case runs on every machine instead of skipping.
RO="$WORK/readonly"
mkdir -p "$RO"
chmod 500 "$RO"
RO_LOG="$RO/sync.log"
if [ -w "$RO" ]; then
    RO_BLOCK="$WORK/readonly-block"
    : > "$RO_BLOCK"
    RO_LOG="$RO_BLOCK/sync.log"
fi
RO_LOG_DIR="${RO_LOG%/*}"
cap_config "LOG=\"$RO_LOG\""
: > "$WORK/cap-args"
run "a run whose log cannot be opened fails, naming the path" 1 "$RO_LOG" \
    cap_env "$HOME/.local/bin/onedrive-sync"
check "and it stopped before touching the remote" test ! -s "$WORK/cap-args"

# The same defect one level up: the directory cannot be created at all.
cap_config "LOG=\"$RO_LOG_DIR/nested/sync.log\""
: > "$WORK/cap-args"
out="$(cap_env "$HOME/.local/bin/onedrive-sync" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && grep -qF "$RO_LOG_DIR/nested/sync.log" <<<"$out"; then
    ok "a log directory that cannot be created is reported too"
else
    bad "an uncreatable log directory passed silently (rc=$rc)"
fi
check "and that run stopped before touching the remote too" \
    test ! -s "$WORK/cap-args"
chmod 700 "$RO"

# ---------------------------------------------------------------- a missing LOCAL
# The wrapper used to mkdir -p LOCAL before the run, so a typo in the path or an
# unmounted tree became a fresh, empty directory that bisync then treated as the
# sync root: Path1 empty, and with CHECK_ACCESS off and only the percentage delete
# cap in the way that emptiness can travel up to the cloud. onedrive-check and
# onedrive-watch already refuse the same state ("sync directory not found"),
# onedrive-doctor already tells the user to mkdir it, and setup.sh creates it for a
# config it writes, so refusing here costs one command and closes the trap.
title "a LOCAL that is not there"
MISSING_LOCAL="$WORK/missing-local"
rm -rf "$MISSING_LOCAL"
cap_config "LOCAL=\"$MISSING_LOCAL\""
: > "$WORK/cap-args"
run "a run whose LOCAL is missing stops, naming the path and the mkdir" 1 \
    "mkdir -p \"$MISSING_LOCAL\"" \
    cap_env "$HOME/.local/bin/onedrive-sync"
check_absent "and it did not create the directory it was pointed at" "$MISSING_LOCAL"
check "and it stopped before touching the remote" test ! -s "$WORK/cap-args"

# The log and cache directories are the run's own state rather than the user's
# tree, so they are still created: a refusal has to be readable in the log.
MISSING_LOG="$WORK/missing-local-log/rclone-onedrive-tray/sync.log"
rm -rf "$WORK/missing-local-log"
cap_config "LOCAL=\"$MISSING_LOCAL\"
LOG=\"$MISSING_LOG\""
cap_env "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
check "and the log directory is still created for the refused run" \
    test -d "$(dirname "$MISSING_LOG")"
check "and the log file with it" test -f "$MISSING_LOG"

# ---------------------------------------------------------------- the log's clock
# log_line stamped with an unpinned `date`, so the log carried whatever calendar
# the machine's locale uses. Measured by building the locale into a scratch
# directory (no root) and running the wrapper under it: fa_IR writes 1405/07/12
# where the readers assume 2026, the doctor's `date -d` on such a line reports
# "last write 226900d ago", and the tray's strptime accepts no stats block at
# all. The producer is what has to pin it: the readers are the doctor's `date -d`
# and the tray's strptime, and neither can know which calendar wrote the file.
title "the log's timestamp is written in the Gregorian calendar"
LOG_CLOCK_LOCALE="$WORK/log-clock-locale"
mkdir -p "$LOG_CLOCK_LOCALE"
if localedef -i fa_IR -f UTF-8 "$LOG_CLOCK_LOCALE/fa_IR.UTF-8" 2>/dev/null &&
        [ -n "$(LOCPATH="$LOG_CLOCK_LOCALE" LC_ALL=fa_IR.UTF-8 date '+%Y' 2>/dev/null)" ] &&
        [ "$(LOCPATH="$LOG_CLOCK_LOCALE" LC_ALL=fa_IR.UTF-8 date '+%Y' 2>/dev/null)" != "$(LC_ALL=C date '+%Y')" ]; then
    # The real thing: the machine's own date, under a locale whose %Y is a
    # different calendar. Nothing is stubbed here.
    : > "$CAP/sync.log"
    cap_config
    cap_env LOCPATH="$LOG_CLOCK_LOCALE" LC_ALL=fa_IR.UTF-8 \
        "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
    LOG_CLOCK_HOW="a scratch fa_IR.UTF-8 locale"
else
    # No locale sources on this machine. The claim under test is that log_line
    # pins LC_ALL, so a date that would answer in another calendar unless the
    # caller pins it stands in for one. The real fa_IR measurement is in
    # tests/install-flow.sh's history and docs/CHANGELOG.
    LOG_CLOCK_STUB="$WORK/log-clock-bin"
    mkdir -p "$LOG_CLOCK_STUB"
    cat > "$LOG_CLOCK_STUB/date" <<'STUB'
#!/bin/bash
if [ "${LC_ALL:-}" = "C" ]; then exec /bin/date "$@"; fi
printf '1405/07/12 09:43:49\n'
STUB
    chmod +x "$LOG_CLOCK_STUB/date"
    : > "$CAP/sync.log"
    cap_config
    cap_env PATH="$LOG_CLOCK_STUB:$CAP:$PATH" \
        "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
    LOG_CLOCK_HOW="a date stub that answers in another calendar"
fi
LOG_CLOCK_WANT="$(LC_ALL=C date '+%Y')"
LOG_CLOCK_GOT="$(head -1 "$CAP/sync.log" | cut -d/ -f1)"
if [ "$LOG_CLOCK_GOT" = "$LOG_CLOCK_WANT" ] &&
        grep -qE "^$LOG_CLOCK_WANT/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} " "$CAP/sync.log"; then
    ok "with $LOG_CLOCK_HOW the log's first field is the Gregorian year"
else
    bad "the log was stamped '$(head -1 "$CAP/sync.log" | cut -c1-19)' under a different calendar"
fi

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
# remote would have put it. The capability question the wrapper asks once per
# run is answered and not recorded: the cases here count the syncs, and a help
# call is not one.
case "$1" in
    bisync)
        if [ "$2" = --help ]; then
            printf '%s\n' '      --recover                          Skip --resync and recover from an interrupted run'
            printf '%s\n' '      --max-lock duration                Consider lock files older than this to be stale (default 2m0s)'
            printf '%s\n' '      --conflict-resolve string          How to resolve conflicting files'
            printf '%s\n' '      --conflict-loser string            What to do with the losing file'
            exit 0
        fi
        printf '%s\n' "$*" >> "$ACC_ARGS" ;;
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

# The hint a rejected flag gets. It named --resilient and --recover whether or
# not either was the flag rclone refused, and told the reader to get "rclone >=
# 1.65" -- so a 1.65 install, where --recover is exactly what died, was sent to
# the version it already had. Reproduced end to end with the release binary:
# "Fatal error: unknown flag: --recover" then "[oldrclone] this rclone does not
# know the flags in BISYNC_ARGS; --resilient/--recover need rclone >= 1.65".
cap_config
: > "$WORK/cap-args"; : > "$CAP/sync.log"
OLD_OUT="$(cap_env CAP_STDERR='Error: unknown flag: --recover' CAP_RC=1 \
    "$HOME/.local/bin/onedrive-sync" 2>&1)"
if grep -qF '[oldrclone]' <<<"$OLD_OUT" && grep -qF -- '--recover' <<<"$OLD_OUT" &&
        grep -qF 'rclone 1.66' <<<"$OLD_OUT"; then
    ok "a rejected flag is named with the rclone version that has it"
else
    bad "the oldrclone hint: $(grep -m1 oldrclone <<<"$OLD_OUT")"
fi
if grep -qF '1.65' <<<"$OLD_OUT"; then
    bad "the hint still tells a 1.65 user to get 1.65"
else
    ok "and it no longer sends a 1.65 user to the version that failed"
fi

cap_config

# --------------------------------------------- the wrapper's result marker
# The tray and the doctor used to decide what a run did by matching English
# fragments in a log the wrapper shares with rclone. The wrapper now ends every
# run with one machine-readable line so a reader can take the outcome from it:
#
#   ONEDRIVE_RESULT v=1 state=<synced|error|stopped> tag=<a-z|none> when=HH:MM msg=<text>
#
# It is written through the script's own log_line, it is the last thing a run
# writes, and there is exactly one per run. Every prose line around it is
# unchanged, because that is what an older reader still matches.
title "the wrapper's result marker"

# result_field <log> <key> -- one field of the newest marker line, or nothing
# when the log carries none. msg runs to the end of the line, so it is returned
# whole; the other three are single words.
result_field() {
    local line
    line="$(grep 'ONEDRIVE_RESULT v=1 ' "$1" 2>/dev/null | tail -1 || true)"
    [ -n "$line" ] || return 0
    case "$2" in
        msg) printf '%s' "${line#* msg=}" ;;
        *)   printf '%s' "$(printf '%s' "${line#* "$2"=}" | cut -d' ' -f1)" ;;
    esac
}
result_count() { grep -c 'ONEDRIVE_RESULT v=1 ' "$1" 2>/dev/null || true; }

# A successful run: one marker, state=synced tag=none, carrying the same minute
# the timestamp on its own line does, and nothing written after it.
cap_config
: > "$CAP/sync.log"; : > "$WORK/cap-args"
cap_env CAP_STDERR= CAP_RC=0 "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
if [ "$(result_count "$CAP/sync.log")" = 1 ] &&
        grep -qE '^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ONEDRIVE_RESULT v=1 state=synced tag=none when=[0-9]{2}:[0-9]{2} msg=.+' "$CAP/sync.log"; then
    ok "a successful run writes exactly one marker, state=synced tag=none"
else
    bad "a successful run: $(result_count "$CAP/sync.log") marker(s), last '$(grep 'ONEDRIVE_RESULT' "$CAP/sync.log" | tail -1)'"
fi
if [ "$(tail -1 "$CAP/sync.log")" = "$(grep 'ONEDRIVE_RESULT' "$CAP/sync.log" | tail -1)" ]; then
    ok "and it is the last thing the run writes"
else
    bad "the marker is not the last log line: '$(tail -1 "$CAP/sync.log")'"
fi
MARKER_WHEN="$(result_field "$CAP/sync.log" when)"
MARKER_PREFIX_WHEN="$(grep -oE '^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}' "$CAP/sync.log" |
    tail -1 | cut -d' ' -f2)"
if [ -n "$MARKER_WHEN" ] && [ "$MARKER_WHEN" = "$MARKER_PREFIX_WHEN" ]; then
    ok "and when= is the local HH:MM the tray shows, the line's own minute"
else
    bad "when='$MARKER_WHEN' is not the timestamp minute '$MARKER_PREFIX_WHEN'"
fi

# A failure whose class a rerun can clear: the attempts run out, so the marker
# says error and names the class, and msg is the hint sentence with the tag
# taken off. [auth] is in PERMANENT_TAGS, so it stops the loop instead; that is
# the case below.
cap_config
: > "$CAP/sync.log"; : > "$WORK/cap-args"
NET_OUT="$(cap_env CAP_STDERR="$CAP_EOF" CAP_RC=1 "$HOME/.local/bin/onedrive-sync" 2>&1)" || true
NET_HINT="$(grep -oE '\[network\] .*' <<<"$NET_OUT" | head -1)"; NET_HINT="${NET_HINT#\[network\] }"
if [ "$(result_count "$CAP/sync.log")" = 1 ] &&
        [ "$(result_field "$CAP/sync.log" state)" = error ] &&
        [ "$(result_field "$CAP/sync.log" tag)" = network ]; then
    ok "a run that used its attempts up writes state=error and the classified tag"
else
    bad "a network failure: $(grep 'ONEDRIVE_RESULT' "$CAP/sync.log" | tail -1)"
fi
if [ -n "$NET_HINT" ] && [ "$(result_field "$CAP/sync.log" msg)" = "$NET_HINT" ]; then
    ok "and msg is the sentence the hint printed, without the tag"
else
    bad "marker msg '$(result_field "$CAP/sync.log" msg)' is not the hint sentence '$(grep -m1 -oE '\[network\] .*' "$CAP/sync.log")'"
fi
check "and the prose line the older readers match is still there" \
    grep -qF 'ERROR: attempt 1/1 failed (rc=1) [network]' "$CAP/sync.log"

# A permanent class stops the run at the first attempt. The marker has to say
# stopped rather than error: "error" is what a run that spent every attempt
# says, and the two sentences for a user are not the same.
cap_config 'RETRIES="3"
RETRY_DELAY="1"'
: > "$CAP/sync.log"; : > "$WORK/cap-args"
ACCESS_OUT="$(cap_env CAP_STDERR="$RETRY_ACCESS" CAP_RC=1 "$HOME/.local/bin/onedrive-sync" 2>&1)" || true
ACCESS_HINT="$(grep -oE '\[access\] .*' <<<"$ACCESS_OUT" | head -1)"; ACCESS_HINT="${ACCESS_HINT#\[access\] }"
if [ "$(result_count "$CAP/sync.log")" = 1 ] &&
        [ "$(result_field "$CAP/sync.log" state)" = stopped ] &&
        [ "$(result_field "$CAP/sync.log" tag)" = access ]; then
    ok "a permanent class stops the run with state=stopped and its tag"
else
    bad "a stopped run: $(grep 'ONEDRIVE_RESULT' "$CAP/sync.log" | tail -1)"
fi
if grep -q 'state=error' "$CAP/sync.log"; then
    bad "the stopped run also wrote an error marker"
else
    ok "and it is not written as an error, which would claim the attempts ran out"
fi
if [ -n "$ACCESS_HINT" ] && [ "$(result_field "$CAP/sync.log" msg)" = "$ACCESS_HINT" ]; then
    ok "and its msg is the hint sentence for the stop"
else
    bad "stopped msg '$(result_field "$CAP/sync.log" msg)' is not the hint '$(grep -m1 -oE '\[access\] .*' "$CAP/sync.log")'"
fi
check "and only the one attempt was made" test "$(wc -l < "$WORK/cap-args")" -eq 1

# A dry run changes nothing, so its marker is the only record of the run and it
# has to describe what really happened: a clean dry run is a clean run, and one
# whose rclone failed is a failure.
cap_config
: > "$CAP/sync.log"; : > "$WORK/cap-args"
cap_env CAP_STDERR= CAP_RC=0 "$HOME/.local/bin/onedrive-sync" --dry-run >/dev/null 2>&1 || true
check "a dry run passes --dry-run through to rclone" \
    grep -q -- '--dry-run' "$WORK/cap-args"
if [ "$(result_count "$CAP/sync.log")" = 1 ] &&
        grep -q 'state=synced tag=none' "$CAP/sync.log"; then
    ok "and a dry run nothing failed in writes one synced marker"
else
    bad "a clean dry run: $(grep 'ONEDRIVE_RESULT' "$CAP/sync.log" | tail -1)"
fi
: > "$CAP/sync.log"; : > "$WORK/cap-args"
cap_env CAP_STDERR="$CAP_EOF" CAP_RC=1 "$HOME/.local/bin/onedrive-sync" --dry-run >/dev/null 2>&1 || true
if [ "$(result_count "$CAP/sync.log")" = 1 ] &&
        [ "$(result_field "$CAP/sync.log" state)" = error ] &&
        [ "$(result_field "$CAP/sync.log" tag)" = network ]; then
    ok "and a dry run whose rclone failed says error, not synced"
else
    bad "a failed dry run: $(grep 'ONEDRIVE_RESULT' "$CAP/sync.log" | tail -1)"
fi

# A refusal ends the run before rclone is invoked, and it used to leave no trace
# beyond a line on stderr, which systemd puts in the journal. The log stayed
# empty, so onedrive-doctor reported that nothing had ever run through the
# wrapper, the tray showed an unknown state, and the sentence explaining it was
# nowhere either of them reads. Every refusal now writes the ERROR line the log is
# there for and one marker of its own.
cap_config "LOCAL=\"$CAP/missing-local\""
: > "$CAP/sync.log"; : > "$WORK/cap-args"
REFUSED_OUT="$(cap_env CAP_STDERR= CAP_RC=0 "$HOME/.local/bin/onedrive-sync" 2>&1)"
REFUSED_RC=$?
if [ "$REFUSED_RC" -eq 1 ] && grep -qF "does not exist" <<<"$REFUSED_OUT"; then
    ok "a run whose LOCAL is not there still refuses"
else
    bad "a missing LOCAL exited $REFUSED_RC: $(head -1 <<<"$REFUSED_OUT")"
fi
if [ "$(result_count "$CAP/sync.log")" = 1 ] &&
        [ "$(result_field "$CAP/sync.log" state)" = stopped ] &&
        [ "$(result_field "$CAP/sync.log" tag)" = other ]; then
    ok "and leaves one marker, state=stopped tag=other"
else
    bad "a refused run: $(result_count "$CAP/sync.log") marker(s), last '$(grep ONEDRIVE_RESULT "$CAP/sync.log" | tail -1)'"
fi
check "and an ERROR line, which is what the doctor reads" \
    grep -qF "ERROR: $CAP/missing-local does not exist" "$CAP/sync.log"
if grep -qF "$CAP/missing-local" <<<"$(result_field "$CAP/sync.log" msg)"; then
    ok "and the marker's msg names the directory that is missing"
else
    bad "marker msg does not name the missing LOCAL: '$(result_field "$CAP/sync.log" msg)'"
fi
check "and rclone was never invoked" test ! -s "$WORK/cap-args"
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

# ------------------------------------------------- --resync: which copy wins
# rclone documents --resync as "equivalent to --resync-mode path1", and the
# wrapper passes the remote first, so Path1 is the cloud: where a file differs on
# both sides the cloud copy replaces the local one. Measured on rclone 1.75.1, a
# local file edited hours after the cloud copy was replaced by the cloud copy,
# rc 0, no *.conflict* file, and the local revision gone. There is no conflict
# copy and the delete cap does not apply, because a replacement is not a delete.
# rclone 1.75.1 has --resync-mode newer, which keeps the copy that changed last;
# the project's floor is 1.65, where the flag may be absent, so the wrapper asks
# rclone itself instead of comparing version strings, once per run.
title "--resync: which copy wins when both sides changed"
# The four lines before the --resync-mode one are the flags the wrapper's default
# set needs; a stub that listed only --resync-mode would be an rclone that knows
# that flag and not the older ones, which no release ever was. Without them the
# capability probe below would drop them and the "command line is the one it
# always was" check after (c) would be comparing two different lines.
CAP_RESYNC_HELP='      --recover                          Skip --resync and recover from an interrupted run
      --max-lock duration                Consider lock files older than this to be stale (default 2m0s)
      --conflict-resolve string          How to resolve conflicting files
      --conflict-loser string            What to do with the losing file
      --resync-mode string   During resync, prefer the version that is: path1, path2, newer, older, larger, smaller (default "none")'

# (a) the rclone that knows the flag: the newer copy is asked for.
cap_config
: > "$WORK/cap-args"; : > "$WORK/cap-args.help"; : > "$CAP/sync.log"
cap_env CAP_BISYNC_HELP="$CAP_RESYNC_HELP" \
    "$HOME/.local/bin/onedrive-sync" --resync >/dev/null 2>&1 || true
check "an rclone that knows --resync-mode is asked for the newer copy" \
    grep -qF -- '--resync-mode newer' "$WORK/cap-args"
check "and the run says which copy wins on this rclone" \
    grep -qF 'the newer copy wins' "$CAP/sync.log"

# (b) the rclone that does not: path1 keeps winning, and the run has to say so
# before it starts rather than silently replacing local edits.
cap_config
: > "$WORK/cap-args"; : > "$WORK/cap-args.help"; : > "$CAP/sync.log"
cap_env "$HOME/.local/bin/onedrive-sync" --resync >/dev/null 2>&1 || true
if grep -qF -- '--resync-mode' "$WORK/cap-args"; then
    bad "an rclone without --resync-mode was handed the flag anyway"
else
    ok "an rclone without --resync-mode is not handed the flag"
fi
check "and the run warns that the cloud copy replaces the local one" \
    grep -qF 'the cloud copy replaces the local one' "$CAP/sync.log"
check "and says what to do about it" \
    grep -qF 'copy the local files aside' "$CAP/sync.log"

# (c) a plain run is untouched: no --resync-mode flag, and the one capability
# question the default flag set needs is asked once rather than once per flag.
# The question is no longer only about --resync: the four flags the default set
# passes arrived in rclone 1.66, so the wrapper has to ask what this rclone has
# before it builds the line, on every run. What a scheduled run must not pay is
# one question per flag.
cap_config
: > "$WORK/cap-args"; : > "$WORK/cap-args.help"; : > "$CAP/sync.log"
cap_env CAP_BISYNC_HELP="$CAP_RESYNC_HELP" \
    "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
if grep -qF -- '--resync-mode' "$WORK/cap-args"; then
    bad "a plain run was handed --resync-mode"
else
    ok "a plain run passes no --resync-mode"
fi
help_calls="$(grep -c 'help ' "$WORK/cap-args.help" 2>/dev/null || true)"
if [ "${help_calls:-0}" -le 1 ]; then
    ok "and it asks the capability question once, not once per flag"
else
    bad "a plain run asked rclone's help $help_calls times"
fi
check "and the plain run's command line is the one it always was" \
    test "$(cat "$WORK/cap-args")" = "$(argv_line "$CAP/local" '--max-delete 50')"
# The other side of that: a run whose flags need no capability answer at all --
# an explicit BISYNC_ARGS holding none of the four -- still asks rclone nothing.
cap_config 'BISYNC_ARGS=""'
: > "$WORK/cap-args"; : > "$WORK/cap-args.help"; : > "$CAP/sync.log"
cap_env "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
if [ -s "$WORK/cap-args.help" ]; then
    bad "a run with no extra flags asked rclone the question"
else
    ok "and it does not even ask rclone the question"
fi
cap_config

# ---------------------------------------- the flags this rclone does not have
# The default set passes four flags that arrived in rclone 1.66, while the
# project documents a lower floor and install.sh only warns below 1.65. On a 1.65
# rclone every run died on rclone's own "unknown flag: --recover", and the hint
# answered a 1.65 user with "get rclone >= 1.65". The wrapper now asks rclone
# which of the four it has -- one `bisync --help` call per run -- and adds only
# those, so the same config syncs on a 1.65 install and says what it left out.
title "the flags this rclone does not have"
CAP_HELP_ALL='      --recover                          Skip --resync and recover from an interrupted run
      --max-lock duration                Consider lock files older than this to be stale (default 2m0s)
      --conflict-resolve string          How to resolve conflicting files
      --conflict-loser string            What to do with the losing file'
CAP_HELP_SOME='      --recover                          Skip --resync and recover from an interrupted run
      --max-lock duration                Consider lock files older than this to be stale (default 2m0s)
      --resilient                        Retry on less serious errors'
CAP_HELP_NONE='      --resilient                        Retry on less serious errors
      --stats duration                   Interval between printing stats (default 1m0s)'

# (i) an rclone that lists all four: the whole default set, and no NOTICE.
cap_config
: > "$WORK/cap-args"; : > "$WORK/cap-args.help"; : > "$CAP/sync.log"
cap_env CAP_BISYNC_HELP="$CAP_HELP_ALL" "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
if [ "$(cat "$WORK/cap-args")" = "$(argv_line "$CAP/local" '--max-delete 50')" ]; then
    ok "an rclone that lists all four flags gets the whole default set"
else
    bad "all four listed: $(cat "$WORK/cap-args")"
fi
if grep -qF 'does not list' "$CAP/sync.log"; then
    bad "an rclone with every flag was told it was missing one"
else
    ok "and the run reports nothing as dropped"
fi

# (ii) an rclone that lists some of them: those two are not passed.
cap_config
: > "$WORK/cap-args"; : > "$WORK/cap-args.help"; : > "$CAP/sync.log"
cap_env CAP_BISYNC_HELP="$CAP_HELP_SOME" "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
want="bisync $CAP_REMOTE $CAP/local --resilient --recover --max-lock 2m --stats 2s --log-level INFO --log-file $CAP/sync.log --max-delete 50"
if [ "$(cat "$WORK/cap-args")" = "$want" ]; then
    ok "the two flags this rclone lacks are left off the command line"
else
    bad "some listed"
    printf '        want: %s\n        got:  %s\n' "$want" "$(cat "$WORK/cap-args")"
fi
check "and the NOTICE names exactly the flags it dropped" \
    grep -qF 'does not list --conflict-resolve, --conflict-loser' "$CAP/sync.log"
check "and names the rclone version that has them" \
    grep -qF 'rclone 1.66' "$CAP/sync.log"

# (iii) an rclone that lists none of them: all four are dropped, named, and the
# capability question was asked once.
cap_config
: > "$WORK/cap-args"; : > "$WORK/cap-args.help"; : > "$CAP/sync.log"
cap_env CAP_BISYNC_HELP="$CAP_HELP_NONE" "$HOME/.local/bin/onedrive-sync" >/dev/null 2>&1 || true
want="bisync $CAP_REMOTE $CAP/local --resilient --stats 2s --log-level INFO --log-file $CAP/sync.log --max-delete 50"
if [ "$(cat "$WORK/cap-args")" = "$want" ]; then
    ok "an rclone with none of the four gets a command line without them"
else
    bad "none listed"
    printf '        want: %s\n        got:  %s\n' "$want" "$(cat "$WORK/cap-args")"
fi
check "and the NOTICE names all four, in the order they are passed" \
    grep -qF 'does not list --recover, --max-lock, --conflict-resolve, --conflict-loser' "$CAP/sync.log"
check "and the capability question was asked once, not once per flag" \
    test "$(grep -c 'help ' "$WORK/cap-args.help")" -eq 1
cap_config

# ---------------------------------------- the stale lock the retry loop hid
# rclone's bisync lock records the owner's PID. When rclone dies mid-run (the OOM
# killer, a kill, a crash) the lock survives with a dead PID, and the sweep that
# drops such a lock ran once, before the retry loop: every remaining attempt
# failed on a lock the sweep's own test (kill -0) would have removed. Measured
# with rclone 1.75.1: attempt 1 SIGKILLed four seconds in, then "attempt 2/3
# failed (rc=1) [lock] a sync lock is still held" and the same for attempt 3,
# wrapper exit 1. The lock tag is not in PERMANENT_TAGS, so the doomed attempts
# also spent their RETRY_DELAY.
title "a lock left by a killed run is swept before the next attempt"
STALE_FX="$WORK/stale-lock"
rm -rf "$STALE_FX"
mkdir -p "$STALE_FX/cfg/rclone-onedrive-tray" "$STALE_FX/cache/rclone/bisync" \
         "$STALE_FX/local" "$STALE_FX/tmp"
cat > "$STALE_FX/cfg/rclone-onedrive-tray/config" <<EOF
REMOTE="lockfake:Vault"
LOCAL="$STALE_FX/local"
LOG="$STALE_FX/sync.log"
RCLONE="rclone"
MAX_DELETE="0"
RETRIES="3"
RETRY_DELAY="1"
EOF
# The PID the dead run's lock names. It is manufactured rather than guessed: the
# fixed number this used to hold was live on some machines and the case skipped
# there, which is one of the ways the suite fell under its floor. A short-lived
# child is started and reaped, so the pid is gone on every machine.
sh -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
# The stub stands in for an rclone that is killed by its first attempt: it leaves
# a lock naming a dead PID and fails, and every later call fails for as long as
# that lock is there, which is what real rclone does with a lock it cannot use.
# The capability question is answered before the attempt counter, so it is not
# one of the attempts this case counts.
cat > "$STALE_FX/rclone" <<EOF
#!/bin/bash
if [ "\$1" = bisync ] && [ "\$2" = --help ]; then
    printf '%s\n' '      --recover                          Skip --resync and recover from an interrupted run'
    printf '%s\n' '      --max-lock duration                Consider lock files older than this to be stale (default 2m0s)'
    printf '%s\n' '      --conflict-resolve string          How to resolve conflicting files'
    printf '%s\n' '      --conflict-loser string            What to do with the losing file'
    exit 0
fi
n="\$(cat "$STALE_FX/calls" 2>/dev/null || echo 0)"
n=\$((n + 1))
printf '%s\n' "\$n" > "$STALE_FX/calls"
printf '%s\n' "\$*" >> "$STALE_FX/argv"
if [ "\$n" -eq 1 ]; then
    printf '{"PID": "$DEAD_PID"}\n' > "$STALE_FX/cache/rclone/bisync/killed-run.lck"
    printf 'prior lock file found: the run that wrote it is gone\n' >&2
    exit 1
fi
if [ -e "$STALE_FX/cache/rclone/bisync/killed-run.lck" ]; then
    printf 'prior lock file found\n' >&2
    exit 1
fi
exit 0
EOF
chmod +x "$STALE_FX/rclone"

stale_env() {
    env PATH="$STALE_FX:$PATH" XDG_CONFIG_HOME="$STALE_FX/cfg" \
        XDG_CACHE_HOME="$STALE_FX/cache" TMPDIR="$STALE_FX/tmp" "$@"
}

: > "$STALE_FX/calls"; : > "$STALE_FX/argv"; rm -f "$STALE_FX/sync.log"
STALE_OUT="$(stale_env "$HOME/.local/bin/onedrive-sync" 2>&1)"; STALE_RC=$?
# rc 0 is what tells "the sweep before attempt 2 cleared it" apart from
# "attempt 2 failed for some other reason": any other failure is still a
# non-zero run, and the two checks below then say which attempt failed.
if [ "$STALE_RC" -eq 0 ] && [ "$(cat "$STALE_FX/calls")" -eq 2 ]; then
    ok "the run succeeds once the lock its first attempt left behind is swept"
else
    bad "the run ended rc=$STALE_RC after $(cat "$STALE_FX/calls" 2>/dev/null || echo 0) attempt(s)"
    printf '%s\n' "$STALE_OUT" | head -3 | sed 's/^/        /'
fi
check "and the sweep before attempt 2 is what removed it" \
    grep -qF "removed stale lock (owner pid $DEAD_PID is gone)" "$STALE_FX/sync.log"
check "and the first attempt's failure really was the lock" \
    grep -qF "[lock]" "$STALE_FX/sync.log"
if grep -qF "ERROR: attempt 2" "$STALE_FX/sync.log"; then
    bad "attempt 2 failed as well, so the lock was still there"
else
    ok "and attempt 2 was not a failure at all"
fi

# ------------------------------------------------------- an empty remote side
# Measured on rclone 1.75.1 against an empty remote, an incremental run ends:
#   ERROR : Empty prior Path1 listing. Cannot sync to an empty directory: <lst>
#   ERROR : Bisync critical error: empty prior Path1 listing: <lst>
# and the second line matches the generic "critical error" class, so the wrapper
# answered "sync baseline is invalid; run: onedrive-sync --resync". A resync
# rebuilds an equally empty baseline, so the next run fails identically and the
# user is in a loop being told to repeat the thing that does not fix it. The
# README's no-account trial creates exactly this pair.
title "an empty remote side is its own failure"
EMPTY_SIDE_ERR='2026/10/04 08:05:45 ERROR : Empty prior Path1 listing. Cannot sync to an empty directory: /home/u/.cache/rclone/bisync/probefake_Vault..home_u_OneDrive.path1.lst
2026/10/04 08:05:45 ERROR : Bisync critical error: empty prior Path1 listing: /home/u/.cache/rclone/bisync/probefake_Vault..home_u_OneDrive.path1.lst'
run "the empty side is named as its own class" 1 "[emptyremote]" \
    cap_env CAP_STDERR="$EMPTY_SIDE_ERR" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"
run "and the message says the remote side is the empty one" 1 \
    "the remote side is empty" \
    cap_env CAP_STDERR="$EMPTY_SIDE_ERR" CAP_RC=1 "$HOME/.local/bin/onedrive-sync"
EMPTY_SIDE_OUT="$(cap_env CAP_STDERR="$EMPTY_SIDE_ERR" CAP_RC=1 \
    "$HOME/.local/bin/onedrive-sync" 2>&1)"
if grep -qF 'sync baseline is invalid' <<<"$EMPTY_SIDE_OUT"; then
    bad "an empty remote side still sends the user to a plain --resync"
else
    ok "and it does not send the user to a plain --resync"
fi
cap_config

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
# bash is in the list because the shebang looks it up through this PATH. pgrep is
# deliberately absent: the tray is found by its own lock, not by scanning the
# machine's process list, and a doctor that reached for pgrep again would fail
# these cases on a PATH that cannot answer it.
for tool in bash sed grep head cut tail date stat mktemp tr timeout flock \
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
             "$d/local" "$d/bin" "$d/tmp" "$d/run"
    printf '*.tmp\n' > "$d/cfg/rclone-onedrive-tray/filters.txt"
    # A running tray has written its status icons, and the tray row of the report
    # tells a directory holding them from one holding none.
    : > "$d/data/rclone-onedrive-tray/icons/synced.png"
    cp "$DOC_STUBS/rclone" "$DOC_STUBS/systemctl" "$d/bin/"
    chmod +x "$d/bin/rclone" "$d/bin/systemctl"
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
# the read-only case below would notice a temporary file left behind, and so is
# XDG_RUNTIME_DIR, which is where the tray's own lock lives: the real one from the
# session this suite runs in must not be part of the experiment.
doc_run() {
    local d="$1"; shift
    local path="$d/bin:$DOC_TOOLS"
    [ -n "$DOC_PATH_OVERRIDE" ] && path="$DOC_PATH_OVERRIDE"
    # DOC_TIMEOUT is set by doc_run_checked for the one case whose defect is a read
    # that never returns: without it a reverted fix hangs the suite rather than
    # failing one case. timeout is in DOC_TOOLS, so it is on the sandbox PATH too.
    local cmd=("$DOCTOR_BIN" "$@")
    if [ -n "${DOC_TIMEOUT:-}" ]; then cmd=(timeout "$DOC_TIMEOUT" "${cmd[@]}"); fi
    env HOME="$d/home" XDG_CONFIG_HOME="$d/cfg" XDG_CACHE_HOME="$d/cache" \
        XDG_DATA_HOME="$d/data" XDG_RUNTIME_DIR="$d/run" TMPDIR="$d/tmp" PATH="$path" \
        DOC_TIMER_ENABLED="$DOC_TIMER_ENABLED" DOC_TIMER_ACTIVE="$DOC_TIMER_ACTIVE" \
        DOC_WATCH_ENABLED="${DOC_WATCH_ENABLED:-disabled}" \
        DOC_WATCH_ACTIVE="${DOC_WATCH_ACTIVE:-inactive}" \
        DOC_LSD_RC="${DOC_LSD_RC:-0}" DOC_LSD_ERR="${DOC_LSD_ERR:-}" \
        "${cmd[@]}"
}

# doc_run_checked <fixture> [arguments...] -- doc_run under a twenty second clock.
doc_run_checked() {
    local d="$1"; shift
    DOC_TIMEOUT=20
    doc_run "$d" "$@"
    local rc=$?
    DOC_TIMEOUT=""
    return "$rc"
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

# The tray check has to name a tray for THIS install. The old probe was
# `timeout 5 pgrep -f 'python3 .*/onedrive-tray'`: the `timeout` process's own
# command line holds that pattern, so the probe matched itself, and pgrep is
# machine-wide, so another install's tray matched as well. Measured in a sandbox
# with no tray at all, the doctor printed "ok tray running (pid N)" with two
# different, already-dead pids on consecutive runs, and the two "no tray process"
# branches below were unreachable. The fact the tray publishes itself is an
# exclusive flock on its lock file, held for its whole life, under this install's
# own XDG_RUNTIME_DIR (bin/onedrive-tray, acquire_lock), so that lock is the
# probe and pgrep is not needed at all.
#
# tray_lock_holder <fixture> -- hold that lock the way the tray does, print the
# holder's pid, and leave it running; the caller kills it. --close keeps the
# lock's file description out of the `sleep` child, so killing the holder really
# releases the lock, which is what the tray's own death does. The output is
# redirected because a background job inside a command substitution keeps the
# substitution's pipe open until it exits.
tray_lock_holder() {
    flock -o -x "$1/run/rclone-onedrive-tray.lock" sleep 30 >/dev/null 2>&1 &
    printf '%s' "$!"
}
# tray_lock_release <pid> -- stop a holder and wait for the lock to go with it.
tray_lock_release() {
    kill "$1" 2>/dev/null
    wait "$1" 2>/dev/null
}

doc_fixture tray-running
TRAY_HOLDER="$(tray_lock_holder "$DOC_FX")"
sleep 0.3
run "a running tray: the ok line names the pid and the icon directory" 0 \
    "running (pid $TRAY_HOLDER), icons in $DOC_FX/data/rclone-onedrive-tray/icons" \
    doc_run "$DOC_FX" --offline
# The icon directory is the other half of the running branch.
rm -rf "$DOC_FX/data/rclone-onedrive-tray/icons"
run "a running tray with no icon directory is a warning that names it" 0 \
    "running (pid $TRAY_HOLDER) but $DOC_FX/data/rclone-onedrive-tray/icons is missing" \
    doc_run "$DOC_FX" --offline
# A directory that exists and holds no icon is the third state, and the one the
# -d test could not tell from a healthy tray: the tray writes the five status
# icons at start, so an unwritable or full directory gave a blank panel icon and
# this row said ok.
mkdir -p "$DOC_FX/data/rclone-onedrive-tray/icons"
run "a running tray whose icons were never written is a warning, not an ok" 0 \
    "but no icon was written to $DOC_FX/data/rclone-onedrive-tray/icons" \
    doc_run "$DOC_FX" --offline
tray_lock_release "$TRAY_HOLDER"

# With no lock there is no tray for this install, in both of the branches the
# always-matching probe made dead code: with and without the icon directory.
doc_fixture tray-absent-with-icons
run "no lock with the icon directory there: no tray process, and why that is normal" 0 \
    "no tray process, but $DOC_FX/data/rclone-onedrive-tray/icons exists" \
    doc_run "$DOC_FX" --offline
doc_fixture tray-absent
rm -rf "$DOC_FX/data/rclone-onedrive-tray/icons"
run "no lock and no icon directory: no tray process, and where to start it" 0 \
    "no tray process and no $DOC_FX/data/rclone-onedrive-tray/icons" \
    doc_run "$DOC_FX" --offline

# The lock is the question and flock is what asks it, so a machine without flock
# must not be told there is no tray: the answer is that it could not be told.
doc_fixture tray-lock-untestable
: > "$DOC_FX/run/rclone-onedrive-tray.lock"
DOC_PATH_OVERRIDE="$DOC_FX/bin:$DOC_NOFLOCK"
run "a lock flock cannot test is not reported as no tray" 1 \
    "could not be told" doc_run "$DOC_FX" --offline
DOC_PATH_OVERRIDE=""

# The two cases below were written against the machine-wide scan, and they still
# hold for the lock: what a process's command line says no longer decides
# anything. The second one runs a real process that looks like another install's
# tray, so a doctor that went back to scanning would report it.
title "the tray probe finds a tray, not its name in any command line"
doc_fixture tray-or-tail
TRAY_HOLDER="$(tray_lock_holder "$DOC_FX")"
sleep 0.3
run "the log tail is skipped and the tray behind it is the one reported" 0 \
    "running (pid $TRAY_HOLDER), icons in $DOC_FX/data/rclone-onedrive-tray/icons" \
    doc_run "$DOC_FX" --offline
tray_lock_release "$TRAY_HOLDER"
run "and a tail on its own is not a tray" 0 "no tray process" \
    doc_run "$DOC_FX" --offline
doc_fixture tray-foreign
bash -c 'exec -a "python3 /home/u/.local/bin/onedrive-tray" sleep 20' &
FOREIGN_TRAY=$!
sleep 0.3
run "and another install's tray is not this install's" 0 "no tray process" \
    doc_run "$DOC_FX" --offline
kill "$FOREIGN_TRAY" 2>/dev/null
wait "$FOREIGN_TRAY" 2>/dev/null

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

# The config is read with `.`, and the doctor, the tray and the wrapper all
# accept a line that starts with `export `. The doctor's two scans for key names
# did not: they matched from the first character, so `export RETRIES="three"`
# was not a RETRIES line to them. The wrapper refused the same file, which left
# the diagnostic certifying a config that nothing would sync with. Measured
# before the fix: "ok config ... sets REMOTE and LOCAL" and "6 ok, 5 warn,
# nothing failed", exit 0, against "RETRIES='three' is not a positive integer"
# from the wrapper.
doc_fixture export-bad-retries 'export RETRIES="three"'
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q '^fail config.*RETRIES' <<<"$DOCTOR_OUT"; then
    ok "an exported RETRIES the wrapper refuses is a failed config check too"
else
    bad "export RETRIES=three: exit $DOCTOR_RC, $(grep -m1 config <<<"$DOCTOR_OUT")"
fi

# The same key again, for its second verdict: the logfile check judged
# MAX_LOG_BYTES on its own and only warned, so the prefix made the run exit 0
# while the wrapper refused to sync at all. One key gets one verdict, and it is
# the failure the wrapper's own refusal implies.
doc_fixture export-bad-max-log 'export MAX_LOG_BYTES="5MB"'
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q '^fail config.*MAX_LOG_BYTES' <<<"$DOCTOR_OUT" &&
        ! grep -q '^warn logfile.*MAX_LOG_BYTES' <<<"$DOCTOR_OUT"; then
    ok "an exported MAX_LOG_BYTES is one failed verdict, not a warn that exits 0"
else
    bad "export MAX_LOG_BYTES=5MB: exit $DOCTOR_RC, $(grep -m1 'logfile\|config' <<<"$DOCTOR_OUT")"
fi

# The filters guard was the other half of the same bug: it also anchored on the
# key, and a config whose only FILTERS_FILE line carried the prefix got no
# mention of the path at all, on this line or any other.
doc_fixture export-bad-filters
export_cfg="$DOC_FX/cfg/rclone-onedrive-tray/config"
sed -i 's|^FILTERS_FILE=|# FILTERS_FILE=|' "$export_cfg"
printf 'export FILTERS_FILE="/nonexistent/filters.txt"\n' >> "$export_cfg"
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q '^fail paths.*FILTERS_FILE' <<<"$DOCTOR_OUT"; then
    ok "an exported FILTERS_FILE that is missing fails the paths check"
else
    bad "export FILTERS_FILE: exit $DOCTOR_RC, $(grep -m1 paths <<<"$DOCTOR_OUT")"
fi

# The third file the paths check reads, and the one the guard for the log and for
# FILTERS_FILE missed. `-e` and `-r` are both true for a fifo, so the doctor's
# `grep -c` waited for a writer that never comes and the whole check hung with no
# line and no exit: this case ran for longer than the twenty seconds below before
# the fix. onedrive-sync skips a non-regular exclude list, so no folder is excluded
# either way and the answer is a failure with the right sentence in it.
doc_fixture exclude-fifo
mkfifo "$DOC_FX/exclude.fifo"
printf 'EXCLUDE_FOLDERS_FILE="%s"\n' "$DOC_FX/exclude.fifo" \
    >> "$DOC_FX/cfg/rclone-onedrive-tray/config"
DOCTOR_OUT="$(doc_run_checked "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q '^fail paths.*EXCLUDE_FOLDERS_FILE.*not a regular file' \
        <<<"$DOCTOR_OUT"; then
    ok "a fifo exclude list is named, not waited on for a writer"
else
    bad "fifo EXCLUDE_FOLDERS_FILE: exit $DOCTOR_RC, $(grep -m1 paths <<<"$DOCTOR_OUT")"
fi

# And the same rule for the row that judges whether the wrapper can open the log.
# A directory passes -e and -w, stat answers 4096 bytes for it, and the row said
# "ok logfile ... writable, 4096 of 5242880 bytes" while onedrive-sync refused the
# same path with "cannot write the log ...: Is a directory" — the summary then read
# "nothing failed", exit 0. Measured before the fix: 6 ok, 6 warn, nothing failed,
# exit 0 against a wrapper that stops every run.
# The doctor has to know about a pause, or a paused install reads as a healthy one:
# every run is turned away by the wrapper, the log is quiet, the timer is active and
# the summary says nothing failed. The stamp lives in the cache directory the tray
# uses, whatever LOG says.
doc_fixture paused-install
mkdir -p "$DOC_FX/cache/rclone-onedrive-tray"
printf '%s' "$(( $(date +%s) + 900 ))" > "$DOC_FX/cache/rclone-onedrive-tray/paused-until"
# Not --quiet: a pause is a healthy state, so its row is an ok line and quiet hides
# exactly the line this case is about.
run "a pause in force is reported, with the time it ends" 0 \
    "automatic sync is paused until" doc_run "$DOC_FX" --offline
printf 'not-a-time' > "$DOC_FX/cache/rclone-onedrive-tray/paused-until"
run "and a stamp that holds no time is a warning, not a silence" 0 \
    "does not hold a time" doc_run "$DOC_FX" --quiet --offline
printf '%s' "$(( $(date +%s) - 900 ))" > "$DOC_FX/cache/rclone-onedrive-tray/paused-until"
run "and a pause that ran out is a warning until the next run clears it" 0 \
    "ran out at" doc_run "$DOC_FX" --quiet --offline
rm -f "$DOC_FX/cache/rclone-onedrive-tray/paused-until"

doc_fixture log-is-a-directory
rm -f "$DOC_FX/cache/sync.log"; mkdir -p "$DOC_FX/cache/sync.log"
DOCTOR_OUT="$(doc_run "$DOC_FX" --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q '^fail logfile.*not a regular file' <<<"$DOCTOR_OUT" &&
        ! grep -qE '^ok +logfile' <<<"$DOCTOR_OUT"; then
    ok "a LOG that is a directory fails the logfile row instead of reading as writable"
else
    bad "LOG is a directory: exit $DOCTOR_RC, $(grep -m1 logfile <<<"$DOCTOR_OUT")"
fi

# And the other side of that rule: a character device is not a regular file either,
# and it is what the wrapper can append to. onedrive-sync opens the log with
# `: >>"$LOG"`, which /dev/null and /dev/stderr are for, and its only other use of
# the path is the rotation guard `[ -f "$LOG" ]`, which skips what it cannot size.
# A row that fails every non-regular file turned a working install into exit 1.
# `report()` pads with printf '%-4s %-9s %s\n', so the verdict is followed by at
# least one space: `^ok logfile` matches nothing, which is why these two cases use
# `^ok +logfile` and the negative above was dead as written.
doc_fixture log-is-a-device 'LOG="/dev/null"'
DOCTOR_OUT="$(doc_run "$DOC_FX" --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 0 ] && grep -qE '^ok +logfile' <<<"$DOCTOR_OUT"; then
    ok "a LOG the wrapper can append to is not failed for being a device"
else
    bad "LOG=/dev/null: exit $DOCTOR_RC, $(grep -m1 logfile <<<"$DOCTOR_OUT")"
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

# A run that refused before it invoked rclone ends state=stopped tag=other: that is
# what every refuse() in the wrapper writes, and the doctor's report had no branch
# for the tag, so a permanently refusing install was certified as "no failure hint
# in it" with exit 0 while the tray painted red.
doc_fixture refusal-other
cat >> "$DOC_FX/cache/sync.log" <<'EOF'
2026/10/04 03:54:31 ERROR: /home/u/OneDrive does not exist. Create it first:  mkdir -p "/home/u/OneDrive"  (or point LOCAL at the right directory in the config)
2026/10/04 03:54:31 ONEDRIVE_RESULT v=1 state=stopped tag=other when=03:54 msg=/home/u/OneDrive does not exist. Create it first:  mkdir -p "/home/u/OneDrive"  (or point LOCAL at the right directory in the config)
EOF
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q "stopped this run before it synced" <<<"$DOCTOR_OUT"; then
    ok "a wrapper refusal is a failure, not a log with nothing in it"
else
    bad "tag=other refusal: exit $DOCTOR_RC, $(head -1 <<<"$DOCTOR_OUT")"
fi
check "and the sentence points at the log for the reason" \
    grep -q "the log says why" <<<"$DOCTOR_OUT"

# One byte that is not text used to silence every log check in the doctor: GNU grep
# calls such a file binary and prints nothing for it, so a log holding a NUL was
# reported as one nothing had ever run through, while the tray read the same file
# and went red. rclone logs file names raw, so such a byte is reachable from a real
# run. The fixture carries no marker on purpose: the diagnosis has to come from the
# prose hint, which is the read that goes silent.
doc_fixture nul-in-log
{ printf '2026/10/04 03:54:31 CRITICAL: invalid_grant: maybe token expired?\n'; } >> "$DOC_FX/cache/sync.log"
printf '2026/10/04 03:54:32 INFO  : bad\000name.txt: Copied (new)\n' >> "$DOC_FX/cache/sync.log"
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q "expired sign-in" <<<"$DOCTOR_OUT"; then
    ok "a log with a NUL byte in it is still read"
else
    bad "NUL in the log: exit $DOCTOR_RC, $(head -1 <<<"$DOCTOR_OUT")"
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

# The classification table names six classes and only three were ever fed a line
# (auth, network and none), so the warn line the other five share could be replaced
# with anything and every suite stayed green. One fixture per class, through the
# real doctor, so a class that stops being named is a failure.
title "the failure classes the doctor names"
doc_class() {  # doc_class <a log line> <the class it must be named as>
    doc_fixture "class-$2"
    printf '%s\n' "$1" >> "$DOC_FX/cache/sync.log"
    DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
    if [ "$DOCTOR_RC" -eq 0 ] && grep -qF "a [$2] failure is in the log" <<<"$DOCTOR_OUT"; then
        ok "a line in the $2 class is named as [$2]"
    else
        bad "$2: exit $DOCTOR_RC, $(grep -m1 ' log ' <<<"$DOCTOR_OUT")"
    fi
}
doc_class '2026/10/01 20:05:00 CRITICAL: prior lock file found in ~/.cache/rclone/bisync' lock
doc_class '2026/10/01 20:05:00 ERROR : Safety abort: too many deletes (>50%, 150 of 200) on Path1' maxdelete
doc_class '2026/10/01 20:05:00 ERROR : Access test failed: Path1 count 1, Path2 count 0 - RCLONE_TEST' access
doc_class '2026/10/01 20:05:00 ERROR : Bisync aborted. Must run --resync to recover.' resync
# rclone's refusal of an empty remote also ends in "Bisync critical error", so it
# has to be its own class: the generic [resync] answer tells the user to run the
# one command that rebuilds an equally empty baseline.
doc_class '2026/10/04 08:05:45 ERROR : Bisync critical error: empty prior Path1 listing: /home/u/.cache/rclone/bisync/a..b.path1.lst' emptyremote
doc_class '2026/10/01 20:05:00 ERROR : unknown flag: --resilient' oldrclone

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

# The wrapper now ends a run with one machine-readable marker, so the doctor
# asks the log for one before it reads any English. The log below is the case
# the prose reader gets wrong: rclone's line is a token fetch that never reached
# Microsoft, which the table above calls [network], while the wrapper's own
# verdict for that run is tag=auth. The marker is the newer of the two, and it
# is the one the doctor has to believe.
title "the doctor reads the wrapper's result marker"
doc_fixture marker-auth-over-network
: > "$DOC_FX/cache/sync.log"
cat >> "$DOC_FX/cache/sync.log" <<'EOF'
2026/10/04 03:54:30 CRITICAL: failed to get root: Get "https://graph.microsoft.com/v1.0/drives/b!/root": couldn't fetch token: Post "https://login.microsoftonline.com/common/oauth2/v2.0/token": EOF
2026/10/04 03:54:31 ONEDRIVE_RESULT v=1 state=error tag=auth when=03:54 msg=the sign-in was refused or has expired; use the tray's 'Re-authorise OneDrive' item, or run: rclone config reconnect docfake:
EOF
DOCTOR_OUT="$(doc_run "$DOC_FX" --quiet --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 1 ] && grep -q "expired sign-in" <<<"$DOCTOR_OUT" &&
        ! grep -q "a network problem" <<<"$DOCTOR_OUT" &&
        grep -qE 'from [0-9]+[smhd] ago' <<<"$DOCTOR_OUT"; then
    ok "a marker's tag decides the class, not the English beside it"
else
    bad "marker tag=auth over a network line: exit $DOCTOR_RC, $(grep ' log ' <<<"$DOCTOR_OUT" | head -1)"
fi

# The other half of reading a marker: one saying the run synced is this log's
# success line, so it clears the refusal written before it even though rclone
# wrote no "Bisync successful" for the reader to find.
doc_fixture marker-synced-clears
: > "$DOC_FX/cache/sync.log"
cat >> "$DOC_FX/cache/sync.log" <<'EOF'
2026/10/04 03:54:30 CRITICAL: Failed to refresh token: oauth2: cannot fetch token: 400 Bad Request: {"error":"invalid_grant","error_description":"AADSTS70043: The refresh token has expired"}
2026/10/04 04:00:00 ONEDRIVE_RESULT v=1 state=synced tag=none when=04:00 msg=sync completed
EOF
DOCTOR_OUT="$(doc_run "$DOC_FX" --offline 2>&1)"; DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 0 ] && ! grep -q "expired sign-in" <<<"$DOCTOR_OUT" &&
        grep -q "every failure hint in it was followed by a sync that worked" <<<"$DOCTOR_OUT"; then
    ok "a synced marker is the success line that clears an older refusal"
else
    bad "synced marker after a refusal: exit $DOCTOR_RC, $(grep ' log ' <<<"$DOCTOR_OUT" | head -1)"
fi

# A log with no marker at all stays on the pattern table, which is what reads a
# log from a wrapper older than this, or one killed before it wrote its last
# line. The case above named "a token fetch that never reached Microsoft is a
# network problem, not an expiry" is that control, and the class battery is the
# rest of it.

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

# A watcher whose start limit has tripped: the unit is failed, every restart the
# unit asks for is refused by systemd, and the reason is in the journal. "inactive"
# and "failed" read the same to a row that only knows active, and the recovery is
# different, so the row has to tell them apart.
doc_fixture watch-failed 'WATCH="1"'
DOC_WATCH_ACTIVE="failed"
run "a watcher whose restart loop gave up names the reset command" 0 \
    "systemctl --user reset-failed docsync-watch.service" \
    doc_run "$DOC_FX" --quiet --offline
DOC_WATCH_ACTIVE=""

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
# The same pair, installed from a prefix this uninstall is not using. Its
# ExecStart names the same script, so it is this project's to turn off; the
# search for an orphan was anchored to the running uninstall's own prefix, which
# left a timer firing at a script this run has just deleted.
STALE_ELSEWHERE="zz-stale-elsewhere"
printf '[Unit]\nDescription=old install\n[Service]\nExecStart=%s/bin/onedrive-sync\n' \
    "$HOME/.local-old" > "$UNIT_DIR/$STALE_ELSEWHERE.service"
printf '[Unit]\nDescription=old install\n[Timer]\nOnUnitInactiveSec=5min\n' \
    > "$UNIT_DIR/$STALE_ELSEWHERE.timer"
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
check_absent "and one left by an install under another prefix" \
    "$UNIT_DIR/$STALE_ELSEWHERE.service" "$UNIT_DIR/$STALE_ELSEWHERE.timer"
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
# One of the two skips left in this suite, and the only environmental state a
# sandbox cannot manufacture: the file lives in /etc and creating or removing it
# needs root. The other is the hook-execution fixture further up, which needs a
# user namespace; CI asserts that it has one, so that case cannot skip there. The
# three conditional skips that used to sit beside them (systemd-analyze absent, a
# 0500 directory that is still writable, a pid that is already gone) build their
# own fixture now and pass on any machine, because a skip is not a pass and three
# of them together once ran the suite under its floor.
HOOK=/etc/NetworkManager/dispatcher.d/90-rclone-onedrive-tray
if [ -f "$HOOK" ]; then
    # The sentence the HOME-redirect guard prints, not the shared word "Leaving":
    # that word alone was satisfied by this guard on every run, because the suite
    # always redirects HOME.
    if grep -qF "Leaving $HOOK alone: HOME is redirected" <<<"$UNINSTALL_OUT"; then
        ok "left the machine-wide hook to the install that owns it"
    else
        bad "a hook exists for another unit and uninstall did not say it left it alone"
    fi
else
    skip "no NetworkManager hook on this machine to leave alone"
fi

# uninstall.sh sent both disables to /dev/null and still ended on "Done", with
# the units left enabled and the scripts they run already deleted. systemd's
# refusal is the only thing that says the uninstall did not finish.
title "a systemctl that refuses to disable on the way out"
mkdir -p "$UNIT_DIR"
printf '[Unit]\nDescription=probe\n[Service]\nExecStart=%s/onedrive-sync\n' \
    "$HOME/.local/bin" > "$UNIT_DIR/$UNIT-watch.service"
: > "$WORK/calls/systemctl-disable-fail"
UNINSTALL_FAIL_OUT="$(bash "$SRC_DIR/uninstall.sh" --prefix "$HOME/.local" 2>&1)"
rm -f "$WORK/calls/systemctl-disable-fail"
if grep -qF 'mock systemctl disable failure' <<<"$UNINSTALL_FAIL_OUT"; then
    ok "a refused disable is reported by the uninstaller"
else
    bad "uninstall swallowed a refused disable"
    printf '%s\n' "$UNINSTALL_FAIL_OUT" | head -4 | sed 's/^/        /'
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

# ---------------------------------------------------------------- the NM hook
# README, docs/DEPENDENCIES.md and docs/TROUBLESHOOTING.md all tell the user to
# run `install.sh --with-nm-dispatcher`, and no suite ran it: the coverage trace
# showed the whole `if [ "$NM_DISPATCHER" -eq 1 ]` body counting zero, and the
# case above ("left the machine-wide hook to the install that owns it") was
# satisfied by the HOME-redirect guard, which always fires here because the suite
# redirects HOME. The unit-name guard and the removal below it were never
# reached. NM_DISPATCHER_DIR and REAL_HOME_OVERRIDE are what point both scripts at
# a sandbox hook, so the three guards can be told apart without writing into /etc.
title "the NetworkManager dispatcher hook"
NM_HOME="$WORK/nm-home"
NM_CFG_DIR="$NM_HOME/.config/rclone-onedrive-tray"
NM_UNIT="zz-nm-probe"
NM_DIR="$WORK/nm-dispatch"
NM_SUDO_CALLS="$WORK/nm-sudo-calls"
NM_STUB="$WORK/nm-stubs"
NM_FAIL_STUB="$WORK/nm-stubs-refuse"
rm -rf "$NM_HOME" "$NM_DIR" "$NM_STUB" "$NM_FAIL_STUB"
mkdir -p "$NM_CFG_DIR" "$NM_DIR" "$NM_STUB" "$NM_FAIL_STUB"
cat > "$NM_CFG_DIR/config" <<EOF
REMOTE="$REMOTE"
LOCAL="$NM_HOME/OneDrive"
UNIT_NAME="$NM_UNIT"
INTERVAL_MIN="5"
WATCH="0"
EOF
# sudo is replaced by one that runs the call only when its target is inside this
# sandbox, so a run against the unfixed scripts cannot reach the machine's real
# hook -- and the unfixed run is the one these cases were written against.
cat > "$NM_STUB/sudo" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$NM_SUDO_CALLS"
target="\${@: -1}"
case "\$1:\$target" in
    install:"$WORK"/*) exec install -m 0755 "\${@: -2:1}" "\$target" ;;
    rm:"$WORK"/*)      exec rm -f "\$target" ;;
esac
exit 1
EOF
chmod +x "$NM_STUB/sudo"
NM_HOOK="$NM_DIR/90-rclone-onedrive-tray"

# First the guard this suite used to satisfy with the word "Leaving": with HOME
# redirected and no override, the hook would start a unit belonging to a user this
# run never touched, so it must not be installed -- the guard says "so it is not
# installed", and this is what makes that sentence true. Nothing here may write
# into /etc: the stub above only executes a target inside the sandbox.
rm -f "$NM_SUDO_CALLS" "$NM_HOOK"
NM_GUARD_OUT="$(env HOME="$NM_HOME" XDG_CONFIG_HOME="$NM_HOME/.config" \
    XDG_CACHE_HOME="$NM_HOME/.cache" XDG_DATA_HOME="$NM_HOME/.data" \
    NM_DISPATCHER_DIR="$NM_DIR" PATH="$NM_STUB:$PATH" \
    bash "$SRC_DIR/install.sh" --prefix "$NM_HOME/.local" --no-start \
        --with-nm-dispatcher 2>&1)"
if grep -qF "so it is not installed" <<<"$NM_GUARD_OUT"; then
    ok "a redirected HOME says the machine-wide hook is not installed"
else
    bad "the HOME-redirect guard printed no refusal"
    printf '%s\n' "$NM_GUARD_OUT" | grep -i 'hook\|HOME' | head -3 | sed 's/^/        /'
fi
check_absent "and it really did not install one" "$NM_HOOK" "$NM_SUDO_CALLS"

: > "$NM_SUDO_CALLS"
NM_OUT="$(env HOME="$NM_HOME" XDG_CONFIG_HOME="$NM_HOME/.config" \
    XDG_CACHE_HOME="$NM_HOME/.cache" XDG_DATA_HOME="$NM_HOME/.data" \
    NM_DISPATCHER_DIR="$NM_DIR" REAL_HOME_OVERRIDE="$NM_HOME" \
    PATH="$NM_STUB:$PATH" \
    bash "$SRC_DIR/install.sh" --prefix "$NM_HOME/opt" --no-start \
        --with-nm-dispatcher 2>&1)"
NM_RC=$?
if [ "$NM_RC" -eq 0 ] && grep -qF "installed $NM_HOOK" <<<"$NM_OUT"; then
    ok "--with-nm-dispatcher installs the hook"
else
    bad "--with-nm-dispatcher did not install the hook (rc=$NM_RC)"
    printf '%s\n' "$NM_OUT" | tail -4 | sed 's/^/        /'
fi
check "and the hook names the configured unit" \
    grep -qxF "UNIT=\"$NM_UNIT.service\"" "$NM_HOOK"
run "and no %UNIT_NAME% placeholder survives it" 1 "" \
    grep -qF '%UNIT_NAME%' "$NM_HOOK"
check "and the install went through sudo" \
    grep -qF -- "install -m 0755 -o root -g root" "$NM_SUDO_CALLS"
check "and sudo was handed the hook path the installer named" \
    grep -qF -- " $NM_HOOK" "$NM_SUDO_CALLS"
# The hook starts the sync service when an interface comes up, and the timer is the
# switch for automatic syncing: a pause is the tray having stopped and disabled it
# on purpose, so a hook that starts the service regardless ran a sync during every
# pause and on every install with automatic sync switched off. The gate has to come
# before the start.
check "and the hook asks the timer before it starts anything" \
    grep -qF -- "is-enabled --quiet" "$NM_HOOK"
check "and the name it asks about is the configured one" \
    grep -qF -- "$NM_UNIT.timer" "$NM_HOOK"
if [ "$(grep -n 'is-enabled --quiet' "$NM_HOOK" | head -1 | cut -d: -f1)" \
        -lt "$(grep -n 'start --no-block' "$NM_HOOK" | head -1 | cut -d: -f1)" ]; then
    ok "and it asks before it starts, not after"
else
    bad "the hook starts the service before it checks the timer"
fi
# The prefix is not ~/.local here, which is the branch that warns the hook is
# machine-wide and starts a unit outside the default prefix.
check "and a prefix outside ~/.local is called out as machine-wide" \
    grep -qF "this hook is machine-wide and will start $NM_UNIT.timer" <<<"$NM_OUT"

# Every case above reads the hook. This one runs it, because what the hook does is
# what matters: it is the dispatch that catches a machine up when an interface comes
# up, and the timer gate in it is the only thing that stops that happening during a
# pause or with automatic sync switched off. Commenting the gate out while keeping
# its text and its position leaves all of the cases above green, which is why this
# fixture exists.
#
# It needs a directory under /run/user, and an unprivileged test cannot create one.
# `unshare -rm` with a tmpfs over /run can, and then `id`, `getent`, `runuser` and
# `systemctl` are stubs that answer for one user and record what they were asked. A
# machine where that namespace cannot be created skips this rather than passing it.
NM_EXEC="$WORK/nm-exec"
rm -rf "$NM_EXEC"; mkdir -p "$NM_EXEC/stubs" "$NM_HOME/.config/systemd/user"
cat > "$NM_EXEC/stubs/id" <<'STUB'
#!/bin/bash
[ "$1" = -nu ] && { echo probeuser; exit 0; }
exec /usr/bin/id "$@"
STUB
cat > "$NM_EXEC/stubs/getent" <<STUB
#!/bin/bash
[ "\$1" = passwd ] && { echo "probeuser:x:4242:4242::$NM_HOME:/bin/sh"; exit 0; }
exec /usr/bin/getent "\$@"
STUB
cat > "$NM_EXEC/stubs/runuser" <<'STUB'
#!/bin/bash
# runuser -u USER -- env XDG_RUNTIME_DIR=... systemctl --user ...
shift; shift
[ "$1" = -- ] && shift
[ "$1" = env ] && shift
while [ $# -gt 0 ] && [ "${1#*=}" != "$1" ]; do shift; done
exec "$@"
STUB
cat > "$NM_EXEC/stubs/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$NM_EXEC_CALLS"
[ "$1" = --user ] && shift
if [ "$1" = is-enabled ]; then
    [ -f "$NM_EXEC_TIMER_ON" ] && exit 0 || exit 1
fi
exit 0
STUB
chmod +x "$NM_EXEC"/stubs/*
: > "$NM_HOME/.config/systemd/user/$NM_UNIT.service"

# The unit file and the timer marker are the caller's to set up: the whole point of
# the third run below is a user whose unit is not there.
nm_exec() {  # nm_exec <calls-file> <timer-marker-or-empty>
    local calls="$1" marker="$2"
    rm -f "$calls"
    if [ -n "$marker" ]; then : > "$marker"; else marker="$NM_EXEC/no-such-marker"; fi
    local helper="$NM_EXEC/run.sh"
    cat > "$helper" <<EOF
mount -t tmpfs t /run || exit 1
mkdir -p /run/user/4242
export PATH="$NM_EXEC/stubs:/usr/bin:/bin"
export NM_EXEC_CALLS="$calls" NM_EXEC_TIMER_ON="$marker"
HOME="$NM_HOME" sh "$NM_HOOK" wlan0 up
EOF
    unshare -rm sh "$helper"
}

if unshare -rm true 2>/dev/null; then
    nm_exec "$NM_EXEC/calls-on" "$NM_EXEC/timer-on"
    check "an interface coming up with the timer enabled starts the sync service" \
        grep -qxF -- "--user start --no-block $NM_UNIT.service" "$NM_EXEC/calls-on"
    check "and it asks the timer first" \
        grep -qxF -- "--user is-enabled --quiet $NM_UNIT.timer" "$NM_EXEC/calls-on"
    # The gate: the same hook, the same interface, a timer that is not enabled,
    # which is what a pause and a switched-off automatic sync both look like.
    nm_exec "$NM_EXEC/calls-off" ""
    # shellcheck disable=SC2016  # $1 belongs to the inner bash
    check "and with the timer off it asks and starts nothing" \
        bash -c '! grep -q start "$1"' _ "$NM_EXEC/calls-off"
    check "and it did ask, so the silence is the gate and not a hook that never ran" \
        grep -qxF -- "--user is-enabled --quiet $NM_UNIT.timer" "$NM_EXEC/calls-off"
    # A user the hook cannot find a unit for is a user it must not touch.
    rm -f "$NM_HOME/.config/systemd/user/$NM_UNIT.service"
    nm_exec "$NM_EXEC/calls-nounit" "$NM_EXEC/timer-on"
    check_absent "and a user with no unit of that name gets no systemctl call at all" \
        "$NM_EXEC/calls-nounit"
    : > "$NM_HOME/.config/systemd/user/$NM_UNIT.service"
else
    skip "the hook cannot be executed here: unshare -rm cannot make a /run/user entry"
fi

# The machine may have no dispatcher directory at all -- NetworkManager is not
# installed, or it keeps them elsewhere. The run has to skip the hook and say so.
NM_ABSENT="$WORK/nm-absent"
rm -rf "$NM_ABSENT" "$NM_HOOK" "$NM_SUDO_CALLS"
NM_NODIR_OUT="$(env HOME="$NM_HOME" XDG_CONFIG_HOME="$NM_HOME/.config" \
    XDG_CACHE_HOME="$NM_HOME/.cache" XDG_DATA_HOME="$NM_HOME/.data" \
    NM_DISPATCHER_DIR="$NM_ABSENT" REAL_HOME_OVERRIDE="$NM_HOME" \
    PATH="$NM_STUB:$PATH" \
    bash "$SRC_DIR/install.sh" --prefix "$NM_HOME/.local" --no-start \
        --with-nm-dispatcher 2>&1)"
if grep -qF "no $NM_ABSENT on this system; skipping." <<<"$NM_NODIR_OUT"; then
    ok "a missing dispatcher directory is skipped, and named"
else
    bad "a missing dispatcher directory was not reported"
    printf '%s\n' "$NM_NODIR_OUT" | grep -i 'dispatcher\|hook' | head -3 | sed 's/^/        /'
fi
check_absent "and nothing was installed and no sudo was run" "$NM_HOOK" "$NM_SUDO_CALLS"

# The unit-name guard: a hook that belongs to an install of a different unit.
# Removing it would take the working install's hook with it.
printf 'UNIT="zz-other-unit.service"\n' > "$NM_HOOK"
rm -f "$NM_SUDO_CALLS"
NM_OTHER_OUT="$(env HOME="$NM_HOME" XDG_CONFIG_HOME="$NM_HOME/.config" \
    XDG_CACHE_HOME="$NM_HOME/.cache" NM_DISPATCHER_DIR="$NM_DIR" \
    REAL_HOME_OVERRIDE="$NM_HOME" PATH="$NM_STUB:$PATH" \
    bash "$SRC_DIR/uninstall.sh" --prefix "$NM_HOME/.local" 2>&1)"
if grep -qF "Leaving $NM_HOOK alone: it does not mention $NM_UNIT" <<<"$NM_OTHER_OUT"; then
    ok "a hook naming another unit is left alone, and the sentence names it"
else
    bad "the unit-name guard did not fire"
    printf '%s\n' "$NM_OTHER_OUT" | grep -i 'networkmanager\|hook' | head -3 | sed 's/^/        /'
fi
check "and that hook is still on disk" test -f "$NM_HOOK"
check_absent "and sudo was not asked to remove it" "$NM_SUDO_CALLS"

# The removal path: the hook names the unit being uninstalled, so it goes.
printf 'UNIT="%s.service"\n' "$NM_UNIT" > "$NM_HOOK"
: > "$NM_SUDO_CALLS"
NM_RM_OUT="$(env HOME="$NM_HOME" XDG_CONFIG_HOME="$NM_HOME/.config" \
    XDG_CACHE_HOME="$NM_HOME/.cache" NM_DISPATCHER_DIR="$NM_DIR" \
    REAL_HOME_OVERRIDE="$NM_HOME" PATH="$NM_STUB:$PATH" \
    bash "$SRC_DIR/uninstall.sh" --prefix "$NM_HOME/.local" 2>&1)"
if grep -qF "Removing the NetworkManager hook (needs root)" <<<"$NM_RM_OUT"; then
    ok "a hook naming the configured unit is removed, and the run says so"
else
    bad "the removal path was not reached"
    printf '%s\n' "$NM_RM_OUT" | grep -i 'networkmanager\|hook' | head -3 | sed 's/^/        /'
fi
check "and sudo was asked for exactly that file" \
    grep -qxF "rm -f $NM_HOOK" "$NM_SUDO_CALLS"
check_absent "and the hook is gone" "$NM_HOOK"

# sudo can refuse or be absent, and the hook then stays. The run has to say that
# and name the command that would finish the job, instead of reporting a removal
# that did not happen.
printf 'UNIT="%s.service"\n' "$NM_UNIT" > "$NM_HOOK"
cat > "$NM_FAIL_STUB/sudo" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$NM_SUDO_CALLS"
exit 1
EOF
chmod +x "$NM_FAIL_STUB/sudo"
: > "$NM_SUDO_CALLS"
NM_FAIL_OUT="$(env HOME="$NM_HOME" XDG_CONFIG_HOME="$NM_HOME/.config" \
    XDG_CACHE_HOME="$NM_HOME/.cache" NM_DISPATCHER_DIR="$NM_DIR" \
    REAL_HOME_OVERRIDE="$NM_HOME" PATH="$NM_FAIL_STUB:$PATH" \
    bash "$SRC_DIR/uninstall.sh" --prefix "$NM_HOME/.local" 2>&1)"
if grep -qF "could not remove it; run: sudo rm -f $NM_HOOK" <<<"$NM_FAIL_OUT"; then
    ok "a refused sudo leaves the hook and names the command that removes it"
else
    bad "a failed removal was not reported"
    printf '%s\n' "$NM_FAIL_OUT" | grep -i 'hook\|remove' | head -3 | sed 's/^/        /'
fi
check "and the hook is still there for that command to remove" test -f "$NM_HOOK"

# The prefix guard, the one below the HOME guard and above the unit-name guard:
# this uninstall is for a scratch prefix, so a hook naming the configured unit is
# still not this run's to remove. Like the other two, its sentence is quoted.
printf 'UNIT="%s.service"\n' "$NM_UNIT" > "$NM_HOOK"
rm -f "$NM_SUDO_CALLS"
NM_PFX_OUT="$(env HOME="$NM_HOME" XDG_CONFIG_HOME="$NM_HOME/.config" \
    XDG_CACHE_HOME="$NM_HOME/.cache" NM_DISPATCHER_DIR="$NM_DIR" \
    REAL_HOME_OVERRIDE="$NM_HOME" PATH="$NM_STUB:$PATH" \
    bash "$SRC_DIR/uninstall.sh" --prefix "$NM_HOME/opt" 2>&1)"
if grep -qF "Leaving $NM_HOOK alone: this uninstall is for $NM_HOME/opt" <<<"$NM_PFX_OUT"; then
    ok "an uninstall for another prefix is left alone, and the sentence names it"
else
    bad "the prefix guard did not fire"
    printf '%s\n' "$NM_PFX_OUT" | grep -i 'networkmanager\|hook' | head -3 | sed 's/^/        /'
fi
check "and that hook is still on disk" test -f "$NM_HOOK"
check_absent "and sudo was not asked to remove it" "$NM_SUDO_CALLS"

summary
