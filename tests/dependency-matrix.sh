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
printf '#!/bin/bash\n[ "$1" = version ] && echo "rclone v1.60.1"\nexit 0\n' \
    > "$WORK/oldrclone/rclone"
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

# ---------------------------------------------------------------- summary
summary
