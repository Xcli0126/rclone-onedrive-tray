#!/usr/bin/env bash
#
# tray.sh: drive the real GTK tray menu and assert on what it did.
#
# The tray is a GUI program, so the only honest way to test it is to build the
# real Gtk.Menu and activate the real handlers. That needs a display, and this
# suite must not touch the desktop session the machine is using: it starts GTK
# 3's own HTML5 backend, broadwayd, on a private XDG_RUNTIME_DIR, and points
# GDK_BACKEND at it. DISPLAY is set to a name that does not exist purely to
# satisfy the tray's own guard, which only asks whether the variable is set.
#
# Everything the tray shells out to (systemctl, systemd-run, rclone, xdg-open,
# onedrive-check, onedrive-sync) is a stub that records its argv, so the live
# user manager and the live rclone remote are never asked anything. Every
# observation is made by a small Python driver, which prints one JSON object per
# scenario; the shell asserts on that JSON. Run from anywhere:
#
#   tests/tray.sh              run everything
#   tests/tray.sh --verbose    also show each scenario's JSON
#
# Skip: without broadwayd (the libgtk-3-bin package) or the GTK 3 bindings there
# is no way to build a menu at all, so the suite reports that and exits 0, the
# way install-flow.sh skips systemd-analyze when it is missing.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SRC_DIR/tests/lib/harness.sh" "$@"

TRAY="$SRC_DIR/bin/onedrive-tray"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tray-test.XXXXXX")"
mkdir -p "$WORK/run" "$WORK/cache" "$WORK/config/rclone-onedrive-tray" \
         "$WORK/data" "$WORK/state" "$WORK/stubs" "$WORK/calls" "$WORK/local"
chmod 700 "$WORK/run"
DRIVER="$WORK/tray-drive.py"

BROADWAYD_PID=""
cleanup() {
    if [ -n "$BROADWAYD_PID" ]; then
        kill "$BROADWAYD_PID" 2>/dev/null
        wait "$BROADWAYD_PID" 2>/dev/null
    fi
    chmod 0755 "$WORK/config/rclone-onedrive-tray" 2>/dev/null
    chmod 0644 "$WORK/config/rclone-onedrive-tray/exclude-folders.txt" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- the display
if ! command -v broadwayd >/dev/null 2>&1; then
    skip "broadwayd is not installed (libgtk-3-bin); the tray menu cannot be built"
    summary
    exit 0
fi

# A port nobody is listening on, asked of the kernel rather than guessed: a
# fixed port would collide with another run of this suite, or with whatever else
# holds it, and the tray would then fail for the wrong reason.
PORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()' 2>/dev/null)"
[ -n "$PORT" ] || PORT="${TRAY_TEST_PORT:-8595}"

XDG_RUNTIME_DIR="$WORK/run" broadwayd -p "$PORT" :9 \
    >"$WORK/broadwayd.log" 2>&1 &
BROADWAYD_PID=$!

# ------------------------------------------------------------- the sandbox
cat > "$WORK/config/rclone-onedrive-tray/config" <<EOF
REMOTE="traytest-remote:"
LOCAL="$WORK/local"
UNIT_NAME="ztraytest"
LOG="$WORK/cache/sync.log"
UI_LANG="en"
OPEN_APP_CMD=""
OPEN_APP_NAME="the app"
EXCLUDE_FOLDERS_FILE="$WORK/config/rclone-onedrive-tray/exclude-folders.txt"
EOF

# One stub shape covers every scenario: it records its argv and answers from
# files under $WORK/calls, so a scenario is configured by dropping a file in
# rather than by rewriting the stub.
cat > "$WORK/stubs/rclone" <<STUB
#!/bin/sh
printf 'rclone %s\n' "\$*" >> "$WORK/calls/calls"
case "\$1" in
    about) [ -f "$WORK/calls/quota-json" ] && cat "$WORK/calls/quota-json" ;;
    lsf)   [ -f "$WORK/calls/folders" ] && cat "$WORK/calls/folders" ;;
esac
exit 0
STUB

cat > "$WORK/stubs/systemctl" <<STUB
#!/bin/sh
printf 'systemctl %s\n' "\$*" >> "$WORK/calls/calls"
for arg in "\$@"; do
    case "\$arg" in
        is-enabled)
            [ -f "$WORK/calls/notimer" ] && exit 1
            if [ -f "$WORK/calls/timer-disabled" ]; then
                printf 'disabled\n'
                exit 1
            fi
            printf 'enabled\n'
            exit 0
            ;;
        is-active) exit 3 ;;
    esac
