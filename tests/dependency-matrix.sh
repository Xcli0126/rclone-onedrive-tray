#!/usr/bin/env bash
#
# dependency-matrix.sh: make the "if it is missing" column true.
#
# docs/DEPENDENCIES.md promises what happens when each dependency is absent. This
# hides one dependency at a time and checks that the promise holds. Documentation
# nobody executes is documentation that drifts, and the drift is only discovered
# by whoever installs it next.
#
#   tests/dependency-matrix.sh              run everything
#   tests/dependency-matrix.sh --verbose    also show each command's output
#
# Exits non-zero if any case disagrees with the documentation.
#
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$SRC_DIR/tests/lib/pyshim"
# The shim is imported from PYTHONPATH, and Python would cache it as a
# __pycache__ directory inside the source tree. Nothing here wants that cache.
export PYTHONDONTWRITEBYTECODE=1
# shellcheck source=tests/lib/harness.sh
. "$SRC_DIR/tests/lib/harness.sh" "$@"

# A PATH holding everything the scripts need except the named commands, so that
# `command -v` genuinely fails for them. Stubbing them with a failing script
# would not be the same test: the code asks whether they exist at all.
REDUCED="$SRC_DIR/tests/lib/reduced-path"
build_reduced_path() {
    rm -rf "$REDUCED"; mkdir -p "$REDUCED"
    local c
    for c in bash env sh dirname basename date mkdir rmdir stat tail head grep sed awk \
             tr cut sort uniq wc seq sleep printf echo cat rm mv cp ln chmod mktemp \
             find id getent runuser python3 rclone flock inotifywait xdg-open systemctl \
             systemd-run pkill install; do
        local src; src="$(command -v "$c" 2>/dev/null)" || continue
        local hide=0
        for h in "$@"; do [ "$c" = "$h" ] && hide=1; done
        [ "$hide" = 1 ] || ln -sf "$src" "$REDUCED/$c"
    done
}

# ---------------------------------------------------------------- fixtures
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

make_sync_fixture() {           # a config plus a fake rclone that records its call
    local dir="$1"
    mkdir -p "$dir/cfg/rclone-onedrive-tray" "$dir/cache/rclone/bisync" "$dir/tmp" "$dir/local"
    cat > "$dir/cfg/rclone-onedrive-tray/config" <<EOF
REMOTE="r:x"
LOCAL="$dir/local"
LOG="$dir/sync.log"
RCLONE="rclone"
RETRIES="1"
EOF
    cat > "$dir/rclone" <<'EOF'
#!/bin/bash
echo CALLED >> "$RC_LOG"
exit 0
EOF
    chmod +x "$dir/rclone"
    : > "$dir/called"
}

echo "dependency matrix, against what docs/DEPENDENCIES.md promises"

# ---------------------------------------------------------------- the tray
title "onedrive-tray"
# The guard is a function the script calls from main() now, so importing the
# module no longer reaches it and proves nothing about these messages: the script
# itself is what has to be run. That is also the point of the change, because a
# module that imports with no bindings is what lets --version answer on a machine
# that cannot run the tray.
tray_bindings() {
    env PYTHONPATH="$SRC_DIR/tests/lib" python3 - "$SRC_DIR/bin/onedrive-tray" <<'PY'
import sys
from load_module import load

module = load(sys.argv[1])
module.load_bindings()
print("LOADED")
PY
}

# The same import, with the binding for notifications hidden: the tray has to
# carry on without it, and load_bindings() is where that decision is made.
tray_notify_optional() {
    env PYTHONPATH="$SHIM:$SRC_DIR/tests/lib" HIDE_TYPELIB=Notify \
        python3 - "$SRC_DIR/bin/onedrive-tray" <<'PY'
import sys
from load_module import load, report

module = load(sys.argv[1])
module.load_bindings()
print("LOADED")
report([] if module.Notify is None else ["Notify is still %r" % (module.Notify,)])
PY
}

run "loads when every binding is present" 0 "LOADED" tray_bindings
run "no PyGObject: exits and names python3-gi" 1 "PyGObject" \
    env PYTHONPATH="$SHIM" HIDE_MODULE=gi python3 "$SRC_DIR/bin/onedrive-tray"
run "no Gtk typelib: exits and names GTK 3" 1 "GTK 3" \
    env PYTHONPATH="$SHIM" HIDE_TYPELIB=Gtk python3 "$SRC_DIR/bin/onedrive-tray"
run "no AppIndicator typelib: exits and names AppIndicator" 1 "AppIndicator" \
    env PYTHONPATH="$SHIM" HIDE_TYPELIB=AyatanaAppIndicator3,AppIndicator3 \
    python3 "$SRC_DIR/bin/onedrive-tray"
run "no pycairo: exits and names pycairo" 1 "pycairo" \
    env PYTHONPATH="$SHIM" HIDE_MODULE=cairo python3 "$SRC_DIR/bin/onedrive-tray"
run "no Notify typelib: still loads, notifications off" 0 "LOADED" \
    tray_notify_optional
# The machine most likely to be asked its version is the one that cannot run the
# tray, so this is the answer that has to survive a missing PyGObject. The version
# is read out of the script rather than written here: it is bumped on every
# release, and a literal went stale the first time that happened.
WANT_VERSION="$(sed -n 's/^VERSION = "\([0-9.]*\)"/\1/p' "$SRC_DIR/bin/onedrive-tray" | head -1)"
[ -n "$WANT_VERSION" ] || bad "could not read VERSION out of bin/onedrive-tray"
run "--version answers with the version while PyGObject is hidden" 0 "$WANT_VERSION" \
    env PYTHONPATH="$SHIM" HIDE_MODULE=gi \
    python3 "$SRC_DIR/bin/onedrive-tray" --version
# GTK aborts with a core dump when there is no display, so the tray has to say
# what it is before it gets that far.
run "no display: exits and says it needs a session" 1 "graphical session" \
    env -u DISPLAY -u WAYLAND_DISPLAY python3 "$SRC_DIR/bin/onedrive-tray"
# A display has to be set to get past the guard above, but the lock is taken
# before GTK connects to it, so nothing here opens a window. XDG_RUNTIME_DIR is
# unset on purpose: this is the fallback path, and the message names it.
run "unusable TMPDIR: says so instead of already running" 1 "Could not create the lock file" \
    env -u XDG_RUNTIME_DIR DISPLAY=:0 TMPDIR="$WORK/does-not-exist" \
        python3 "$SRC_DIR/bin/onedrive-tray"
