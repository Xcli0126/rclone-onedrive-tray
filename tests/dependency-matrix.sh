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
mkdir -p "$WORK/oldbin"
printf '#!/bin/bash\necho "Error: unknown flag: --resilient" >&2\nexit 1\n' \
    > "$WORK/oldbin/rclone"
chmod +x "$WORK/oldbin/rclone"
run "rclone too old for the flags: names the version problem" 1 "rclone >= 1.65" \
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
# inotifywait records the command line it was given before failing. The watcher
# answers a failing inotifywait by retrying, so each run is cut short with
# timeout and its exit status deliberately ignored; the debounce line is printed
# before the loop is entered, and the recorded call is what the second case
# reads.
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
# icon out.
run "no pycairo: installs the sync half and names python3-cairo" 0 "python3-cairo" \
    env PYTHONPATH="$PYSHIM_DIR" HIDE_MODULE=cairo XDG_CONFIG_HOME="$WORK/i2" \
        XDG_CACHE_HOME="$WORK/i2c" XDG_DATA_HOME="$WORK/i2d" \
    bash "$SRC_DIR/install.sh" --prefix "$WORK/i2p" --no-start
check "and the wrapper is installed anyway" \
    test -x "$WORK/i2p/bin/onedrive-sync"
check "and no autostart entry is offered for a tray that cannot run" \
    test ! -e "$WORK/i2/.config/autostart/rclone-onedrive-tray.desktop"
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

# ---------------------------------------------------------------- summary
summary