done
exit 0
STUB

cat > "$WORK/stubs/systemd-run" <<STUB
#!/bin/sh
printf 'systemd-run %s\n' "\$*" >> "$WORK/calls/calls"
exit 0
STUB

cat > "$WORK/stubs/xdg-open" <<STUB
#!/bin/sh
printf 'xdg-open %s\n' "\$*" >> "$WORK/calls/calls"
exit 0
STUB

cat > "$WORK/stubs/onedrive-check" <<STUB
#!/bin/sh
printf 'onedrive-check %s\n' "\$*" >> "$WORK/calls/calls"
exit 0
STUB

cat > "$WORK/stubs/onedrive-sync" <<STUB
#!/bin/sh
printf 'onedrive-sync %s\n' "\$*" >> "$WORK/calls/calls"
exit 0
STUB

chmod +x "$WORK/stubs"/*

# ------------------------------------------------------------- the driver
cat > "$DRIVER" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Drive the tray's real Gtk.Menu on a private Broadway display.

Usage: tray-drive.py SCENARIO TRAY_PATH

The environment (GDK_BACKEND, BROADWAY_DISPLAY, XDG_*, a PATH holding the
stubs) is set up by tests/tray.sh. This script only builds the tray, drives it
through MenuItem.activate(), and prints one JSON object of observations on
stdout. Every pass/fail decision is made by the shell suite, which reads that
JSON, so the same measurement cannot be interpreted two different ways.
"""
import importlib.machinery
import importlib.util
import json
import os
import sys
import time

sys.dont_write_bytecode = True

RECORDS = os.environ["TRAY_RECORDS"]


def record(text):
    with open(RECORDS, "a", encoding="utf-8") as fh:
        fh.write(text + "\n")


def load_tray():
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk
    Gtk.init_check()
    path = sys.argv[2]
    loader = importlib.machinery.SourceFileLoader("tray_under_test", path)
    spec = importlib.util.spec_from_loader("tray_under_test", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


MODULE = load_tray()
from gi.repository import GLib  # noqa: E402

CFG = MODULE.load_config()


def pump(seconds):
    """Iterate the default main context for up to `seconds`."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        while GLib.MainContext.default().iteration(False):
            pass
        time.sleep(0.01)


def wait_for(predicate, seconds=8.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        pump(0.05)
    return bool(predicate())


def build():
    tray = MODULE.Tray(CFG)
    GLib.timeout_add(200, tray.poll)
    return tray


# --------------------------------------------------------------- menu walking
def walk(menu):
    """Every item in the menu tree, as path -> what it says and shows."""
    out = {}

    def visit(m, prefix):
        for i, item in enumerate(m.get_children()):
            path = "%s%d" % (prefix, i)
            out[path] = {"label": item.get_label() or "",
                         "visible": bool(item.get_visible()),
                         "sensitive": bool(item.get_sensitive())}
            sub = item.get_submenu()
            if sub is not None:
                visit(sub, path + ".")

    visit(menu, "menu/")
    return out


def visible_labels(menu):
    """Every label a user could read, in menu order, separators left out."""
    return [item["label"] for item in walk(menu).values()
            if item["visible"] and item["label"]]


def labels_from(menu):
    return {"menu_labels": visible_labels(menu)}


def item_labels(menu, index):
    """Labels of one item and everything under it, as a flat list."""
    items = walk(menu)
    prefix = "menu/%d" % index
    return [entry["label"] for path, entry in sorted(items.items())
            if (path == prefix or path.startswith(prefix + "."))
            and entry["label"]]


def find_at(menu, label):
    """The item labelled `label`, anywhere in the menu tree."""
    for item in menu.get_children():
        if (item.get_label() or "") == label:
            return item
        sub = item.get_submenu()
        if sub is not None:
            try:
                return find_at(sub, label)
            except SystemExit:
                pass
    raise SystemExit("no menu item labelled %r" % label)


def call_lines():
    try:
        with open(os.path.join(os.environ["TRAY_CALLS"], "calls"),
                  encoding="utf-8") as fh:
            return [line.rstrip("\n") for line in fh if line.strip()]
    except OSError:
        return []


def clear_calls():
    try:
        open(os.path.join(os.environ["TRAY_CALLS"], "calls"), "w").close()
    except OSError:
        pass


# ------------------------------------------------------------------ scenarios
def scenario_menus():
    """Every label in the asked-for language, with the menu fully built."""
    cfg = dict(CFG)
    cfg["UI_LANG"] = "zh" if os.environ.get("TRAY_LANG") == "zh" else "en"
    tray = MODULE.Tray(cfg)
    # Let polling settle, so the pause row shows an answer rather than the
    # placeholder the menu is born with. This waits on a clock instead of on
    # auto_seen, because a tray that predates that attribute has neither.
    pump(2.5)
    tray.folders = ["Docs", "Music", ".config"]
    # Only a tray that tracks what the listing already showed can be told not to
    # rebuild it; without that the poll may replace the submenu right away, and
    # the assertions below read the current menu rather than a stale handle.
    if hasattr(tray, "folders_seen"):
        tray.folders_seen = tray.folders
    tray._build_folder_menu()
    pump(0.3)
    data = labels_from(tray.menu)
    data["status"] = item_labels(tray.menu, 0)[0]
    data["quota_label"] = tray.item_quota.get_label() or ""
    data["quota_visible"] = bool(tray.item_quota.get_visible())
    data["pause_label"] = tray.item_pause.get_label() or ""
    data["lang"] = cfg["UI_LANG"]
    return data


def scenario_quota():
    """The quota row: hidden with nothing to say, one usage line when there is."""
    tray = MODULE.Tray(CFG)
    # An older tray has no quota attribute until its worker returns, so only
    # wait on it when it does exist; otherwise the pump below is the wait.
    if hasattr(tray, "quota"):
        wait_for(lambda: tray.quota is not None, 8.0)
    pump(1.0)
    data = labels_from(tray.menu)
    data["quota_visible"] = bool(tray.item_quota.get_visible())
    data["quota_height"] = tray.item_quota.get_preferred_height()[1]
    data["quota_label"] = tray.item_quota.get_label() or ""
    data["quota_seen"] = bool(getattr(tray, "quota", None))
    data["quota_unreadable"] = not hasattr(tray, "quota")
    return data


def scenario_sync():
    """Sync now must start the configured service."""
    tray = build()
    clear_calls()
    find_at(tray.menu, "Sync now").activate()
    called = wait_for(lambda: any("systemctl --user start" in line
                                  for line in call_lines()), 8.0)
    pump(0.3)
    data = labels_from(tray.menu)
    data["sync_called"] = called
    data["calls"] = call_lines()
    return data


def scenario_pause_durations():
    """Each pause duration schedules the resume timer systemd-run should get."""
    tray = build()
    clear_calls()
    data = {}
    for minutes, label in ((30, "30 minutes"), (120, "2 hours"),
                           (480, "8 hours")):
        find_at(tray.menu, label).activate()
        data["pause_%d" % minutes] = wait_for(
            lambda m=minutes: any("systemd-run --user --on-active=%dmin" % m
                                  in line for line in call_lines()), 8.0)
    data["stamp_was_written"] = os.path.exists(MODULE.PAUSE_STAMP)
    find_at(tray.menu, "Resume now").activate()
    data["resumed"] = wait_for(
        lambda: any("enable --now" in line for line in call_lines()), 8.0)
    pump(0.5)
    data["stamp_cleared"] = not os.path.exists(MODULE.PAUSE_STAMP)
    data.update(labels_from(tray.menu))
    data["pause_label"] = tray.item_pause.get_label() or ""
    data["calls"] = call_lines()
    return data


def scenario_timer_state():
    """A timer that is disabled, or cannot be asked, is not a pause."""
    tray = build()
    clear_calls()
    expected = os.environ.get("TRAY_EXPECT_AUTO", "")
    wait_for(lambda: getattr(tray, "auto_seen", None) == expected, 8.0)
    pump(0.5)
    data = labels_from(tray.menu)
    data["auto_seen"] = getattr(tray, "auto_seen", None)
    data["pause_label"] = tray.item_pause.get_label() or ""
    data["status"] = tray.item_status.get_label() or ""
    return data


def scenario_folders():
    """Unticking a folder rewrites the list; a failed write changes nothing."""
    tray = MODULE.Tray(CFG)
    # The listing normally arrives from rclone; stamp it in so the submenu is
    # built from a known set of folders rather than from the stub's output.
    tray.folders = ["Docs", "Music", ".config"]
    tray.folders_seen = tray.folders
    tray._build_folder_menu()
    pump(0.3)
    # Re-read the submenu each time: the tray rebuilds it whenever the listing
    # changes, so a handle taken before that would drive a detached menu.
    find_at(tray.menu, "Music").set_active(False)
    written = wait_for(lambda: "Music" in MODULE.read_excluded_folders(
        tray.exclude_file), 8.0)
    data = {"unchecked_written": written,
            "excluded_after_uncheck":
                MODULE.read_excluded_folders(tray.exclude_file),
            "music_stayed_unchecked":
                not find_at(tray.menu, "Music").get_active()}
    # Now make the write fail. The file is made read-only rather than its
    # directory, because a 0500 directory still lets a writable file inside it
    # be truncated. The tick has to go back where it was, so the menu and
    # exclude-folders.txt cannot disagree.
    os.chmod(tray.exclude_file, 0o400)
    try:
        find_at(tray.menu, "Docs").set_active(False)
        pump(0.5)
        data["reverted"] = bool(find_at(tray.menu, "Docs").get_active())
        data["excluded_after_failure"] = MODULE.read_excluded_folders(
            tray.exclude_file)
    finally:
        os.chmod(tray.exclude_file, 0o644)
    data["check_states"] = {name: bool(find_at(tray.menu, name).get_active())
                            for name in ("Docs", "Music")}
    data.update(labels_from(tray.menu))
    return data


def scenario_openapp():
    """A quoted OPEN_APP_CMD is split the way a shell would split it."""
    tray = build()
    record_path = os.path.join(os.environ["TRAY_CALLS"], "openapp")
    try:
        os.remove(record_path)
    except OSError:
        pass
    find_at(tray.menu, "Open %s" % tray.open_name).activate()
    ran = wait_for(lambda: os.path.exists(record_path), 8.0)
    pump(0.3)
    argv = []
    if ran:
        with open(record_path, encoding="utf-8") as fh:
            argv = [line.rstrip("\n") for line in fh]
    return {"openapp_ran": ran, "openapp_argv": argv,
            "open_cmd": tray.open_cmd}


def scenario_lock_hold():
    """Take the single-instance lock and hold it for the second process."""
    lock = MODULE.acquire_lock()
    if lock is None:
        return {"lock_acquired": False}
    record("held %d" % os.getpid())
    time.sleep(float(os.environ.get("TRAY_HOLD", "3.0")))
    # release_lock() took the lock handle only after the defect that left the
    # file behind was fixed; an older tray closes it itself.
    try:
        MODULE.release_lock(lock)
    except TypeError:
        lock.close()
    return {"lock_acquired": True,
            "lock_removed": not os.path.exists(MODULE.LOCK_FILE)}


def scenario_lock_second():
    """Run the real main() while another process holds the lock."""
    import runpy
    saved = sys.argv
    sys.argv = [saved[2]]
    try:
        runpy.run_path(saved[2], run_name="__main__")
    except SystemExit as exc:
        return {"exit_code": exc.code}
    finally:
        sys.argv = saved
    return {"exit_code": 0}


SCENARIOS = {
    "menus": scenario_menus,
    "quota": scenario_quota,
    "sync": scenario_sync,
    "pause-durations": scenario_pause_durations,
    "timer-state": scenario_timer_state,
    "folders": scenario_folders,
    "openapp": scenario_openapp,
    "lock-hold": scenario_lock_hold,
    "lock-second": scenario_lock_second,
}


def main():
    name = sys.argv[1]
    if name not in SCENARIOS:
        raise SystemExit("unknown scenario %r" % name)
    print(json.dumps(SCENARIOS[name](), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF

# ------------------------------------------------------------- running it
LAST_JSON="$WORK/last.json"
DRIVER_ERR="$WORK/driver.err"
DRIVER_ALLERR="$WORK/driver-all.err"

# driver SCENARIO [VAR=VALUE...]
#
# The tray's own chatter (GTK warnings from a display with no StatusNotifier
# host, for one) is noise the assertions do not want. run_driver folds it into
# DRIVER_ERR; driver_both leaves stderr alone, because the second instance of
# the tray writes its refusal there and the harness's run() only reads stdout.
driver_quiet() {
    local name="$1"; shift
    env -i PATH="$WORK/stubs:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK/cache" \
        XDG_RUNTIME_DIR="$WORK/run" \
        XDG_CONFIG_HOME="$WORK/config" XDG_CACHE_HOME="$WORK/cache" \
        XDG_DATA_HOME="$WORK/data" XDG_STATE_HOME="$WORK/state" \
        GDK_BACKEND=broadway BROADWAY_DISPLAY=:9 DISPLAY=:77 \
        LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        TRAY_RECORDS="$WORK/records" TRAY_CALLS="$WORK/calls" \
        "$@" \
        python3 "$DRIVER" "$name" "$TRAY" 2>"$DRIVER_ERR"
}

driver_both() {
    local name="$1"; shift
    env -i PATH="$WORK/stubs:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK/cache" \
        XDG_RUNTIME_DIR="$WORK/run" \
        XDG_CONFIG_HOME="$WORK/config" XDG_CACHE_HOME="$WORK/cache" \
        XDG_DATA_HOME="$WORK/data" XDG_STATE_HOME="$WORK/state" \
        GDK_BACKEND=broadway BROADWAY_DISPLAY=:9 DISPLAY=:77 \
        LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        TRAY_RECORDS="$WORK/records" TRAY_CALLS="$WORK/calls" \
        "$@" \
        python3 "$DRIVER" "$name" "$TRAY"
}

# run_driver SCENARIO [VAR=VALUE...] -- the whole output becomes LAST_JSON, and
# a scenario that cannot even build the tray is a failure, not a crash.
run_driver() {
    local out rc
    out="$(driver_quiet "$@")"; rc=$?
    printf '%s' "$out" > "$LAST_JSON"
    if [ "$VERBOSE" = 1 ]; then
        printf '        $ tray-drive.py %s\n' "$*"
        printf '%s\n' "$out" | head -5 | cut -c1-400 | sed 's/^/        | /'
    fi
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        bad "the tray could not be driven for '$1' (exit $rc)"
        cat "$DRIVER_ERR" >> "$DRIVER_ALLERR"
        grep -v -e WARNING -e '^$' "$DRIVER_ERR" | head -4 | sed 's/^/        /'
        return 1
    fi
    return 0
}

# json_py SNIPPET -- run a snippet over LAST_JSON, where `d` is the parsed
# object. Anything the snippet prints becomes the failure detail.
json_py() {
    python3 - "$LAST_JSON" "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
exec(sys.argv[2])
PY
}

# json_expr EXPRESSION -- the same, for one-liners. Exits non-zero, with the
# expression and the data on stdout, when the expression is false.
json_expr() {
    python3 - "$LAST_JSON" "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
if not eval(sys.argv[2]):          # noqa: S307 - the suite's own expression
    print("expression false: %s" % sys.argv[2])
    print("data: %s" % json.dumps(d, ensure_ascii=False)[:600])
    raise SystemExit(1)
PY
}

# gtk_probe -- is there a GTK that can initialise against this broadwayd? A
# machine can have broadwayd but no python3-gi, and the messages are the same
# either way: no menu can be built here.
gtk_probe() {
    env -i PATH="$WORK/stubs:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK/cache" \
        XDG_RUNTIME_DIR="$WORK/run" \
        GDK_BACKEND=broadway BROADWAY_DISPLAY=:9 DISPLAY=:77 \
        LANG=C.UTF-8 python3 -c '
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk
ok, _ = Gtk.init_check()
raise SystemExit(0 if ok else 1)
' 2>"$WORK/driver.err"
}

if ! gtk_probe; then
    skip "broadwayd did not come up on the private display (port ${PORT:-?}); GTK 3 cannot be initialised here"
    summary
    exit 0
fi

title "Menu construction and translation"
if run_driver menus TRAY_LANG=en; then
    check "no label is a bare translation key" json_py '
import re
raw = re.compile(r"^[a-z][a-z0-9]*(_[a-z0-9]+)+$")
bad = [x for x in d["menu_labels"] + [d["status"], d["quota_label"]] if raw.match(x)]
for name in ("dlg_resync_body", "lcl_deselected_body", "dlg_resync_title"):
    if name in d["menu_labels"]:
        bad.append(name)
if bad:
    print("labels that look like translation keys: %r" % bad)
    raise SystemExit(1)
'
    check "no label is empty or duplicated" json_py '
labels = [x for x in d["menu_labels"] if x]
if len(labels) != len(set(labels)):
    print("duplicate labels: %r" % labels)
    raise SystemExit(1)
'
    check "the English menu has the expected labels" \
        json_expr "all(x in d['menu_labels'] for x in ['Sync now', 'Open sync folder', 'View sync log', 'Folders to sync', 'Pause automatic sync', 'Start tray at login', 'Check file names', 'Rebuild sync baseline (resync)…', 'Quit', 'Docs', 'Music', '.config', '30 minutes', '2 hours', '8 hours', 'Resume now'])"
    check "the English menu contains no Chinese" json_py '
if any(any("\u4e00" <= c <= "\u9fff" for c in x) for x in d["menu_labels"]):
    print("Chinese label under UI_LANG=en: %r" % d["menu_labels"])
    raise SystemExit(1)
'
fi

if run_driver menus TRAY_LANG=zh; then
    check "the Chinese menu has the expected labels" \
        json_expr "all(x in d['menu_labels'] for x in ['立即同步', '打开同步文件夹', '查看同步日志', '同步的文件夹', '暂停自动同步', '开机自动启动图标', '检查文件名', '退出', '30 分钟', '2 小时', '8 小时', '立即恢复'])"
    check "no Chinese label is left in English" json_py '
left = [x for x in d["menu_labels"]
        if x in ("Sync now", "View sync log", "Quit", "Resume now")]
if left:
    print("untranslated under UI_LANG=zh: %r" % left)
    raise SystemExit(1)
'
    check "folder names keep their own spelling under UI_LANG=zh" \
        json_expr "all(x in d['menu_labels'] for x in ['Docs', 'Music', '.config'])"
    check "the status line is translated too" json_py '
if d["status"] in ("Reading status…", "No sync recorded yet"):
    print("status stayed English: %r" % d["status"])
    raise SystemExit(1)
'
fi

title "The quota row"
if run_driver quota; then
    check "with no quota reply the row is hidden" \
        json_expr "not d['quota_visible'] and not d['quota_seen']"
    check "with no quota reply the row has no height" \
        json_expr "d['quota_height'] == 0"
    check "with no quota reply the row says nothing" \
        json_expr "not d['quota_label']"
fi

printf '%s\n' '{"total": 1000000000000, "used": 250000000000}' \
    > "$WORK/calls/quota-json"
if run_driver quota; then
    check "a stubbed rclone about reply fills the row" \
        json_expr "d['quota_visible'] and d['quota_seen'] and d['quota_height'] > 0"
    check "the row shows the usage line" \
        json_expr "d['quota_label'] == '232.8 GiB of 931.3 GiB used (25%)'"
fi

title "Sync now"
if run_driver sync; then
    check "activating Sync now records a start of the configured service" \
        json_expr "any(x == 'systemctl --user start ztraytest.service' for x in d['calls'])"
fi

title "Pausing for a while"
if run_driver pause-durations; then
    check "30 minutes schedules a 30min resume" \
        json_expr "d['pause_30'] and any('systemd-run --user --on-active=30min --unit=rclone-onedrive-tray-resume systemctl --user enable --now ztraytest.timer ztraytest-watch.service' in x for x in d['calls'])"
    check "2 hours schedules a 120min resume" \
        json_expr "d['pause_120'] and any('--on-active=120min' in x for x in d['calls'])"
    check "8 hours schedules a 480min resume" \
        json_expr "d['pause_480'] and any('--on-active=480min' in x for x in d['calls'])"
    check "pausing stops the timer and the watcher" \
        json_expr "any('disable ztraytest.timer ztraytest-watch.service' in x for x in d['calls'])"
    check "pausing writes the resume stamp" \
        json_expr "d['stamp_was_written']"
    check "Resume now stops the transient unit" \
        json_expr "d['resumed'] and any('stop rclone-onedrive-tray-resume.timer rclone-onedrive-tray-resume.service' in x for x in d['calls'])"
    check "Resume now enables the timer and the watcher" \
        json_expr "any(x == 'systemctl --user enable --now ztraytest.timer' for x in d['calls']) and any(x == 'systemctl --user enable --now ztraytest-watch.service' for x in d['calls'])"
    check "Resume now clears the stamp" \
        json_expr "d['stamp_cleared']"
    check "the resume menu entry is the one that was activated" \
        json_expr "'Resume now' in d['menu_labels']"
fi

title "A disabled timer is not a pause"
printf 'Docs/\nMusic/\n' > "$WORK/calls/folders"
printf 'x\n' > "$WORK/calls/timer-disabled"
if run_driver timer-state TRAY_EXPECT_AUTO=off; then
    check "systemctl answering disabled is not reported as a pause" json_py '
claims = [x for x in d["menu_labels"] + [d["status"], d["pause_label"]]
          if "paused" in x.lower() or "暂停" in x]
if claims:
    print("a pause was claimed: %r" % claims)
    raise SystemExit(1)
'
    check "the state the tray reports is one it can name" json_expr "d['auto_seen'] in ('off', 'unknown')"
fi

rm -f "$WORK/calls/timer-disabled"
printf 'x\n' > "$WORK/calls/notimer"
if run_driver timer-state TRAY_EXPECT_AUTO=unknown; then
    check "systemctl answering nothing is not reported as a pause" json_py '
claims = [x for x in d["menu_labels"] + [d["status"], d["pause_label"]]
          if "paused" in x.lower() or "暂停" in x]
if claims:
    print("a pause was claimed: %r" % claims)
    raise SystemExit(1)
'
    check "an unreadable state is named as unreadable" \
        json_expr "d['auto_seen'] == 'unknown'"
fi
rm -f "$WORK/calls/notimer"

title "Folders to sync"
if run_driver folders; then
    check "unticking a folder writes it to exclude-folders.txt" \
        json_expr "d['unchecked_written'] and d['excluded_after_uncheck'] == ['Music'] and d['music_stayed_unchecked']"
    check "a failed write puts the tick back" \
        json_expr "d['reverted']"
    check "the menu and the file still agree after a failed write" \
        json_expr "d['excluded_after_failure'] == ['Music'] and d['check_states']['Docs'] and not d['check_states']['Music']"
fi

title "A quoted OPEN_APP_CMD"
cat > "$WORK/stubs/probing-stub" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$WORK/calls/openapp"
STUB
chmod +x "$WORK/stubs/probing-stub"
python3 - "$WORK" <<'PY'
import sys
work = sys.argv[1]
path = work + "/config/rclone-onedrive-tray/config"
with open(path, encoding="utf-8") as fh:
    text = fh.read()
# The command holds a quoted argument, which is the case that used to be split
# on whitespace and passed through with its quotes intact. Single quotes are
# used so that no backslash survives into the config file.
value = "%s/stubs/probing-stub 'probe arg' --flag" % work
text = text.replace('OPEN_APP_CMD=""', 'OPEN_APP_CMD="%s"' % value)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PY
if run_driver openapp; then
    check "the quoted command runs as three arguments" \
        json_expr "d['openapp_ran'] and d['openapp_argv'] == ['probe arg', '--flag']"
    check "the quote characters reach nothing" \
        json_expr "not any('\"' in x for x in d['openapp_argv'])"
fi
python3 - "$WORK" <<'PY'
import sys
work = sys.argv[1]
path = work + "/config/rclone-onedrive-tray/config"
with open(path, encoding="utf-8") as fh:
    text = fh.read()
start = text.index('OPEN_APP_CMD=')
end = text.index('\n', start)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text[:start] + 'OPEN_APP_CMD=""' + text[end:])
PY

title "The single-instance lock"
: > "$WORK/records"
# The holder sleeps well past the second start's own startup cost, so the lock
# is still held whatever this machine's process launch time happens to be.
driver_quiet lock-hold TRAY_HOLD=15 >/dev/null 2>&1 &
HOLDER=$!
for _ in $(seq 1 40); do
    [ -s "$WORK/records" ] && break
    sleep 0.1
done
if [ -s "$WORK/records" ]; then
    run "a second start prints the documented message and exits 0" \
        0 "rclone-onedrive-tray is already running." \
        driver_both lock-second
    wait "$HOLDER" 2>/dev/null
    check_absent "the lock file does not outlive the process that held it" \
        "$WORK/cache/rclone-onedrive-tray.lock"
else
    bad "the first process never took the lock"
    kill "$HOLDER" 2>/dev/null
    wait "$HOLDER" 2>/dev/null
fi

summary