# The lock is a fixed name, so it belongs somewhere only this user can write.
# The runtime directory wins over TMPDIR; with it pointing at nothing, the tray
# has to fail on the lock rather than quietly fall back to the shared one.
run "the lock prefers XDG_RUNTIME_DIR over TMPDIR" 1 "Could not create the lock file" \
    env DISPLAY=:0 XDG_RUNTIME_DIR="$WORK/no-runtime-dir" TMPDIR="$WORK" \
        XDG_CONFIG_HOME="$WORK/no-config" \
        python3 "$SRC_DIR/bin/onedrive-tray"

# The lock is a flock on the descriptor, but the file it lives in is visible and
# used to survive the process. An empty config directory gets the tray as far as
# the lock without ever touching GTK, so this needs no display.
LOCK_DIR="$WORK/tray-lock"; mkdir -p "$LOCK_DIR"
run "missing config: exits after taking the lock" 1 "Config not found" \
    env -u XDG_RUNTIME_DIR DISPLAY=:0 TMPDIR="$LOCK_DIR" \
        XDG_CONFIG_HOME="$WORK/no-config" \
        python3 "$SRC_DIR/bin/onedrive-tray"
check_absent "the lock file does not outlive the process" \
    "$LOCK_DIR/rclone-onedrive-tray.lock"

# English strings double as the translation keys, so a key shaped like an
# identifier is shipped verbatim to an English user: the resync confirmation
# once read "dlg_resync_body" in the default UI. The shape of every t("...") key
# is therefore a test, along with its Chinese entry.
tray_strings() {
    python3 - "$SRC_DIR/bin/onedrive-tray" "$1" <<'PY'
import ast
import re
import sys

path, mode = sys.argv[1], sys.argv[2]
tree = ast.parse(open(path, encoding="utf-8").read())

literals = []
for node in ast.walk(tree):
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == "t" and node.args
            and isinstance(node.args[0], ast.Constant)
            and isinstance(node.args[0].value, str)):
        literals.append((node.lineno, node.args[0].value))

if mode == "prose":
    bad = [(n, k) for n, k in literals if re.fullmatch(r"[a-z][a-z0-9_]*", k)]
    for n, k in bad:
        print(f"line {n}: t({k!r}) is a symbolic key, not English prose")
    sys.exit(1 if bad else 0)

if mode == "zh":
    strings = None
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                getattr(t, "id", None) == "STRINGS" for t in node.targets):
            strings = ast.literal_eval(node.value)
            break
    if strings is None:
        sys.exit("STRINGS table not found")
    zh = strings.get("zh", {})
    bad = []
    for lineno, key in literals:
        if key not in zh:
            bad.append(f"line {lineno}: t({key!r}) has no zh translation")
            continue
        want = set(re.findall(r"\{(\w+)\}", key))
        got = set(re.findall(r"\{(\w+)\}", zh[key]))
        if want != got:
            bad.append(f"line {lineno}: {sorted(want)} in the key, "
                       f"zh has {sorted(got)}")
    for b in bad:
        print(b)
    sys.exit(1 if bad else 0)

# Gtk.ButtonsType.* labels come from the system locale, so an English dialog on
# a Chinese desktop showed 取消/确定. Dialogs have to add their own buttons.
bad = [f"line {n.lineno}: Gtk.ButtonsType.{n.attr}"
       for n in ast.walk(tree)
       if isinstance(n, ast.Attribute) and n.attr in ("OK_CANCEL", "YES_NO")
       and isinstance(n.value, ast.Attribute) and n.value.attr == "ButtonsType"]
for b in bad:
    print(b + " follows the system locale, not UI_LANG")
sys.exit(1 if bad else 0)
PY
}

run "translated strings: every t() key is English prose" 0 "" tray_strings prose
run "translated strings: every t() key has a zh entry" 0 "" tray_strings zh
run "dialogs: no locale-dependent stock buttons" 0 "" tray_strings buttons

# unit_states() must tell a disabled unit and an unreadable one from a pause.
# Treating "anything but enabled" as paused made a missing timer unit announce
# "Automatic sync paused (click to resume)" when nothing had been paused.
tray_unit_states() {
    env PYTHONPATH="$SRC_DIR/tests/lib" python3 - "$SRC_DIR/bin/onedrive-tray" <<'PY'
import sys
from load_module import load, report      # noqa: E402

module = load(sys.argv[1])


class Fake:
    service = "onedrive-sync.service"
    timer = "onedrive-sync.timer"


def sh_for(active, enabled):
    def sh(cmd, timeout=30):
        if "is-active" in cmd:
            return active
        if "is-enabled" in cmd:
            return enabled
        raise AssertionError(cmd)
    return sh


cases = [
    ("active and enabled", (0, "active\ninactive", ""), (0, "enabled", ""),
     (True, "enabled")),
    ("activating counts as active", (0, "activating\ninactive", ""), (0, "enabled", ""),
     (True, "enabled")),
    ("unit present but disabled", (3, "inactive\ninactive", ""), (0, "disabled", ""),
     (False, "off")),
    ("unit missing", (3, "inactive\ninactive", ""),
     (1, "", "Failed to get unit file state for onedrive-sync.timer: No such file "
             "or directory"), (False, "unknown")),
    ("systemctl failed", (1, "", "stub failure"), (1, "", "stub failure"),
     (False, "unknown")),
]
bad = []
for name, active, enabled, want in cases:
    module.sh = sh_for(active, enabled)
    got = module.Tray.unit_states(Fake())
    if got != want:
        bad.append(f"{name}: unit_states() -> {got!r}, wanted {want!r}")
report(bad)
PY
}

run "unit states: disabled and unknown are not 'paused'" 0 "" tray_unit_states

