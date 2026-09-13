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
LOADER="$SRC_DIR/tests/lib/load_module.py"
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
run "loads when every binding is present" 0 "LOADED" \
    python3 "$LOADER" "$SRC_DIR/bin/onedrive-tray"
run "no PyGObject: exits and names python3-gi" 1 "PyGObject" \
    env PYTHONPATH="$SHIM" HIDE_MODULE=gi python3 "$LOADER" "$SRC_DIR/bin/onedrive-tray"
run "no Gtk typelib: exits and names GTK 3" 1 "GTK 3" \
    env PYTHONPATH="$SHIM" HIDE_TYPELIB=Gtk python3 "$LOADER" "$SRC_DIR/bin/onedrive-tray"
run "no AppIndicator typelib: exits and names AppIndicator" 1 "AppIndicator" \
    env PYTHONPATH="$SHIM" HIDE_TYPELIB=AyatanaAppIndicator3,AppIndicator3 \
    python3 "$LOADER" "$SRC_DIR/bin/onedrive-tray"
run "no pycairo: exits and names pycairo" 1 "pycairo" \
    env PYTHONPATH="$SHIM" HIDE_MODULE=cairo python3 "$LOADER" "$SRC_DIR/bin/onedrive-tray"
run "no Notify typelib: still loads, notifications off" 0 "LOADED" \
    env PYTHONPATH="$SHIM" HIDE_TYPELIB=Notify python3 "$LOADER" "$SRC_DIR/bin/onedrive-tray"
# GTK aborts with a core dump when there is no display, so the tray has to say
# what it is before it gets that far. Loading the module does not reach that
# code, which is deliberate: the dependency checks above have to keep working on
# a headless machine.
run "no display: exits and says it needs a session" 1 "graphical session" \
    env -u DISPLAY -u WAYLAND_DISPLAY python3 "$SRC_DIR/bin/onedrive-tray"
# A display has to be set to get past the guard above, but the lock is taken
# before GTK connects to it, so nothing here opens a window.
run "unusable TMPDIR: says so instead of already running" 1 "Could not create the lock file" \
    env DISPLAY=:0 TMPDIR="$WORK/does-not-exist" \
        python3 "$SRC_DIR/bin/onedrive-tray"

# The lock is a flock on the descriptor, but the file it lives in is visible in
# $TMPDIR and used to survive the process. An empty config directory gets the
# tray as far as the lock without ever touching GTK, so this needs no display.
LOCK_DIR="$WORK/tray-lock"; mkdir -p "$LOCK_DIR"
run "missing config: exits after taking the lock" 1 "Config not found" \
    env DISPLAY=:0 TMPDIR="$LOCK_DIR" XDG_CONFIG_HOME="$WORK/no-config" \
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
    python3 - "$SRC_DIR/bin/onedrive-tray" <<'PY'
import importlib.machinery
import importlib.util
import sys

sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("candidate", sys.argv[1])
spec = importlib.util.spec_from_loader("candidate", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


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
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
}

run "unit states: disabled and unknown are not 'paused'" 0 "" tray_unit_states

# OPEN_APP_CMD is written shell-style, so a quoted path has to be split the way
# a shell would. str.split() kept the quote characters and spawn() failed
# silently; a command that cannot be launched must be reported instead.
tray_open_app() {
    python3 - "$SRC_DIR/bin/onedrive-tray" <<'PY'
import importlib.machinery
import importlib.util
import sys

sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("candidate", sys.argv[1])
spec = importlib.util.spec_from_loader("candidate", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


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
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
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
run "no pycairo: refuses and names python3-cairo" 1 "python3-cairo" \
    env PYTHONPATH="$PYSHIM_DIR" HIDE_MODULE=cairo XDG_CONFIG_HOME="$WORK/i2" \
    bash "$SRC_DIR/install.sh" --prefix "$WORK/i2p" --no-start
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

# ---------------------------------------------------------------- summary
summary