# OPEN_APP_CMD is written shell-style, so a quoted path has to be split the way
# a shell would. str.split() kept the quote characters and spawn() failed
# silently; a command that cannot be launched must be reported instead.
tray_open_app() {
    env PYTHONPATH="$SRC_DIR/tests/lib" python3 - "$SRC_DIR/bin/onedrive-tray" <<'PY'
import sys
from load_module import load, report      # noqa: E402

module = load(sys.argv[1])


class Fake:
    def __init__(self, cmd):
        self.open_cmd = cmd
        self.open_name = "the app"
        self.t = module.make_translator("en")
        self.notes = []

    def notify(self, title, body):
        self.notes.append(body)


calls = []
real_spawn = module.spawn
module.spawn = lambda argv: (calls.append(list(argv)), True)[1]

bad = []
quoted = Fake('"my app" --flag')
module.Tray.open_app(quoted)
if calls != [["my app", "--flag"]]:
    bad.append(f"quoted command became {calls!r}, wanted [['my app', '--flag']]")
if quoted.notes:
    bad.append(f"a command that spawned fine still notified: {quoted.notes!r}")

module.spawn = real_spawn
missing = Fake("definitely-not-a-real-command-xyz")
module.Tray.open_app(missing)
if not missing.notes or "Could not start" not in missing.notes[-1]:
    bad.append(f"a command that cannot start was not reported: {missing.notes!r}")

unclosed = Fake('"unclosed')
module.Tray.open_app(unclosed)
if not unclosed.notes:
    bad.append("an unsplittable command was not reported")
report(bad)
PY
}

run "OPEN_APP_CMD: quoted command is split, failure is reported" 0 "" tray_open_app

# ---------------------------------------------------------------- the wrapper
title "onedrive-sync"
FIX="$WORK/sync"; make_sync_fixture "$FIX"
run "runs rclone when everything is present" 0 "" \
    env -i PATH="$FIX:$PATH" HOME="$HOME" XDG_CONFIG_HOME="$FIX/cfg" \
        XDG_CACHE_HOME="$FIX/cache" TMPDIR="$FIX/tmp" RC_LOG="$FIX/called" \
    bash "$SRC_DIR/bin/onedrive-sync"
if [ -s "$FIX/called" ]; then ok "  rclone was actually invoked"; else bad "rclone was never invoked"; fi

build_reduced_path rclone
run "no config: explains which file is missing" 1 "config not found" \
    env -i PATH="$REDUCED" HOME="$HOME" XDG_CONFIG_HOME="$WORK/none" \
        XDG_CACHE_HOME="$WORK/none" TMPDIR="$WORK" bash "$SRC_DIR/bin/onedrive-sync"

build_reduced_path rclone
run "no rclone: exits and names rclone" 1 "rclone not found" \
    env -i PATH="$REDUCED" HOME="$HOME" XDG_CONFIG_HOME="$FIX/cfg" \
        XDG_CACHE_HOME="$FIX/cache" TMPDIR="$FIX/tmp" RC_LOG="$WORK/never" \
    bash "$SRC_DIR/bin/onedrive-sync"

build_reduced_path flock
: > "$FIX/called"
run "no flock: refuses to run rather than skipping" 1 "flock" \
    env -i PATH="$REDUCED:$FIX" HOME="$HOME" XDG_CONFIG_HOME="$FIX/cfg" \
        XDG_CACHE_HOME="$FIX/cache" TMPDIR="$FIX/tmp" RC_LOG="$FIX/called" \
    bash "$SRC_DIR/bin/onedrive-sync"
if [ -s "$FIX/called" ]; then
    bad "rclone ran without a lock (it must not)"
else
    ok "rclone was not invoked without a lock"
fi

# An rclone older than the flags in BISYNC_ARGS rejects them before it opens its
# log file, so this used to end as a bare "[other] see log" pointing at nothing.
# The floor in the wrapper's own sentence belongs to bin/onedrive-sync, and that
# sentence still said 1.65 when this case was written; what is asserted here is
# that an unknown flag is classified as a version problem at all rather than as
# "[other]". The real floor is asserted against install.sh, which owns the
# version check, in the installer section below.
mkdir -p "$WORK/oldbin"
printf '#!/bin/bash\necho "Error: unknown flag: --resilient" >&2\nexit 1\n' \
    > "$WORK/oldbin/rclone"
chmod +x "$WORK/oldbin/rclone"
run "rclone too old for the flags: names the flag and the version that has it" 1 \
    "does not know --resilient; that flag arrived in rclone 1.64" \
    env -i PATH="$WORK/oldbin:$PATH" HOME="$HOME" XDG_CONFIG_HOME="$FIX/cfg" \
        XDG_CACHE_HOME="$FIX/cache" TMPDIR="$FIX/tmp" RC_LOG="$WORK/never" \
    bash "$SRC_DIR/bin/onedrive-sync"

# ---------------------------------------------------------------- the watcher
title "onedrive-watch"
build_reduced_path inotifywait
run "no inotifywait: exits and names it" 1 "inotifywait" \
    env -i PATH="$REDUCED" HOME="$HOME" XDG_CONFIG_HOME="$FIX/cfg" \
        XDG_CACHE_HOME="$FIX/cache" TMPDIR="$FIX/tmp" bash "$SRC_DIR/bin/onedrive-watch"
run "no config: explains which file is missing" 1 "config not found" \
    env -i PATH="$PATH" HOME="$HOME" XDG_CONFIG_HOME="$WORK/none" \
        XDG_CACHE_HOME="$WORK/none" TMPDIR="$WORK" bash "$SRC_DIR/bin/onedrive-watch"

# Both cases above only reach the watcher's failure paths, so neither the
# debounce default nor the arguments inotifywait is handed were ever seen. This
# fixture leaves WATCH_DEBOUNCE unset and sets an exclude regex, and a stub
# inotifywait records the command line it was given before failing. A failing
# inotifywait is retried a few times and then ends the loop, so each run is cut
# short with timeout and its exit status deliberately ignored; the debounce line
# is printed before the loop is entered, and the recorded call is what the second
# case reads. The exit after repeated permanent failures has its own case in
# tests/install-flow.sh.
WATCH_FIX="$WORK/watch"; rm -rf "$WATCH_FIX"
mkdir -p "$WATCH_FIX/cfg/rclone-onedrive-tray" "$WATCH_FIX/local" \
         "$WATCH_FIX/bin" "$WATCH_FIX/tmp"
cat > "$WATCH_FIX/cfg/rclone-onedrive-tray/config" <<EOF
REMOTE="r:x"
LOCAL="$WATCH_FIX/local"
LOG="$WATCH_FIX/sync.log"
WATCH_EXCLUDE="zz-watch-exclude-probe"
EOF
cat > "$WATCH_FIX/bin/inotifywait" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$WATCH_CALLS"
exit 1
EOF
chmod +x "$WATCH_FIX/bin/inotifywait"
WATCH_CALLS="$WATCH_FIX/calls"

watch_run() {   # watch_run -- the watcher for a moment; timeout stops its loop
    env -i PATH="$WATCH_FIX/bin:$PATH" HOME="$HOME" \
        XDG_CONFIG_HOME="$WATCH_FIX/cfg" XDG_CACHE_HOME="$WATCH_FIX/cache" \
        TMPDIR="$WATCH_FIX/tmp" WATCH_CALLS="$WATCH_CALLS" \
        timeout 5 bash "$SRC_DIR/bin/onedrive-watch" 2>&1
}

watch_args() {  # watch_args -- the command line inotifywait was handed
    : > "$WATCH_CALLS"
    watch_run >/dev/null 2>&1
    cat "$WATCH_CALLS"
}

run "the default debounce is the documented 8 seconds" - "debounce 8s, settle 12s" watch_run
run "the watcher passes its exclude regex to inotifywait" - \
    "--exclude zz-watch-exclude-probe" watch_args

# ---------------------------------------------------------------- the installer
# install.sh ends by enabling its units through systemctl. Replacing systemctl
# keeps that from touching the units of the machine this suite runs on -- the
# config and unit directories are already redirected, but the enable --now call
# would reach the real user manager.
STUB="$WORK/stubs"; mkdir -p "$STUB"
printf '#!/bin/bash\nexit 0\n' > "$STUB/systemctl"
chmod +x "$STUB/systemctl"

# ------------------------------------------------- one file, three readers
# The config file has three readers: the tray parses it in Python, onedrive-sync
# sources it with `.` (the shipped example expands variables, so only a shell can
# read it), and the two installers share the sed reader in lib/config.sh. What bash
# does with each shape is the contract, because the wrapper is the reader whose
# answer the sync uses. The tray's parser had drifted from it: a value the writer
# escaped came back with the backslashes still in it, a single-quoted `${HOME}` was
# expanded although bash leaves it alone, and an escaped `\$VAR` was expanded too.
title "one file, three readers"
READERS="$WORK/readers"
rm -rf "$READERS"; mkdir -p "$READERS/home"
cat > "$READERS/config" <<'CFGEOF'
REMOTE="probe:Vault"
LOCAL="${HOME}/OneDrive"
# a comment line
CHECK_FILENAME="quote\"dollar\$tick\`slash\\end"
SINGLE='${HOME}/literal'
ESCAPED="\$HOME/cost"
FALLBACK="${READERS_UNSET:-fallback}/x"
EMPTY=""
UNQUOTED=simple
HASH=abc#def
SPACED=abc # a comment
   export UNIT_NAME="exported-name"
INTERVAL_MIN=7
SHOW_ICON="1"
SHOW_ICON="0"
CFGEOF
READER_KEYS="REMOTE LOCAL CHECK_FILENAME SINGLE ESCAPED FALLBACK EMPTY UNQUOTED HASH SPACED UNIT_NAME INTERVAL_MIN SHOW_ICON"

# The shared sed reader, which answers values as written: it does not expand
# `${VAR}` because the keys it is asked for are a binary name, a unit name, a
# number and a boolean.
# shellcheck disable=SC2016  # the script is for the inner bash, and its $1/$2/$3
#                             # are that shell's arguments, not this one's
sed_dump="$(env CONFIG_DIR="$READERS" bash -c '
    . "$1/lib/config.sh"
    for key in $3; do printf "%s=<%s>\n" "$key" "$(config_value "$key" "$2")"; done' \
    _ "$SRC_DIR" "$READERS/config" "$READER_KEYS")"

# What the wrapper sees, which is the answer that matters.
# shellcheck disable=SC2016  # same: ${!key-} is the inner shell's indirect read
src_dump="$(env HOME="$READERS/home" bash -c '
    set -a; . "$1"; set +a
    for key in $2; do printf "%s=<%s>\n" "$key" "${!key-}"; done' \
    _ "$READERS/config" "$READER_KEYS")"

# The tray's parser, through the same load_config() the tray uses.
py_dump="$(env HOME="$READERS/home" PYTHONPATH="$SRC_DIR/tests/lib" \
    python3 - "$SRC_DIR/bin/onedrive-tray" "$READERS/config" "$READER_KEYS" <<'PY'
import sys

from load_module import load

module = load(sys.argv[1])
module.CONFIG_FILE = sys.argv[2]
cfg = module.load_config()
for key in sys.argv[3].split():
    print("%s=<%s>" % (key, cfg.get(key, "")))
PY
)"

if [ "$src_dump" = "$py_dump" ]; then
    ok "the tray reads the file exactly as the shell that sources it does"
else
    bad "the tray's reader disagrees with bash"
    diff <(printf '%s\n' "$src_dump") <(printf '%s\n' "$py_dump") |
        sed 's/^/        /' | head -8
fi
# The installers' reader is deliberately narrower: no expansion, and a value it is
# not asked for cannot drift. Compared on the shapes it is asked for.
sed_narrow="$(printf '%s\n' "$sed_dump" | grep -vE '^(LOCAL|SINGLE|ESCAPED|FALLBACK)=')"
src_narrow="$(printf '%s\n' "$src_dump" | grep -vE '^(LOCAL|SINGLE|ESCAPED|FALLBACK)=')"
if [ "$sed_narrow" = "$src_narrow" ]; then
    ok "and the installers' shared reader agrees on the values it is asked for"
else
    bad "the installers' reader disagrees with bash"
    diff <(printf '%s\n' "$src_narrow") <(printf '%s\n' "$sed_narrow") |
        sed 's/^/        /' | head -8
fi
# The difference is the documented one, not an accident: a variable in a value the
# installers read comes back as written.
# shellcheck disable=SC2016  # the ${VAR} is the text being searched for
check "and it answers a \${VAR} value as written, which is what it is documented to do" \
    grep -qxF 'FALLBACK=<${READERS_UNSET:-fallback}/x>' <<<"$sed_dump"

title "install.sh"
PYSHIM_DIR="$WORK/pycairo-off"; mkdir -p "$PYSHIM_DIR"
cat > "$PYSHIM_DIR/sitecustomize.py" <<'EOF'
import os, sys
_block = os.environ.get("HIDE_MODULE", "")
if _block:
    class B:
        def find_spec(self, name, path=None, target=None):
            if name == _block or name.startswith(_block + "."):
                raise ImportError(f"No module named {name!r}")
            return None
    sys.meta_path.insert(0, B())
EOF

run "all present: installs" 0 "Installed" \
    env PATH="$STUB:$PATH" XDG_CONFIG_HOME="$WORK/i1" XDG_CACHE_HOME="$WORK/i1c" XDG_DATA_HOME="$WORK/i1d" \
    bash "$SRC_DIR/install.sh" --prefix "$WORK/i1p" --no-start
# The tray's stack is not the sync's: the README tells a server user to run
# onedrive-sync and the timer, and blocking the whole install on a desktop stack
# made that impossible to follow. It warns, installs the sync half, and leaves the
# icon out. The entry is pre-created so the case covers the machine that used to
# have the tray and no longer has the stack, which is the state the removal is
# for; a first install has nothing there to remove.
# XDG_CONFIG_HOME is what install.sh reads, so the entry lives directly under it.
mkdir -p "$WORK/i2/autostart"
printf 'stale entry from a machine that used to have the tray\n' \
    > "$WORK/i2/autostart/rclone-onedrive-tray.desktop"
run "no pycairo: installs the sync half and names python3-cairo" 0 "python3-cairo" \
    env PYTHONPATH="$PYSHIM_DIR" HIDE_MODULE=cairo XDG_CONFIG_HOME="$WORK/i2" \
        XDG_CACHE_HOME="$WORK/i2c" XDG_DATA_HOME="$WORK/i2d" \
    bash "$SRC_DIR/install.sh" --prefix "$WORK/i2p" --no-start
check "and the wrapper is installed anyway" \
    test -x "$WORK/i2p/bin/onedrive-sync"
# The old check here named "$WORK/i2/.config/autostart", a path this run never
# writes to: it passed because the file was absent from a directory that is not
# the autostart directory at all.
check "and no autostart entry is left for a tray that cannot run" \
    test ! -e "$WORK/i2/autostart/rclone-onedrive-tray.desktop"
# Put one back and run again: the removal has to be reported, so a user who had
# the tray installed before the packages went away is told what happened to it.
printf 'stale entry from a machine that used to have the tray\n' \
    > "$WORK/i2/autostart/rclone-onedrive-tray.desktop"
run "a re-run with the entry back removes it and says so" 0 "removed the autostart entry" \
    env PYTHONPATH="$PYSHIM_DIR" HIDE_MODULE=cairo XDG_CONFIG_HOME="$WORK/i2" \
        XDG_CACHE_HOME="$WORK/i2c" XDG_DATA_HOME="$WORK/i2d" \
    bash "$SRC_DIR/install.sh" --prefix "$WORK/i2p" --no-start
check "and it is gone afterwards" \
    test ! -e "$WORK/i2/autostart/rclone-onedrive-tray.desktop"
build_reduced_path flock
run "no flock: refuses and names flock" 1 "flock" \
    env -i PATH="$REDUCED" HOME="$HOME" XDG_CONFIG_HOME="$WORK/i3" \
    bash "$SRC_DIR/install.sh" --prefix "$WORK/i3p" --no-start

TRAY_SHIM="$WORK/notify-off"; mkdir -p "$TRAY_SHIM"
cp "$SHIM/sitecustomize.py" "$TRAY_SHIM/sitecustomize.py"
run "no Notify typelib: warns but installs anyway" 0 "Optional dependencies" \
    env PATH="$STUB:$PATH" PYTHONPATH="$TRAY_SHIM" HIDE_TYPELIB=Notify XDG_CONFIG_HOME="$WORK/i4" \
        XDG_CACHE_HOME="$WORK/i4c" XDG_DATA_HOME="$WORK/i4d" \
    bash "$SRC_DIR/install.sh" --prefix "$WORK/i4p" --no-start

# The distribution rclone is frequently below 1.65, so the installer has to say
# so instead of letting every later sync die on an unknown flag.
mkdir -p "$WORK/oldrclone"
cat > "$WORK/oldrclone/rclone" <<'EOF'
#!/bin/bash
[ "$1" = version ] && echo "rclone v1.60.1"
exit 0
EOF
chmod +x "$WORK/oldrclone/rclone"
run "rclone older than 1.65: installs, but warns about recovery" 0 "older than 1.65" \
    env PATH="$WORK/oldrclone:$STUB:$PATH" XDG_CONFIG_HOME="$WORK/i5" \
        XDG_CACHE_HOME="$WORK/i5c" XDG_DATA_HOME="$WORK/i5d" \
    bash "$SRC_DIR/install.sh" --prefix "$WORK/i5p" --no-start

# rclone too old for the flags: the old floor here was 1.65, and 1.65 is exactly
# the version a user would install to satisfy it. --recover, --max-lock,
# --conflict-resolve and --conflict-loser all arrived in 1.66 (checked against
# rclone's cmd/bisync/cmd.go at the v1.65.0 and v1.66.0 tags), so the installer
# asks the binary what it supports instead of trusting a version string, and
# names each flag the binary does not list. This fixture answers `bisync --help`
# the way 1.65 does, so the case is about the flags, not about the number.
mkdir -p "$WORK/rclone165"
cat > "$WORK/rclone165/rclone" <<'EOF'
#!/bin/bash
case "$1" in
    version) echo "rclone v1.65.0" ;;
    bisync)
        printf '%s\n' \
          "      --resilient       Allow future runs to retry after certain less-serious errors" \
          "      --check-access    Ensure expected RCLONE_TEST files are found on both paths" \
          "  -1, --resync          Performs the resync run." ;;
esac
exit 0
EOF
chmod +x "$WORK/rclone165/rclone"
R165_OUT="$(env PATH="$WORK/rclone165:$STUB:$PATH" HOME="$HOME" \
    XDG_CONFIG_HOME="$WORK/r165-cfg" XDG_CACHE_HOME="$WORK/r165-cache" \
    XDG_DATA_HOME="$WORK/r165-data" \
    bash "$SRC_DIR/install.sh" --prefix "$WORK/r165-prefix" --no-start 2>&1)"
check "rclone 1.65: the install still completes" grep -qF "Installed" <<<"$R165_OUT"
check "and it names the flags this rclone does not list" \
    grep -qF "has no --recover --max-lock --conflict-resolve --conflict-loser" <<<"$R165_OUT"
check "and it names 1.66, the version those flags arrived in" \
    grep -qF "1.66" <<<"$R165_OUT"

# The other half of asking the binary: a build that reports 1.65 and lists the
# four flags has them, so nothing may be said about a floor it already meets.
mkdir -p "$WORK/rclone165all"
cat > "$WORK/rclone165all/rclone" <<'EOF'
#!/bin/bash
case "$1" in
    version) echo "rclone v1.65.0" ;;
    bisync)
        printf '%s\n' \
          "      --recover         Automatically recover from interruptions" \
          "      --max-lock Duration   Consider lock files older than this to be expired" \
          "      --conflict-resolve string   Automatically resolve conflicts" \
          "      --conflict-loser ConflictLoserAction   Action to take on the loser" ;;
esac
exit 0
EOF
chmod +x "$WORK/rclone165all/rclone"
R165B_OUT="$(env PATH="$WORK/rclone165all:$STUB:$PATH" HOME="$HOME" \
    XDG_CONFIG_HOME="$WORK/r165b-cfg" XDG_CACHE_HOME="$WORK/r165b-cache" \
    XDG_DATA_HOME="$WORK/r165b-data" \
    bash "$SRC_DIR/install.sh" --prefix "$WORK/r165b-prefix" --no-start 2>&1)"
if grep -qF "1.66" <<<"$R165B_OUT"; then
    bad "a 1.65 build that lists all four flags was still warned about the floor"
else
    ok "a 1.65 build that does list the four flags is not warned"
fi

# config.example documents RCLONE as "the rclone binary to run, by name or by path.
# Change it to use a build outside PATH", and onedrive-sync and onedrive-doctor
# honour it. install.sh gated the whole install on `command -v rclone` and took its
# version warning from whatever PATH held, so the user who followed that advice
# could not install at all. These two cases are the two halves: nothing called
# rclone on PATH, and an old rclone on PATH beside a good one in the config.
ALT_DIR="$WORK/altbin"; ALT_CALLS="$WORK/alt-calls"
rm -rf "$ALT_DIR" "$WORK/alt-cfg"; mkdir -p "$ALT_DIR" "$WORK/alt-cfg/rclone-onedrive-tray"
cat > "$ALT_DIR/rclone" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$ALT_CALLS"
[ "\$1" = version ] && echo "rclone v1.75.1"
exit 0
EOF
chmod +x "$ALT_DIR/rclone"
cat > "$WORK/alt-cfg/rclone-onedrive-tray/config" <<EOF
REMOTE="r:x"
LOCAL="$WORK/alt-local"
UNIT_NAME="zz-alt-probe"
INTERVAL_MIN="5"
WATCH="0"
RCLONE="$ALT_DIR/rclone"
EOF
: > "$ALT_CALLS"
build_reduced_path rclone
run "a config naming a path with nothing called rclone on PATH still installs" 0 \
    "Installed" \
    env PATH="$STUB:$REDUCED" HOME="$HOME" XDG_CONFIG_HOME="$WORK/alt-cfg" \
        XDG_CACHE_HOME="$WORK/alt-cache" XDG_DATA_HOME="$WORK/alt-data" \
    bash "$SRC_DIR/install.sh" --prefix "$WORK/alt-prefix" --no-start
check "and the version check asked the binary the config names" \
    grep -qxF 'version' "$ALT_CALLS"

# The other half: an rclone on PATH that is too old, and a current one named by
# the config. The warning has to be about the binary the project will actually
# run, or it sends the user to upgrade something nothing uses.
mkdir -p "$WORK/oldpath"
cat > "$WORK/oldpath/rclone" <<'EOF'
#!/bin/bash
[ "$1" = version ] && echo "rclone v1.60.1"
exit 0
EOF
chmod +x "$WORK/oldpath/rclone"
: > "$ALT_CALLS"
ALTB_OUT="$(env PATH="$WORK/oldpath:$STUB:$PATH" HOME="$HOME" \
    XDG_CONFIG_HOME="$WORK/alt-cfg" XDG_CACHE_HOME="$WORK/alt-cache" \
    XDG_DATA_HOME="$WORK/alt-data" \
    bash "$SRC_DIR/install.sh" --prefix "$WORK/alt-prefix" --no-start 2>&1)"
if grep -qF 'older than 1.65' <<<"$ALTB_OUT"; then
    bad "the old rclone on PATH was warned about instead of the config's"
elif grep -qxF 'version' "$ALT_CALLS"; then
    ok "an old rclone on PATH is not what the config's RCLONE gets warned about"
else
    bad "the config's rclone was never asked its version"
fi

# ---------------------------------------------------------------- enable
# systemctl's own reason for a failed enable is the only thing that says why.
# The installer threw it away and warned "(no user systemd session?)", which is
# the wrong cause for a masked or missing unit, and then printed "Installed"
# over it. The captured sentence has to appear, followed by the same repair
# command the unreachable-manager branch already prints.
ENABLE_STUB="$WORK/enable-stubs"
rm -rf "$ENABLE_STUB"; mkdir -p "$ENABLE_STUB"
cat > "$ENABLE_STUB/systemctl" <<'EOF'
#!/bin/bash
shift
case "$1" in
    daemon-reload) exit 0 ;;
    show)          printf '%s\n' "$XDG_CONFIG_HOME/systemd/user/${@: -1}"; exit 0 ;;
    enable)        echo "Failed to enable unit: Unit file does not exist." >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$ENABLE_STUB/systemctl"
ENABLE_CFG="$WORK/enable-cfg"
rm -rf "$ENABLE_CFG"; mkdir -p "$ENABLE_CFG/rclone-onedrive-tray"
cat > "$ENABLE_CFG/rclone-onedrive-tray/config" <<EOF
REMOTE="r:x"
LOCAL="$WORK/enable-local"
UNIT_NAME="zz-enable-probe"
INTERVAL_MIN="5"
WATCH="0"
EOF
ENABLE_OUT="$(env PATH="$ENABLE_STUB:$STUB:$PATH" HOME="$HOME" \
    XDG_CONFIG_HOME="$ENABLE_CFG" XDG_CACHE_HOME="$WORK/enable-cache" \
    XDG_DATA_HOME="$WORK/enable-data" \
    bash "$SRC_DIR/install.sh" --prefix "$WORK/enable-prefix" --no-start 2>&1)"
check "a failed enable repeats systemctl's own reason" \
    grep -qF "Failed to enable unit: Unit file does not exist." <<<"$ENABLE_OUT"
check "and the command that repairs it follows the warning" \
    grep -qF "systemctl --user daemon-reload && systemctl --user enable --now zz-enable-probe.timer" \
    <<<"$ENABLE_OUT"

# ---------------------------------------------------------------- UNIT_NAME
# install.sh substitutes UNIT_NAME from the config into the NetworkManager
# dispatcher hook, which NetworkManager runs as root. The value used to go in
# through sed with no escaping and no validation: "$(touch ...)" was executed by
# the hook's own shell, "&" produced a hook that could never match a unit while
# the install still said a sync starts on connection, and "|" killed the run
# inside sed without ever naming UNIT_NAME. The config lives in a scratch
# XDG_CONFIG_HOME and the dispatcher directory in the scratch tree; the sudo stub
# only executes an install whose target is inside that tree.
NM_WORK="$WORK/nm-units"
NM_STUB="$NM_WORK/stubs"
rm -rf "$NM_WORK"; mkdir -p "$NM_WORK/dispatcher" "$NM_STUB"
cat > "$NM_STUB/sudo" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$NM_WORK/sudo-calls"
target="\${@: -1}"
case "\$1:\$target" in
    install:"$NM_WORK"/*) exec install -m 0755 "\${@: -2:1}" "\$target" ;;
esac
exit 1
EOF
chmod +x "$NM_STUB/sudo"

nm_install() {  # nm_install <tag> <unit-name> -- install.sh for that UNIT_NAME
    local tag="$1" name="$2" cfg
    cfg="$NM_WORK/$tag-cfg"
    rm -rf "$cfg" "$NM_WORK/dispatcher"; mkdir -p "$cfg/rclone-onedrive-tray" \
        "$NM_WORK/dispatcher" "$NM_WORK/tmp"
    cat > "$cfg/rclone-onedrive-tray/config" <<EOF
REMOTE="r:x"
LOCAL="$NM_WORK/local"
UNIT_NAME="$name"
INTERVAL_MIN="5"
WATCH="0"
EOF
    env PATH="$NM_STUB:$STUB:$PATH" HOME="$HOME" XDG_CONFIG_HOME="$cfg" \
        XDG_CACHE_HOME="$NM_WORK/cache" XDG_DATA_HOME="$NM_WORK/data" \
        TMPDIR="$NM_WORK/tmp" \
        NM_DISPATCHER_DIR="$NM_WORK/dispatcher" REAL_HOME_OVERRIDE="$HOME" \
    bash "$SRC_DIR/install.sh" --prefix "$NM_WORK/prefix" --no-start \
        --with-nm-dispatcher 2>&1
}

NM_SH_VALUE="zz\$(touch \${IFS}pwned)zz"
NM_SH_OUT="$(nm_install shellcmd "$NM_SH_VALUE")"; NM_SH_RC=$?
check "a UNIT_NAME holding a command substitution is refused" \
    test "$NM_SH_RC" -eq 1
check "and the refusal names the key, the value and the config file" \
    grep -qF "invalid UNIT_NAME in $NM_WORK/shellcmd-cfg/rclone-onedrive-tray/config: '$NM_SH_VALUE'" \
    <<<"$NM_SH_OUT"
if grep -rqF '$' "$NM_WORK/dispatcher" 2>/dev/null; then
    bad "a hook carrying a shell expansion was installed anyway"
else
    ok "and no hook carrying a shell expansion was installed"
fi

for bad_unit in 'zz&zz' 'zz|zz'; do
    NM_BAD_OUT="$(nm_install bad "$bad_unit")"
    if grep -qF "invalid UNIT_NAME in $NM_WORK/bad-cfg/rclone-onedrive-tray/config: '$bad_unit'" \
            <<<"$NM_BAD_OUT"; then
        ok "a UNIT_NAME holding '$bad_unit' is refused, naming the key and the value"
    else
        bad "a UNIT_NAME holding '$bad_unit' was not refused by name"
        printf '%s\n' "$NM_BAD_OUT" | head -3 | sed 's/^/        /'
    fi
done

# The readers here took everything up to the FIRST inner quote, so a value the
# tray wrote with an escaped quote came back truncated and nothing said so: the
# "Four parsers for one file format" entry. A name holding a quote is refused by
# the allow-list, and the refusal has to quote the whole value back. That is how
# this case sees the reader rather than assuming it.
NM_QUOTED='zz-quoted"unit'
NM_QUOTED_VALUE="zz-quoted\\\"unit"
NM_QUOTED_OUT="$(nm_install quoted "$NM_QUOTED_VALUE")"; NM_QUOTED_RC=$?
check "a UNIT_NAME with an escaped quote is refused as one value" \
    test "$NM_QUOTED_RC" -eq 1
check "and the refusal quotes the whole value, not the part before the quote" \
    grep -qF "invalid UNIT_NAME in $NM_WORK/quoted-cfg/rclone-onedrive-tray/config: '$NM_QUOTED'" \
    <<<"$NM_QUOTED_OUT"

# ---------------------------------------------------------------- extras/
# extras/install-issue-watch.sh generates its own unit with
# ExecStart=$BIN_DIR/watch-issues.sh, unquoted and unescaped. A prefix that needs
# quoting is then split on whitespace by systemd, and a prefix holding % or $ is
# read as a specifier or a variable reference. No suite ran extras/ at all, which
# is how that survived. systemd-analyze is not on every machine, so the check
# skips where it is absent instead of reporting a pass it did not earn.
title "extras/install-issue-watch.sh"
ISSUE_STUB="$WORK/issue-stubs"
rm -rf "$ISSUE_STUB"; mkdir -p "$ISSUE_STUB"
printf '#!/bin/bash\nexit 0\n' > "$ISSUE_STUB/systemctl"
chmod +x "$ISSUE_STUB/systemctl"

ISSUE_CFG="$WORK/issue-cfg"
ISSUE_PREFIX="$WORK/issue prefix/100%"
rm -rf "$ISSUE_CFG" "$ISSUE_PREFIX"; mkdir -p "$ISSUE_CFG"
env PATH="$ISSUE_STUB:$PATH" XDG_CONFIG_HOME="$ISSUE_CFG" HOME="$HOME" \
    bash "$SRC_DIR/extras/install-issue-watch.sh" --prefix "$ISSUE_PREFIX" \
    >/dev/null 2>&1
ISSUE_UNIT="$ISSUE_CFG/systemd/user/onedrive-issue-watch.service"
if command -v systemd-analyze >/dev/null 2>&1; then
    ISSUE_VERIFY="$(systemd-analyze verify "$ISSUE_UNIT" 2>&1)" || true
    if grep -qF 'is not executable' <<<"$ISSUE_VERIFY"; then
        bad "the generated ExecStart was split by systemd: $(grep -m1 -F 'is not executable' <<<"$ISSUE_VERIFY")"
    else
        ok "a prefix holding a space and a % still verifies as one ExecStart"
    fi
else
    skip "systemd-analyze is not installed; the generated unit was not verified"
fi

# systemd-analyze does not resolve $$, so the dollar rule is checked as text: the
# generated line has to carry $$ where the prefix carries one $.
ISSUE_DOLLAR_CFG="$WORK/issue-dollar-cfg"
ISSUE_DOLLAR_PREFIX="$WORK/issue \$cash"
rm -rf "$ISSUE_DOLLAR_CFG" "$ISSUE_DOLLAR_PREFIX"; mkdir -p "$ISSUE_DOLLAR_CFG"
env PATH="$ISSUE_STUB:$PATH" XDG_CONFIG_HOME="$ISSUE_DOLLAR_CFG" HOME="$HOME" \
    bash "$SRC_DIR/extras/install-issue-watch.sh" --prefix "$ISSUE_DOLLAR_PREFIX" \
    >/dev/null 2>&1
check "a literal \$ in the prefix reaches systemd as \$\$" \
    grep -qxF "ExecStart=\"$WORK/issue \$\$cash/bin/watch-issues.sh\"" \
    "$ISSUE_DOLLAR_CFG/systemd/user/onedrive-issue-watch.service"

# ---------------------------------------------------------------- the wizard
title "setup.sh"
build_reduced_path rclone
run "no rclone: the wizard says so first" 1 "rclone is not installed" \
    env -i PATH="$REDUCED" HOME="$HOME" XDG_CONFIG_HOME="$WORK/s1" \
        XDG_CACHE_HOME="$WORK/s1c" bash "$SRC_DIR/setup.sh" --yes --no-install

# With no remote and no terminal, the wizard used to start rclone's browser
# sign-in and block forever. --yes means "do not ask me", so it has to stop.
mkdir -p "$WORK/noremote"
printf '#!/bin/bash\nexit 0\n' > "$WORK/noremote/rclone"
chmod +x "$WORK/noremote/rclone"
run "no remote and no terminal: refuses instead of hanging" 1 "no rclone remote" \
    env -i PATH="$WORK/noremote:$REDUCED" HOME="$HOME" XDG_CONFIG_HOME="$WORK/s2" \
        XDG_CACHE_HOME="$WORK/s2c" bash "$SRC_DIR/setup.sh" --yes --no-install

# Values that reach a unit file or the timer template. A space or a slash in
# --unit-name produced a unit systemd refuses to load and install.sh then blamed
# the user manager; --interval abc was swallowed into a five minute timer in
# silence, and 0 was written into the template so the timer never fired. The
# check runs before anything is written, so the value is named and the run ends
# there.
for bad_unit in "bad name" "bad/name"; do
    run "--unit-name '$bad_unit' is refused, naming the value" 1 \
        "invalid --unit-name value: '$bad_unit'" \
        env -i PATH="$PATH" HOME="$WORK/s3h" XDG_CONFIG_HOME="$WORK/s3" \
            XDG_CACHE_HOME="$WORK/s3c" \
        bash "$SRC_DIR/setup.sh" --unit-name "$bad_unit" --yes --no-install
done
for bad_interval in abc 0; do
    run "--interval $bad_interval is refused, naming the value" 1 \
        "invalid --interval value: '$bad_interval'" \
        env -i PATH="$PATH" HOME="$WORK/s3h" XDG_CONFIG_HOME="$WORK/s3" \
            XDG_CACHE_HOME="$WORK/s3c" \
        bash "$SRC_DIR/setup.sh" --interval "$bad_interval" --yes --no-install
done

# exclude-folders.txt is read by onedrive-sync and by the tray's folder menu, and
# both drop a line starting with # and trim the line. A deselected folder named
# "#Archive" was therefore written as a comment: the folder kept syncing while
# the menu showed it as excluded. The tray refuses that name with an explanation
# (exclusion_problem); the wizard has to refuse it too, and say why, instead of
# writing a line neither reader can see.
SKIP_HOME="$WORK/skip-folders"
SKIP_CFG="$SKIP_HOME/cfg"
rm -rf "$SKIP_HOME"; mkdir -p "$SKIP_CFG" "$SKIP_HOME/bin"
cat > "$SKIP_HOME/bin/rclone" <<'EOF'
#!/bin/bash
[ "$1" = listremotes ] && echo "zz:"
exit 0
EOF
chmod +x "$SKIP_HOME/bin/rclone"
SKIP_OUT="$(env -i PATH="$SKIP_HOME/bin:$PATH" HOME="$SKIP_HOME" \
    XDG_CONFIG_HOME="$SKIP_CFG" XDG_CACHE_HOME="$SKIP_HOME/cache" \
    bash "$SRC_DIR/setup.sh" --remote zz: --local "$SKIP_HOME/local" \
    --skip-folders '#Archive,Notes' --yes --no-install 2>&1)"
SKIP_FILE="$SKIP_CFG/rclone-onedrive-tray/exclude-folders.txt"
if grep -qF 'Cannot leave #Archive out of the sync' <<<"$SKIP_OUT"; then
    ok "a folder name starting with # is refused, with an explanation"
else
    bad "a folder name starting with # was written without a warning"
    printf '%s\n' "$SKIP_OUT" | tail -3 | sed 's/^/        /'
fi
if [ -f "$SKIP_FILE" ] && grep -qE '^[[:space:]]*#' "$SKIP_FILE"; then
    bad "exclude-folders.txt holds a line both readers skip"
else
    ok "and no line both readers skip was written to exclude-folders.txt"
fi
check "and the name that can be expressed is still written" \
    grep -qxF 'Notes' "$SKIP_FILE"

# A flag whose value is missing used to reach bash's own ":?" and print a
# localized internal that names no flag ("setup.sh: line 77: 2: parameter null or
# not set"), while --skip-folders three lines below printed its intended
# sentence. An unknown option exited 1 where install.sh exits 2, so the same
# class of usage error had a different status depending on which installer ran.
for value_flag in --remote --local --interval; do
    run "$value_flag without a value names the flag" 1 "$value_flag needs a value" \
        env -i PATH="$PATH" HOME="$WORK/s4h" XDG_CONFIG_HOME="$WORK/s4" \
            XDG_CACHE_HOME="$WORK/s4c" \
        bash "$SRC_DIR/setup.sh" "$value_flag"
done
run "an unknown option exits 2, the same as install.sh" 2 "unknown option: --bogus" \
    env -i PATH="$PATH" HOME="$WORK/s4h" XDG_CONFIG_HOME="$WORK/s4" \
        XDG_CACHE_HOME="$WORK/s4c" \
    bash "$SRC_DIR/setup.sh" --bogus

# ---------------------------------------------------------------- summary
summary
