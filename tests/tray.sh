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
# A user manager that refuses: the settings dialog has to report this rather
# than close over it.
if [ -f "$WORK/calls/systemctl-fail" ]; then
    printf 'mock systemctl failure\n' >&2
    exit 1
fi
# enable --now clears the disabled state, the way the real user manager would,
# so a scenario that turns the units back on is answered truthfully afterwards.
case " \$* " in
    *" enable --now "*) rm -f "$WORK/calls/timer-disabled" ;;
esac
# The transient resume timer a pause arms. Whether it survived is what decides
# if the pause still has anything that will end it, so one file makes it answer
# "active" and its absence makes it answer the way a missing unit does.
if [ "\$1 \$2 \$3" = "--user is-active rclone-onedrive-tray-resume.timer" ]; then
    [ -f "$WORK/calls/pause-timer-active" ] && { printf 'active\n'; exit 0; }
    exit 3
fi
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
# A resume that cannot be scheduled is a pause nothing will end; the tray has to
# end it rather than leave the units disabled behind a promise.
if [ -f "$WORK/calls/systemd-run-fail" ]; then
    printf 'mock systemd-run failure\n' >&2
    exit 1
fi
exit 0
STUB

# These three only have to record that they were asked and with what.
for name in xdg-open onedrive-check onedrive-sync; do
cat > "$WORK/stubs/$name" <<STUB
#!/bin/sh
printf '$name %s\n' "\$*" >> "$WORK/calls/calls"
exit 0
STUB
done

# The re-authorise item opens a terminal when the desktop has one, and this
# machine does (ptyxis, xdg-terminal-exec). Stub them so the suite records the
# command instead of putting a window on somebody's screen.
for term in xdg-terminal-exec ptyxis gnome-terminal konsole xfce4-terminal xterm; do
cat > "$WORK/stubs/$term" <<STUB
#!/bin/sh
printf 'terminal %s\n' "\$*" >> "$WORK/calls/calls"
exit 0
STUB
done

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
import shutil
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
    # The bindings are imported on demand from load_bindings() rather than at the
    # top of the module, so the driver asks for them the way main() does. An
    # older tray had them already, and simply has no such function.
    getattr(module, "load_bindings", lambda: None)()
    return module


MODULE = load_tray()
from gi.repository import GLib, Gtk  # noqa: E402

CFG = MODULE.load_config()
WORK = os.path.dirname(os.environ["TRAY_CALLS"])


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


def read_text(path):
    """A file's text, or "" when it is not there."""
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def line_of(text, key):
    """The line index of KEY=..., or -1. Used to prove a rewrite stayed put."""
    for index, line in enumerate(text.splitlines()):
        if line.startswith(key + "="):
            return index
    return -1


def widget_texts(widget):
    """Every distinct button and label text under `widget`, in tree order."""
    found = []

    def visit(node):
        # A Gtk.Button carries a label of its own and holds a Gtk.Label saying
        # the same thing, so the raw walk sees each of them twice.
        if isinstance(node, Gtk.Button):
            found.append(node.get_label() or "")
        elif isinstance(node, Gtk.Label):
            found.append(node.get_text() or "")
        if isinstance(node, Gtk.Container):
            for child in node.get_children():
                visit(child)

    visit(widget)
    seen = set()
    unique = []
    for text in found:
        if text and text not in seen:
            seen.add(text)
            unique.append(text)
    return unique


def combo_texts(combo):
    """The visible items of a ComboBoxText, in order.

    Read by selecting each row and asking what is shown: the model behind a
    ComboBoxText has an id column as well, and which column is the text is not
    something to assume.
    """
    saved = combo.get_active()
    texts = []
    for index in range(len(combo.get_model())):
        combo.set_active(index)
        texts.append(combo.get_active_text() or "")
    combo.set_active(saved)
    return texts


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
    header = tray.menu.get_children()[0]
    data["header_label"] = header.get_label() or ""
    data["header_sensitive"] = bool(header.get_sensitive())
    data["header_is_first"] = bool(data["menu_labels"]) and \
        data["menu_labels"][0] == data["header_label"]
    data["status"] = tray.item_status.get_label() or ""
    data["quota_label"] = tray.item_quota.get_label() or ""
    data["quota_visible"] = bool(tray.item_quota.get_visible())
    data["pause_label"] = tray.item_pause.get_label() or ""
    data["version"] = MODULE.VERSION
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


def scenario_folder_delete():
    """A local delete is only ever offered for one ordinary component.

    The fixture is the one the guard has to survive: a folder that may go, a
    real directory outside LOCAL, a symlink inside LOCAL pointing at it, a
    symlink inside LOCAL pointing back at LOCAL itself, and a nested path that
    is reachable only through two components. The confirmation is faked as
    accepted so that confirming is not what is under test, and every refused
    name has to leave the tree outside LOCAL exactly as it was.
    """
    tray = build()
    local = tray.local
    outside = os.path.join(WORK, "outside")
    ordinary = os.path.join(local, "ordinary")
    nested = os.path.join(local, "a", "b")
    link = os.path.join(local, "link-to-outside")
    selflink = os.path.join(local, "self-link")
    # A sibling directory whose name merely starts with the root's name. Without
    # the trailing separator on the prefix check this one passes for "inside the
    # root", and a symlink to it would hand the whole directory to rmtree.
    sibling = local + "-old"
    oldlink = os.path.join(local, "link-to-sibling")

    os.makedirs(os.path.join(ordinary, "sub"), exist_ok=True)
    with open(os.path.join(ordinary, "sub", "inner.txt"), "w",
              encoding="utf-8") as fh:
        fh.write("inner\n")
    os.makedirs(nested, exist_ok=True)
    with open(os.path.join(nested, "kept.txt"), "w", encoding="utf-8") as fh:
        fh.write("kept\n")
    os.makedirs(outside, exist_ok=True)
    with open(os.path.join(outside, "precious.txt"), "w",
              encoding="utf-8") as fh:
        fh.write("keep me\n")
    os.makedirs(sibling, exist_ok=True)
    with open(os.path.join(sibling, "older.txt"), "w",
              encoding="utf-8") as fh:
        fh.write("still synced elsewhere\n")
    for path, destination in ((link, outside), (selflink, local),
                              (oldlink, sibling)):
        if os.path.lexists(path):
            os.remove(path)
        os.symlink(destination, path)

    asked = []

    class FakeDialog:
        def __init__(self, *a, **k):
            asked.append(k.get("text", ""))

        def format_secondary_text(self, text):
            pass

        def add_button(self, label, response):
            pass

        def run(self):
            return MODULE.Gtk.ResponseType.OK

        def destroy(self):
            pass

    real = MODULE.Gtk.MessageDialog
    MODULE.Gtk.MessageDialog = FakeDialog
    try:
        # The offer only stands on an exclusion that really took effect, and
        # unticking a folder is the only way the handler ever reaches it. The
        # names refused below are still refused by the path guard first, which is
        # the guard this scenario is about.
        MODULE.write_excluded_folders(tray.exclude_file, ["ordinary"])
        del asked[:]
        tray._offer_local_delete("ordinary")
        data = {"ordinary_asked": len(asked),
                "ordinary_title": asked[0] if asked else ""}
        data["ordinary_gone"] = wait_for(
            lambda: not os.path.exists(ordinary), 8.0)

        data["asked"] = {}
        for name in ("../outside", "a/b", "..", ".", "", "link-to-outside",
                     "self-link"):
            del asked[:]
            tray._offer_local_delete(name)
            pump(0.3)
            data["asked"][name] = len(asked)

        # The prefix check needs a name that passes the exclusion gate, or that
        # gate refuses it first and the assertion below proves nothing. This is
        # the one case here where the name is genuinely on the exclusion list and
        # only the path guard stands between it and rmtree.
        MODULE.write_excluded_folders(tray.exclude_file,
                                      ["ordinary", "link-to-sibling"])
        del asked[:]
        tray._offer_local_delete("link-to-sibling")
        pump(0.3)
        data["asked"]["link-to-sibling"] = len(asked)

        data["nested_intact"] = os.path.isfile(
            os.path.join(nested, "kept.txt"))
        data["outside_kept"] = os.path.isdir(outside)
        data["outside_files"] = sorted(os.listdir(outside))
        data["link_intact"] = (os.path.islink(link)
                               and os.path.realpath(link) == os.path.realpath(outside))
        data["sibling_kept"] = os.path.isdir(sibling)
        data["sibling_files"] = sorted(os.listdir(sibling))
        data["local_listing"] = sorted(os.listdir(local))
    finally:
        MODULE.Gtk.MessageDialog = real
    pump(0.3)
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


def fake_message_dialog(store, response):
    """A drop-in for Gtk.MessageDialog that records what a handler put in it.

    The tray's confirmation and information windows are built, written to and
    run, and that is all the assertions here need to see: replacing the class
    keeps the handler's own code on the path under test, where rebuilding the
    window afterwards would only test the reconstruction. `store` collects the
    title, the secondary text and the button labels; `response` is what run()
    answers with.
    """

    class FakeDialog:
        def __init__(self, *a, **k):
            store["text"] = k.get("text", "")
            store["buttons"] = []

        def format_secondary_text(self, text):
            store["body"] = text

        def add_button(self, label, response):
            store["buttons"].append(label)

        def run(self):
            return response

        def destroy(self):
            pass

    return FakeDialog


def scenario_reauth():
    """The re-authorise item must run rclone's sign-in for the right remote.

    The handler asks for confirmation first, so Gtk.MessageDialog is replaced by
    something that answers yes; the rest of the path is untouched.
    """
    tray = build()
    clear_calls()
    asked = {}

    real = MODULE.Gtk.MessageDialog
    MODULE.Gtk.MessageDialog = fake_message_dialog(
        asked, MODULE.Gtk.ResponseType.OK)
    try:
        find_at(tray.menu, "Re-authorise OneDrive…").activate()
        asked["reconnect"] = wait_for(
            lambda: any("config reconnect" in line for line in call_lines()), 8.0)
        asked["started"] = wait_for(
            lambda: any("start --no-block ztraytest.service" in line
                        for line in call_lines()), 8.0)
    finally:
        MODULE.Gtk.MessageDialog = real
    pump(0.3)
    asked.update(labels_from(tray.menu))
    asked["calls"] = call_lines()
    return asked


# ---------------------------------------------------------------- settings
def scenario_settings_view():
    """What the settings window opens with, before anything is touched."""
    tray = MODULE.Tray(CFG)
    pump(0.3)
    dialog = MODULE.SettingsDialog(tray)
    dialog.show_all()
    pump(0.3)
    data = {
        "title": dialog.get_title(),
        "config_file": MODULE.CONFIG_FILE,
        "config_line": dialog.label_config.get_text(),
        "values": dialog.values(),
        "original": dialog.original,
        "labels": widget_texts(dialog.get_content_area()) + [
            dialog.save_button.get_label(), dialog.cancel_button.get_label()],
        "lang_choices": combo_texts(dialog.combo_lang),
        "bw_choices": combo_texts(dialog.combo_bw),
        "notice_visible": bool(dialog.label_notice.get_visible()),
        "status_visible": bool(dialog.label_status.get_visible()),
        "boot": bool(dialog.check_boot.get_active()),
    }
    dialog.destroy()
    return data


def scenario_settings_markers():
    """The marker button runs onedrive-check-access, and reports what came back.

    CHECK_ACCESS off means rclone's --check-access is off, so switching it on in
    the window has to say what that will do to the next run before it is saved.
    The script is the real one beside the tray; only rclone is a stub, so the
    remote it verifies against is the stub's answer.
    """
    tray = MODULE.Tray(CFG)
    dialog = MODULE.SettingsDialog(tray)
    dialog.show_all()
    marker = MODULE.marker_file_path(CFG)
    folders = os.path.join(os.environ["TRAY_CALLS"], "folders")
    if os.path.exists(marker):
        os.remove(marker)
    dialog.check_access.set_active(True)
    pump(0.2)
    data = {
        "marker": marker,
        "marker_before": os.path.exists(marker),
        "notice_visible": bool(dialog.label_notice.get_visible()),
        "notice_text": dialog.label_notice.get_text(),
    }

    # The stub remote lists the marker, so the script's own read-back passes.
    with open(folders, "w", encoding="utf-8") as fh:
        fh.write("RCLONE_TEST\n")
    clear_calls()
    dialog.button_markers.clicked()
    data["markers_done"] = wait_for(lambda: not dialog.markers_busy, 20.0)
    pump(0.5)
    data["ok_status"] = dialog.label_status.get_text()
    data["marker_after"] = os.path.exists(marker)
    data["notice_after"] = bool(dialog.label_notice.get_visible())
    data["calls_ok"] = call_lines()

    # Now the remote does not list it: the failure has to be shown here, not
    # swallowed, and the warning has to come back.
    os.remove(folders)
    os.remove(marker)
    clear_calls()
    dialog.button_markers.clicked()
    data["failed_done"] = wait_for(lambda: not dialog.markers_busy, 20.0)
    pump(0.5)
    data["fail_status"] = dialog.label_status.get_text()
    # The script writes the local marker before it verifies the remote one, so
    # the local half of a failed run has still happened; that is the script's
    # own behaviour, reported here rather than asserted on.
    data["marker_after_fail"] = os.path.exists(marker)
    data["notice_after_fail"] = bool(dialog.label_notice.get_visible())
    data["calls_fail"] = call_lines()
    data["dialog_still_open"] = not dialog.done
    dialog.destroy()
    return data


def scenario_settings_save():
    """Save: the file is edited in place, and the live settings follow."""
    tray = MODULE.Tray(CFG)
    pump(0.5)
    clear_calls()
    before = read_text(MODULE.CONFIG_FILE)
    dialog = MODULE.SettingsDialog(tray)
    dialog.show_all()
    # One change of each kind: language and icon apply to the running tray, the
    # rest go to the config file, to systemd or to the autostart directory.
    dialog.combo_lang.set_active_id("zh")
    dialog.check_show.set_active(False)
    dialog.spin_interval.set_value(15)
    dialog.check_watch.set_active(False)
    dialog.check_notify.set_active(False)
    dialog.spin_delete.set_value(0)
    dialog.combo_bw.set_active_id("10M")
    dialog.check_access.set_active(True)
    dialog.check_boot.set_active(True)
    changed = dialog.values()
    dialog.on_save()
    saved = wait_for(lambda: dialog.done or dialog.failures, 20.0)
    pump(0.5)
    after = read_text(MODULE.CONFIG_FILE)
    data = {
        "saved": bool(saved and dialog.done),
        "failures": dialog.failures,
        "status_text": dialog.label_status.get_text(),
        "changed": changed,
        "config_before": before,
        "config_after": after,
        "interval_line_before": line_of(before, "INTERVAL_MIN"),
        "interval_line_after": line_of(after, "INTERVAL_MIN"),
        "menu_labels": visible_labels(tray.menu),
        "header_label": tray.item_header.get_label() or "",
        "pause_items": item_labels(tray.menu, next(
            index for index, item in enumerate(tray.menu.get_children())
            if item is tray.item_pause)),
        "status_label": tray.item_status.get_label() or "",
        "icon_visible": bool(tray.icon_visible),
        "indicator_status": int(tray.ind.get_status()),
        "status_active": int(MODULE.AppIndicator.IndicatorStatus.ACTIVE),
        "status_passive": int(MODULE.AppIndicator.IndicatorStatus.PASSIVE),
        "unit": tray.unit,
        "dropin_path": MODULE.timer_dropin_path(tray.unit),
        "dropin": read_text(MODULE.timer_dropin_path(tray.unit)),
        "autostart_path": MODULE.AUTOSTART,
        "autostart": read_text(MODULE.AUTOSTART),
        "calls": call_lines(),
    }
    dialog.destroy()
    return data


def scenario_settings_fail():
    """A systemd call that fails is reported in the window, which stays open."""
    tray = MODULE.Tray(CFG)
    pump(0.3)
    dialog = MODULE.SettingsDialog(tray)
    dialog.show_all()
    dialog.spin_interval.set_value(30)
    dialog.check_watch.set_active(not dialog.check_watch.get_active())
    dialog.on_save()
    wait_for(lambda: dialog.done or dialog.failures, 20.0)
    pump(0.3)
    data = {
        "done": bool(dialog.done),
        "failures": dialog.failures,
        "status_text": dialog.label_status.get_text(),
        "status_shown": bool(dialog.label_status.get_visible()),
        "save_sensitive": bool(dialog.save_button.get_sensitive()),
        "config_text": read_text(MODULE.CONFIG_FILE),
        "dropin": read_text(MODULE.timer_dropin_path(tray.unit)),
    }
    dialog.destroy()
    return data


def scenario_about():
    """The About window: the version, where the config is, and the project."""
    tray = build()
    seen = {}

    real = MODULE.Gtk.MessageDialog
    MODULE.Gtk.MessageDialog = fake_message_dialog(seen, 0)
    try:
        find_at(tray.menu, "About").activate()
    finally:
        MODULE.Gtk.MessageDialog = real
    seen["version"] = MODULE.VERSION
    seen["config_file"] = MODULE.CONFIG_FILE
    seen["url"] = MODULE.PROJECT_URL
    seen["app"] = MODULE.APP_NAME
    return seen


def scenario_notify():
    """A finished sync is optional to announce; a failure never is."""
    shown = []

    class FakeNote:
        def __init__(self, title, body, icon):
            shown.append(body)

        def set_urgency(self, *_):
            pass

        def show(self):
            pass

    class FakeNotify:
        Urgency = type("Urgency", (), {"NORMAL": 0})

        class Notification:
            # notify() calls Notification.new(...), the way libnotify's own
            # binding does; anything else would be swallowed by its except.
            @staticmethod
            def new(title, body, icon):
                return FakeNote(title, body, icon)

        @staticmethod
        def init(_app):
            pass

    cfg = dict(CFG)
    cfg["NOTIFY_ON_SUCCESS"] = os.environ.get("TRAY_NOTIFY", "1")
    log = os.path.join(os.path.dirname(cfg["LOG"]), "notify.log")
    cfg["LOG"] = log
    real = MODULE.Notify
    MODULE.Notify = FakeNotify
    try:
        tray = MODULE.Tray(cfg)
        pump(0.3)

        def once(text):
            del shown[:]
            with open(log, "w", encoding="utf-8") as fh:
                fh.write(text)
            tray.state = None
            tray.was_syncing = True
            tray.manual_requested = True
            tray._apply_state(False, "enabled")
            pump(0.3)
            return list(shown)

        ok = once("2026/01/02 03:04:05 INFO  : Bisync successful\n")
        bad = once("2026/01/02 03:05:05 ERROR : [network] remote unreachable\n")
    finally:
        MODULE.Notify = real
    return {"notify_on_success": cfg["NOTIFY_ON_SUCCESS"],
            "success_bodies": ok, "failure_bodies": bad}


def scenario_icons():
    """Draw the five icons twice and report what is actually in the files.

    The pixels are decoded here rather than by an image library: the suite must
    not grow a dependency on PIL, and the PNG header is what proves the file is
    really 8-bit RGBA rather than a palette or a greyscale image.
    """
    import hashlib
    import struct
    import zlib

    import cairo

    def read_png(path):
        with open(path, "rb") as fh:
            blob = fh.read()
        if blob[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError("not a PNG: %s" % path)
        pos, idat, header = 8, [], None
        while pos + 8 <= len(blob):
            length = struct.unpack(">I", blob[pos:pos + 4])[0]
            kind = blob[pos + 4:pos + 8]
            body = blob[pos + 8:pos + 8 + length]
            if kind == b"IHDR":
                header = struct.unpack(">IIBBBBB", body)
            elif kind == b"IDAT":
                idat.append(body)
            pos += 12 + length
        width, height, depth, colour = header[0], header[1], header[2], header[3]
        raw = zlib.decompress(b"".join(idat))
        channels = {0: 1, 2: 3, 4: 2, 6: 4}[colour]
        stride = width * channels
        out = bytearray(stride * height)
        prev = bytearray(stride)
        cursor = 0
        for y in range(height):
            filt = raw[cursor]
            cursor += 1
            line = bytearray(raw[cursor:cursor + stride])
            cursor += stride
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                up = prev[i]
                if filt == 1:
                    line[i] = (line[i] + left) & 0xFF
                elif filt == 2:
                    line[i] = (line[i] + up) & 0xFF
                elif filt == 3:
                    line[i] = (line[i] + ((left + up) >> 1)) & 0xFF
                elif filt == 4:
                    corner = prev[i - channels] if i >= channels else 0
                    p = left + up - corner
                    pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                    pred = left if (pa <= pb and pa <= pc) else (
                        up if pb <= pc else corner)
                    line[i] = (line[i] + pred) & 0xFF
            out[y * stride:(y + 1) * stride] = line
            prev = line
        return {"width": width, "height": height, "depth": depth,
                "colour_type": colour, "pixels": bytes(out)}

    def near(pixel, colour, slack=26):
        return all(abs(pixel[i] - round(colour[i] * 255)) <= slack
                   for i in range(3))

    def digest(path):
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()

    def small_copy(surface, size=22):
        out = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
        cr = cairo.Context(out)
        cr.scale(size / float(surface.get_width()), size / float(surface.get_height()))
        cr.set_source_surface(surface, 0, 0)
        cr.paint()
        out.flush()
        return out, bytes(out.get_data()), out.get_stride()

    first = os.path.join(WORK, "icons-first")
    second = os.path.join(WORK, "icons-second")
    for folder in (first, second):
        os.makedirs(folder, exist_ok=True)
    for state in MODULE.STATES:
        MODULE.draw_icon(os.path.join(first, state + ".png"), state)
        MODULE.draw_icon(os.path.join(second, state + ".png"), state)
    MODULE.draw_icon(os.path.join(first, "syncing-40.png"), "syncing", 40)

    data = {"states": list(MODULE.STATES), "icons": {}, "digests": {},
            "sizes": {}}                      # 22px versions, for the panel
    for state in MODULE.STATES:
        path = os.path.join(first, state + ".png")
        png = read_png(path)
        surface = cairo.ImageSurface.create_from_png(path)   # proves it decodes
        pixels = png["pixels"]
        stats = {"width": png["width"], "height": png["height"],
                 "depth": png["depth"], "colour_type": png["colour_type"],
                 "clear": 0, "edge": 0, "opaque": 0, "colours": set(),
                 "cloud": 0, "badge": 0, "corner_clear": 0}
        for i in range(0, len(pixels), 4):
            r, g, b, a = pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]
            if a == 0:
                stats["clear"] += 1
                continue
            if a < 250:
                stats["edge"] += 1
                continue
            stats["opaque"] += 1
            stats["colours"].add((r, g, b))
            if near((r, g, b), MODULE.CLOUD_COLOR):
                stats["cloud"] += 1
            if near((r, g, b), MODULE.BADGE_COLORS[state]):
                stats["badge"] += 1
        stats["corner_clear"] = sum(
            1 for x, y in ((0, 0), (63, 0), (0, 63))
            if pixels[(y * png["width"] + x) * 4 + 3] == 0)
        stats["colours"] = len(stats["colours"])
        stats["total"] = png["width"] * png["height"]
        stats["idempotent"] = digest(path) == digest(
            os.path.join(second, state + ".png"))
        data["icons"][state] = stats
        data["digests"][state] = digest(path)[:16]

        small, buf, stride = small_copy(surface)
        centre = (MODULE.BADGE_CENTER[0] * 22.0 / 64.0,
                  MODULE.BADGE_CENTER[1] * 22.0 / 64.0)
        badge_rgb = tuple(round(c * 255) for c in MODULE.BADGE_COLORS[state])
        # How far the pixels in the middle of the badge get from the badge
        # colour: that is the glyph, and at 22px it is the only thing telling the
        # five states apart. A flat disc scores 0.
        contrast = 0
        for y in range(22):
            for x in range(22):
                off = y * stride + x * 4
                if buf[off + 3] < 250:
                    continue
                if (x + 0.5 - centre[0]) ** 2 + (y + 0.5 - centre[1]) ** 2 > 9:
                    continue
                if sys.byteorder == "little":
                    px = (buf[off + 2], buf[off + 1], buf[off])
                else:
                    px = (buf[off + 1], buf[off + 2], buf[off + 3])
                contrast = max(contrast,
                               max(abs(px[i] - badge_rgb[i]) for i in range(3)))
        data["sizes"][state] = {
            "glyph_contrast": contrast,
            "hash": hashlib.sha256(buf).hexdigest()[:16],
            "bytes": len(buf)}

    # The syncing icon with a percentage is a different drawing, and it is the
    # tray, not the test, that has to ask for it.
    data["progress_differs"] = digest(os.path.join(first, "syncing-40.png")) != \
        digest(os.path.join(first, "syncing.png"))
    tray = MODULE.Tray(dict(CFG))
    pump(0.2)
    tray.state = "syncing"
    tray.sync_pct = None
    before = digest(tray.icons["syncing"])
    # A stats block is only believed while it is recent, so the stamp has to be
    # now: a fixed date would be stale on any machine whose clock has moved past
    # it, and the tray would (correctly) ignore the block.
    now = time.strftime("%Y/%m/%d %H:%M:%S")
    with open(CFG["LOG"], "w", encoding="utf-8") as fh:
        fh.write("%s INFO  : Transferred:   1.5 MiB / 10 MiB, 15%%, 250 KiB/s\n"
                 % now)
        fh.write("%s INFO  :  * big-file.bin: 15%% done\n" % now)
    tray._apply_state(True, "enabled")
    pump(0.2)
    data["tray_pct"] = tray.sync_pct
    data["tray_redrew_syncing"] = digest(tray.icons["syncing"]) != before
    os.remove(CFG["LOG"])
    return data


def scenario_cli_settings():
    """--settings opens the window even when another tray holds the lock.

    That is the case the flag exists for: the icon can be hidden, and a hidden
    icon does not stop the process holding the single-instance lock.
    """
    import subprocess

    tray_path = sys.argv[2]
    data = {}
    for label in ("free", "held"):
        lock = None
        if label == "held":
            lock = MODULE.acquire_lock()
            if lock is None:
                data["lock_taken"] = False
                continue
        err = os.path.join(WORK, "cli-%s.err" % label)
        with open(err, "w", encoding="utf-8") as fh:
            proc = subprocess.Popen([sys.executable, tray_path, "--settings"],
                                    stdout=subprocess.DEVNULL, stderr=fh)
        time.sleep(4.0)
        data[label + "_alive"] = proc.poll() is None
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        data[label + "_stderr"] = read_text(err)
        if lock is not None:
            MODULE.release_lock(lock)
    return data


def install_fake_notify(shown):
    """Replace the notification binding with one that records the bodies.

    notify() reads the binding when it is called, so a scenario that wants to
    read what the tray said replaces it before it does anything.
    """
    class FakeNote:
        def __init__(self, title, body, icon):
            shown.append(body)

        def set_urgency(self, *_):
            pass

        def show(self):
            pass

    class FakeNotify:
        Urgency = type("Urgency", (), {"NORMAL": 0})

        class Notification:
            @staticmethod
            def new(title, body, icon):
                return FakeNote(title, body, icon)

        @staticmethod
        def init(_app):
            pass

    return FakeNotify


def scenario_excluded_name():
    """A name the folder list cannot hold is refused, and nothing is deleted.

    A line starting with # is a comment to both readers of exclude-folders.txt,
    so unticking "#notes" left the menu saying the folder was out of the sync
    while onedrive-sync kept syncing it. The local copy is what turns that into
    data loss: with the exclusion not in effect, deleting it is an ordinary
    local delete, and the next bisync propagates the deletion to the cloud.
    """
    # The listing normally arrives from rclone on a worker; giving the stub the
    # same names means a late answer cannot rebuild the submenu underneath the
    # assertions below.
    with open(os.path.join(os.environ["TRAY_CALLS"], "folders"), "w",
              encoding="utf-8") as fh:
        fh.write("#notes/\nDocs/\n")
    tray = build()
    folder = os.path.join(tray.local, "#notes")
    kept = os.path.join(folder, "kept.txt")
    os.makedirs(folder, exist_ok=True)
    with open(kept, "w", encoding="utf-8") as fh:
        fh.write("still here\n")

    shown = []
    asked = []

    class CountingDialog:
        """Accepts every confirmation and remembers how many there were."""

        def __init__(self, *a, **k):
            asked.append(k.get("text", ""))

        def format_secondary_text(self, text):
            pass

        def add_button(self, label, response):
            pass

        def run(self):
            return MODULE.Gtk.ResponseType.OK

        def destroy(self):
            pass

    real_notify = MODULE.Notify
    real_dialog = MODULE.Gtk.MessageDialog
    MODULE.Notify = install_fake_notify(shown)
    MODULE.Gtk.MessageDialog = CountingDialog
    try:
        tray.folders = ["#notes", "Docs"]
        tray.folders_seen = list(tray.folders)
        tray._build_folder_menu()
        pump(0.3)
        find_at(tray.menu, "#notes").set_active(False)
        pump(0.8)
        data = {
            "tick_back": bool(find_at(tray.menu, "#notes").get_active()),
            "excluded": MODULE.read_excluded_folders(tray.exclude_file),
            "file_text": read_text(tray.exclude_file),
            "asked_after_untick": len(asked),
            "local_after_untick": os.path.isfile(kept),
            "notices": list(shown),
        }
        # These sentences reach t() through a variable, so the static check that
        # every t() key has a Chinese entry cannot see them. They are the whole
        # message a user gets when a click is refused, so they are checked here.
        refusals = [MODULE.exclusion_problem(name)
                    for name in ("", " ", " a", "#notes", "a\nb")]
        refusals.append("Could not save the folder list")
        data["refusals_translated"] = all(
            MODULE.STRINGS["zh"].get(text) for text in refusals)
        data["refusals"] = refusals
        # The offer has to refuse on its own as well: the dialog it puts up
        # promises the folder stays in OneDrive, and that promise is only true
        # while the folder is really out of the sync.
        del asked[:]
        tray._offer_local_delete("#notes")
        pump(0.5)
        data["asked_direct"] = len(asked)
        data["local_after_direct"] = os.path.isfile(kept)
    finally:
        MODULE.Notify = real_notify
        MODULE.Gtk.MessageDialog = real_dialog
    # The fixture goes, not the tray: the scenarios after this one list what is
    # in LOCAL, and this folder is only here to be refused.
    shutil.rmtree(folder, ignore_errors=True)
    pump(0.3)
    return data


def scenario_pause_recovery():
    """What the tray does at startup with a pause stamp in ~/.cache.

    A transient systemd unit lives only in the running user manager, so a reboot
    or a logout during a pause leaves both units disabled with no timer behind
    it while the stamp still holds a future time. Reading the stamp alone made
    the menu promise a resume that could never come.
    """
    case = os.environ.get("TRAY_PAUSE_CASE", "gone")
    stamp = MODULE.PAUSE_STAMP
    os.makedirs(os.path.dirname(stamp), exist_ok=True)
    due = int(time.time()) + (-60 if case == "expired" else 900)
    with open(stamp, "w", encoding="utf-8") as fh:
        fh.write(str(due))

    # A paused pair is one whose timer is disabled, which is also what makes the
    # tray read the stamp at all.
    with open(os.path.join(os.environ["TRAY_CALLS"], "timer-disabled"), "w"):
        pass
    active = os.path.join(os.environ["TRAY_CALLS"], "pause-timer-active")
    if case == "alive":
        with open(active, "w"):
            pass
    elif os.path.exists(active):
        os.remove(active)

    shown = []
    real_notify = MODULE.Notify
    MODULE.Notify = install_fake_notify(shown)
    clear_calls()
    try:
        tray = MODULE.Tray(CFG)
        if case in ("gone", "alive"):
            wait_for(lambda: any("is-active rclone-onedrive-tray-resume.timer" in x
                                 for x in call_lines()), 8.0)
        else:
            wait_for(lambda: not os.path.exists(stamp) or shown, 8.0)
        pump(0.5)
        data = {
            "case": case,
            "stamp_left": os.path.exists(stamp),
            "due_in_future": due > time.time(),
            "rearmed": [x for x in call_lines() if x.startswith("systemd-run")],
            "enabled_after": [x for x in call_lines() if "enable --now" in x],
            "pause_label": tray.item_pause.get_label() or "",
            "notices": list(shown),
            "auto_seen": getattr(tray, "auto_seen", None),
        }
    finally:
        MODULE.Notify = real_notify
    return data


SCENARIOS = {
    "menus": scenario_menus,
    "quota": scenario_quota,
    "sync": scenario_sync,
    "pause-durations": scenario_pause_durations,
    "timer-state": scenario_timer_state,
    "folders": scenario_folders,
    "excluded-name": scenario_excluded_name,
    "folder-delete": scenario_folder_delete,
    "pause-recovery": scenario_pause_recovery,
    "openapp": scenario_openapp,
    "lock-hold": scenario_lock_hold,
    "lock-second": scenario_lock_second,
    "reauth": scenario_reauth,
    "settings-view": scenario_settings_view,
    "settings-markers": scenario_settings_markers,
    "settings-save": scenario_settings_save,
    "settings-fail": scenario_settings_fail,
    "about": scenario_about,
    "notify": scenario_notify,
    "icons": scenario_icons,
    "cli-settings": scenario_cli_settings,
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

# driver_env SCENARIO [VAR=VALUE...] -- the driver, in the one environment every
# scenario runs in: a private runtime directory, a PATH holding the stubs, the
# private Broadway display, and a fixed UTF-8 locale so a desktop configured with
# another one cannot change what is measured.
driver_env() {
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

# The tray's own chatter (GTK warnings from a display with no StatusNotifier
# host, for one) is noise the assertions do not want. driver_quiet folds it into
# DRIVER_ERR; driver_both leaves stderr alone, because the second instance of the
# tray writes its refusal there and the harness's run() only reads stdout.
driver_quiet() { driver_env "$@" 2>"$DRIVER_ERR"; }
driver_both()  { driver_env "$@"; }

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
        grep -v -e WARNING -e '^$' "$DRIVER_ERR" | head -4 | sed 's/^/        /'
        return 1
    fi
    return 0
}

# json_run MODE SNIPPET -- run a snippet over LAST_JSON, where `d` is the parsed
# object. MODE=exec treats the snippet as statements; MODE=eval treats it as one
# expression and reports the expression and the data when it is false. Anything
# the snippet prints becomes the failure detail.
json_run() {
    python3 - "$LAST_JSON" "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
snippet = sys.argv[3]
if sys.argv[2] == "exec":
    exec(snippet)
elif not eval(snippet):            # noqa: S307 - the suite's own expression
    print("expression false: %s" % snippet)
    print("data: %s" % json.dumps(d, ensure_ascii=False)[:600])
    raise SystemExit(1)
PY
}

json_py()   { json_run exec "$1"; }
json_expr() { json_run eval "$1"; }

# set_config KEY VALUE -- set one key in the sandbox config, leaving every other
# line where it is. The tray reads this file, so the scenarios that need a value
# the suite did not write at startup patch it here rather than rewriting the file.
set_config() {
    python3 - "$WORK/config/rclone-onedrive-tray/config" "$1" "$2" <<'PY'
import sys

path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    lines = fh.read().splitlines()
out = ["%s=%s" % (key, value) if line.startswith(key + "=") else line
       for line in lines]
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
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
        json_expr "all(x in d['menu_labels'] for x in ['Sync now', 'Open sync folder', 'View sync log', 'Folders to sync', 'Pause automatic sync', 'Start tray at login', 'Check file names', 'Re-authorise OneDrive…', 'Rebuild sync baseline (resync)…', 'Settings…', 'About', 'Quit', 'Docs', 'Music', '.config', '30 minutes', '2 hours', '8 hours', 'Resume now'])"
    check "the first row names the application and the version" json_py '
want = "OneDrive " + d["version"]
if d["header_label"] != want:
    print("header: %r, wanted %r" % (d["header_label"], want))
    raise SystemExit(1)
if not d["header_is_first"]:
    print("the header is not the first row: %r" % (d["menu_labels"][:3],))
    raise SystemExit(1)
'
    check "the header says nothing when clicked" json_expr "not d['header_sensitive']"
    check "the English menu contains no Chinese" json_py '
if any(any("\u4e00" <= c <= "\u9fff" for c in x) for x in d["menu_labels"]):
    print("Chinese label under UI_LANG=en: %r" % d["menu_labels"])
    raise SystemExit(1)
'
fi

if run_driver menus TRAY_LANG=zh; then
    check "the Chinese menu has the expected labels" \
        json_expr "all(x in d['menu_labels'] for x in ['立即同步', '打开同步文件夹', '查看同步日志', '同步的文件夹', '暂停自动同步', '开机自动启动托盘', '检查文件名', '重新登录 OneDrive…', '设置…', '关于', '退出', '30 分钟', '2 小时', '8 小时', '立即恢复'])"
    check "no Chinese label is left in English" json_py '
left = [x for x in d["menu_labels"]
        if x in ("Sync now", "View sync log", "Quit", "Resume now", "Settings…",
                 "About")]
if left:
    print("untranslated under UI_LANG=zh: %r" % left)
    raise SystemExit(1)
'
    check "the header keeps the application name and the version" json_py '
want = "OneDrive " + d["version"]
if d["header_label"] != want:
    print("header: %r, wanted %r" % (d["header_label"], want))
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

title "A pause whose resume timer did not survive"
# The timer that ends a pause is a transient systemd unit, so it lives only in
# the running user manager: a reboot during the pause leaves both units disabled
# with nothing to bring them back, while the stamp in the cache still holds a
# future time. The stamp alone is not proof of anything, so each case here asks
# what the tray does about it.
if run_driver pause-recovery TRAY_PAUSE_CASE=gone; then
    check "a stamp with no timer behind it is re-armed" json_py '
armed = [x for x in d["rearmed"]
         if "rclone-onedrive-tray-resume" in x and "enable --now" in x]
if not armed:
    print("nothing was scheduled for a pause still in the future: %r"
          % (d["rearmed"],))
    raise SystemExit(1)
'
    check "the re-armed timer covers what is left of the pause" json_py '
import re
armed = [x for x in d["rearmed"] if "rclone-onedrive-tray-resume" in x]
left = [int(m.group(1))
        for m in (re.search(r"--on-active=(\d+)s", x) for x in armed) if m]
if not left or not all(0 < n <= 900 for n in left):
    print("scheduled %r seconds for a pause with 900 left" % (left,))
    raise SystemExit(1)
'
    check "and the pause the stamp claims is kept, not dropped" json_py '
if not d["stamp_left"] or not d["due_in_future"]:
    print("stamp_left=%r due_in_future=%r label=%r"
          % (d["stamp_left"], d["due_in_future"], d["pause_label"]))
    raise SystemExit(1)
'
fi

if run_driver pause-recovery TRAY_PAUSE_CASE=alive; then
    check "a stamp whose timer is still loaded is left alone" json_py '
if d["rearmed"]:
    print("a second resume timer was scheduled over a live one: %r"
          % (d["rearmed"],))
    raise SystemExit(1)
if not d["stamp_left"]:
    print("the stamp went away although its timer is loaded")
    raise SystemExit(1)
'
fi

if run_driver pause-recovery TRAY_PAUSE_CASE=expired; then
    check "an expired stamp is dropped instead of claiming a pause" json_py '
if d["stamp_left"]:
    print("the expired stamp is still there")
    raise SystemExit(1)
if "paused" in d["pause_label"].lower():
    print("the menu still claims a pause: %r" % (d["pause_label"],))
    raise SystemExit(1)
'
fi

: > "$WORK/calls/systemd-run-fail"
if run_driver pause-recovery TRAY_PAUSE_CASE=fail; then
    check "a resume that cannot be restored ends the pause and says so" json_py '
if d["stamp_left"]:
    print("the stamp survived a pause that cannot be kept")
    raise SystemExit(1)
if not any("enable --now ztraytest.timer" in x for x in d["enabled_after"]):
    print("the units were left disabled with nothing to end the pause: %r"
          % (d["enabled_after"],))
    raise SystemExit(1)
if not any("resume" in body for body in d["notices"]):
    print("nothing was said about it: %r" % (d["notices"],))
    raise SystemExit(1)
if "paused" in d["pause_label"].lower():
    print("the menu still claims a pause: %r" % (d["pause_label"],))
    raise SystemExit(1)
'
fi
rm -f "$WORK/calls/systemd-run-fail" "$WORK/calls/timer-disabled" \
      "$WORK/calls/pause-timer-active" \
      "$WORK/cache/rclone-onedrive-tray/paused-until"

title "A disabled timer is not a pause"
# Both timer-state scenarios ask this of a different systemctl answer: does
# anything on screen claim a pause that never happened?
PAUSE_CLAIM='
claims = [x for x in d["menu_labels"] + [d["status"], d["pause_label"]]
          if "paused" in x.lower() or "暂停" in x]
if claims:
    print("a pause was claimed: %r" % claims)
    raise SystemExit(1)
'
printf 'Docs/\nMusic/\n' > "$WORK/calls/folders"
printf 'x\n' > "$WORK/calls/timer-disabled"
if run_driver timer-state TRAY_EXPECT_AUTO=off; then
    check "systemctl answering disabled is not reported as a pause" \
        json_py "$PAUSE_CLAIM"
    check "the state the tray reports is one it can name" json_expr "d['auto_seen'] in ('off', 'unknown')"
fi

rm -f "$WORK/calls/timer-disabled"
printf 'x\n' > "$WORK/calls/notimer"
if run_driver timer-state TRAY_EXPECT_AUTO=unknown; then
    check "systemctl answering nothing is not reported as a pause" \
        json_py "$PAUSE_CLAIM"
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

title "A folder name the list cannot hold"
# Both readers of exclude-folders.txt treat a line starting with # as a comment,
# so unticking "#notes" cannot be written down. The menu used to say the folder
# was out of the sync anyway and then offer to delete the local copy, which is
# still synced: that delete is an ordinary local delete, and the next bisync
# propagates it to the cloud.
if run_driver excluded-name; then
    check "unticking a name the file cannot hold puts the tick back" json_py '
if not d["tick_back"]:
    print("the tick stayed off with nothing written: excluded=%r"
          % (d["excluded"],))
    raise SystemExit(1)
'
    check "and nothing is written for it" json_py '
if "#notes" in d["excluded"] or "#notes" in d["file_text"]:
    print("the name reached the file: excluded=%r file=%r"
          % (d["excluded"], d["file_text"]))
    raise SystemExit(1)
'
    check "and the refusal is said out loud, not silently swallowed" json_py '
if not any("comment" in body for body in d["notices"]):
    print("notices: %r" % (d["notices"],))
    raise SystemExit(1)
if any("will not sync" in body for body in d["notices"]):
    print("the menu claimed the folder is out of the sync: %r" % (d["notices"],))
    raise SystemExit(1)
'
    check "no local copy is offered, or deleted, for it" json_py '
if d["asked_after_untick"] or d["asked_direct"]:
    print("a delete was offered: after the untick %r, when asked directly %r"
          % (d["asked_after_untick"], d["asked_direct"]))
    raise SystemExit(1)
if not d["local_after_untick"] or not d["local_after_direct"]:
    print("the local copy was deleted: after the untick %r, when asked directly %r"
          % (d["local_after_untick"], d["local_after_direct"]))
    raise SystemExit(1)
'
    check "every refusal it can give has a Chinese sentence" json_py '
if not d["refusals_translated"]:
    print("no Chinese entry for: %r" % (d["refusals"],))
    raise SystemExit(1)
'
fi

title "Deleting a deselected folder's local copy"
# The guard decides on a name that came from a remote listing, and shutil.rmtree
# runs on whatever it returns. Only one ordinary component inside LOCAL may ever
# get that far: everything else, including a symlink that leaves LOCAL, has to be
# refused before the confirmation is even put on screen.
if run_driver folder-delete; then
    check "the one ordinary folder is offered and then deleted" json_py '
if d["ordinary_asked"] != 1 or not d["ordinary_gone"]:
    print("asked=%r gone=%r title=%r"
          % (d["ordinary_asked"], d["ordinary_gone"], d["ordinary_title"]))
    raise SystemExit(1)
'
    check "../outside is refused" json_py '
if d["asked"]["../outside"] != 0:
    print("a dialog was put on screen for ../outside: %r"
          % (d["asked"]["../outside"],))
    raise SystemExit(1)
'
    check "a two-component name is refused and its directory survives" json_py '
if d["asked"]["a/b"] != 0 or not d["nested_intact"]:
    print("asked=%r nested_intact=%r"
          % (d["asked"]["a/b"], d["nested_intact"]))
    raise SystemExit(1)
'
    check ".. is refused" json_py '
if d["asked"][".."] != 0:
    print("a dialog was put on screen for ..: %r" % (d["asked"][".."],))
    raise SystemExit(1)
'
    check ". is refused" json_py '
if d["asked"]["."] != 0:
    print("a dialog was put on screen for .: %r" % (d["asked"]["."],))
    raise SystemExit(1)
'
    check "an empty name is refused" json_py '
if d["asked"][""] != 0:
    print("a dialog was put on screen for an empty name: %r"
          % (d["asked"][""],))
    raise SystemExit(1)
'
    check "a symlink to a sibling named like the root is refused" json_py '
if d["asked"]["link-to-sibling"] != 0:
    print("a dialog was put on screen for a sibling directory: %r"
          % (d["asked"]["link-to-sibling"],))
    raise SystemExit(1)
if not d["sibling_kept"] or d["sibling_files"] != ["older.txt"]:
    print("the sibling directory was touched: kept=%r files=%r"
          % (d["sibling_kept"], d["sibling_files"]))
    raise SystemExit(1)
'
    check "a symlink that leaves LOCAL is refused" json_py '
if d["asked"]["link-to-outside"] != 0:
    print("a dialog was put on screen for the symlink: %r"
          % (d["asked"]["link-to-outside"],))
    raise SystemExit(1)
'
    check "a symlink that resolves back to LOCAL itself is refused" json_py '
if d["asked"]["self-link"] != 0:
    print("a dialog was put on screen for the self-link: %r"
          % (d["asked"]["self-link"],))
    raise SystemExit(1)
'
    check "the outside directory and its contents still exist" json_py '
if not d["outside_kept"] or d["outside_files"] != ["precious.txt"]:
    print("kept=%r files=%r" % (d["outside_kept"], d["outside_files"]))
    raise SystemExit(1)
'
    check "the symlink still points at the outside directory" \
        json_expr "d['link_intact']"
    check "the refused names left the rest of LOCAL where it was" json_py '
if d["local_listing"] != ["a", "link-to-outside", "link-to-sibling", "self-link"]:
    print("LOCAL holds %r" % (d["local_listing"],))
    raise SystemExit(1)
'
fi

title "A quoted OPEN_APP_CMD"
cat > "$WORK/stubs/probing-stub" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$WORK/calls/openapp"
STUB
chmod +x "$WORK/stubs/probing-stub"
# The command holds a quoted argument, which is the case that used to be split on
# whitespace and passed through with its quotes intact. Single quotes are used so
# that no backslash survives into the config file.
set_config OPEN_APP_CMD "\"$WORK/stubs/probing-stub 'probe arg' --flag\""
if run_driver openapp; then
    check "the quoted command runs as three arguments" \
        json_expr "d['openapp_ran'] and d['openapp_argv'] == ['probe arg', '--flag']"
    check "the quote characters reach nothing" \
        json_expr "not any('\"' in x for x in d['openapp_argv'])"
fi
set_config OPEN_APP_CMD '""'

title "The single-instance lock"
# The lock lives under XDG_RUNTIME_DIR, which is this suite's $WORK/run: 0700 and
# belonging to one user, so nobody else can take the name first. It used to be a
# fixed name in TMPDIR, where another local user could leave a symlink behind and
# have the tray truncate whatever it pointed at.
LOCK_PATH="$WORK/run/rclone-onedrive-tray.lock"
printf 'do not touch me\n' > "$WORK/victim"
ln -s "$WORK/victim" "$LOCK_PATH"

# A home to run from that has no config, so the run stops at the lock whichever
# version of the tray is under test rather than going on to need a real display.
# TMPDIR is the same directory as XDG_RUNTIME_DIR on purpose: the tray used to
# build the lock path from TMPDIR alone, so that is where a symlink has to sit for
# this to be about following one rather than about which directory wins.
lock_probe() {
    env -i PATH="$WORK/stubs:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK/run" \
        XDG_RUNTIME_DIR="$WORK/run" XDG_CONFIG_HOME="$WORK/no-config-here" \
        DISPLAY=:77 LANG=C.UTF-8 python3 "$TRAY"
}
run "a symlink at the lock path is refused, not followed" \
    1 "symbolic link" lock_probe
check "the symlink's target was not truncated" \
    grep -q 'do not touch me' "$WORK/victim"
LOCK_OUT="$(lock_probe 2>&1)"
if printf '%s' "$LOCK_OUT" | grep -q "already running"; then
    bad "the symlink was reported as another tray running"
else
    ok "the refusal never pretends another tray is running"
fi
rm -f "$LOCK_PATH" "$WORK/victim"

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
        "$WORK/run/rclone-onedrive-tray.lock"
else
    bad "the first process never took the lock"
    kill "$HOLDER" 2>/dev/null
    wait "$HOLDER" 2>/dev/null
fi

title "Signing in again"
if run_driver reauth; then
    check "the confirm dialog names the remote and offers both buttons" \
        json_expr "'traytest-remote:' in d['body'] and d['buttons'] == ['Cancel', 'Sign in again']"
    check "confirming runs rclone's sign-in for the same remote" \
        json_expr "d['reconnect'] and any('config reconnect traytest-remote:' in x for x in d['calls'])"
    check "and it opens a terminal rather than a windowless process" \
        json_expr "any(x.startswith('terminal ') and 'config reconnect' in x for x in d['calls'])"
    check "a completed sign-in starts a sync" \
        json_expr "d['started'] and any('start --no-block ztraytest.service' in x for x in d['calls'])"
fi

title "Strings and translations"
# A static check rather than a driven one: the labels above prove the menu is
# translated, this proves nothing was added to t() without a Chinese entry, and
# that no key is a snake_case identifier.
check "every literal string passed to t() has a Chinese entry" \
    python3 - "$TRAY" <<'PY'
import ast
import re
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    tree = ast.parse(fh.read())
keys = set()
for node in ast.walk(tree):
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == "t" and node.args
            and isinstance(node.args[0], ast.Constant)
            and isinstance(node.args[0].value, str)):
        keys.add(node.args[0].value)
zh = set()
for node in tree.body:
    if getattr(node, "targets", None) and getattr(node.targets[0], "id", "") == "STRINGS":
        zh = set(ast.literal_eval(node.value)["zh"])
raw = re.compile(r"^[a-z][a-z0-9]*(_[a-z0-9]+)+$")
missing = sorted(k for k in keys if k not in zh)
snake = sorted(k for k in keys if raw.match(k))
for problem in (missing, snake):
    if problem:
        print("problem strings: %r" % problem)
if missing or snake:
    raise SystemExit(1)
print("checked %d strings" % len(keys))
PY

# ---------------------------------------------------------- the settings window
SETTINGS_HOME="$WORK/settings"
mkdir -p "$SETTINGS_HOME/rclone-onedrive-tray" "$SETTINGS_HOME/autostart"
cat > "$SETTINGS_HOME/rclone-onedrive-tray/config" <<EOF
# A hand-edited comment the dialog must not delete.
REMOTE="traytest-remote:"
LOCAL="$SETTINGS_HOME/local"
UNIT_NAME="ztraytest"
LOG="$WORK/cache/sync.log"
UI_LANG="en"
# INTERVAL_MIN sits in the middle of the file: replacing it must not move it.
INTERVAL_MIN="5"
EXPERIMENTAL_UNKNOWN_KEY="keep me"
MAX_DELETE="100"
WATCH="1"
CHECK_ACCESS="0"
EOF

title "The settings window"
if run_driver settings-view; then
    check "the window names where the config lives" json_py '
want = "Config file: %s" % d["config_file"]
if d["title"] != "Settings" or d["config_line"] != want:
    print("title %r, line %r" % (d["title"], d["config_line"]))
    raise SystemExit(1)
'
    check "every control is there" json_py '
needed = ["Language", "Show the icon in the panel", "Start tray at login",
          "Sync interval (minutes)", "Realtime sync",
          "Tell me when a sync I start succeeds", "Delete cap (files)",
          "Bandwidth limit", "Access check", "Create the marker files",
          "Save", "Cancel"]
missing = [name for name in needed if name not in d["labels"]]
if missing:
    print("controls that are missing: %r" % missing)
    raise SystemExit(1)
'
    check "the language list offers the system, English and Chinese" \
        json_expr "d['lang_choices'] == ['Follow the system', 'English', '中文']"
    check "the bandwidth list is Unlimited and the four sizes" \
        json_expr "d['bw_choices'] == ['Unlimited', '1M', '5M', '10M', '20M']"
    check "the untouched controls start from the config's own defaults" json_py '
want = {"UI_LANG": "en", "SHOW_ICON": "1", "INTERVAL_MIN": "5", "WATCH": "1",
        "NOTIFY_ON_SUCCESS": "1", "MAX_DELETE": "100", "BW_LIMIT": "",
        "CHECK_ACCESS": "0"}
if d["values"] != want:
    print("values: %r" % (d["values"],))
    raise SystemExit(1)
'
    check "nothing is reported before anything is done" \
        json_expr "not d['notice_visible'] and not d['status_visible']"
    check "start at login follows the autostart file" json_expr "not d['boot']"
fi

title "The marker files behind the access check"
if run_driver settings-markers XDG_CONFIG_HOME="$SETTINGS_HOME"; then
    check "switching the check on warns about the missing markers" json_py '
if not d["notice_visible"] or d["marker_before"]:
    print("notice_visible=%r marker_before=%r"
          % (d["notice_visible"], d["marker_before"]))
    raise SystemExit(1)
if d["marker"] not in d["notice_text"]:
    print("the warning does not name the file: %r" % d["notice_text"])
    raise SystemExit(1)
'
    check "the button hands the job to onedrive-check-access" json_py '
if not any(line.startswith("rclone copyto ") for line in d["calls_ok"]):
    print("calls: %r" % (d["calls_ok"],))
    raise SystemExit(1)
'
    check "a run that worked creates the marker and says so" json_py '
if not d["markers_done"] or not d["marker_after"]:
    print("done=%r marker_after=%r" % (d["markers_done"], d["marker_after"]))
    raise SystemExit(1)
if "The marker files are there." not in d["ok_status"]:
    print("status: %r" % (d["ok_status"],))
    raise SystemExit(1)
'
    check "and the warning goes away once they exist" \
        json_expr "not d['notice_after']"
    check "a run that failed is reported in the window" json_py '
if "does not list it" not in d["fail_status"]:
    print("the script message never reached the window: %r" % (d["fail_status"],))
    raise SystemExit(1)
if d["dialog_still_open"] is False:
    print("the window reported a failure and closed anyway")
    raise SystemExit(1)
'
fi

title "Saving the settings"
if run_driver settings-save XDG_CONFIG_HOME="$SETTINGS_HOME"; then
    check "Save reports nothing wrong" json_py '
if not d["saved"] or d["failures"] or d["status_text"]:
    print("saved=%r failures=%r status=%r"
          % (d["saved"], d["failures"], d["status_text"]))
    raise SystemExit(1)
'
    check "the changed keys are replaced where they were, the rest left alone" json_py '
import re

def parse(text):
    found = {}
    for line in text.splitlines():
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=\"(.*)\"$", line)
        if m:
            found[m.group(1)] = m.group(2)
    return found

before, after = parse(d["config_before"]), parse(d["config_after"])
want = {"UI_LANG": "zh", "SHOW_ICON": "0", "INTERVAL_MIN": "15", "WATCH": "0",
        "NOTIFY_ON_SUCCESS": "0", "MAX_DELETE": "0", "BW_LIMIT": "10M",
        "CHECK_ACCESS": "1"}
for key, value in want.items():
    if after.get(key) != value:
        print("%s is %r, wanted %r" % (key, after.get(key), value))
        raise SystemExit(1)
added = [k for k in ("SHOW_ICON", "NOTIFY_ON_SUCCESS", "BW_LIMIT") if k in before]
if added:
    print("keys that were already in the file: %r" % added)
    raise SystemExit(1)
if "A hand-edited comment the dialog must not delete." not in d["config_after"]:
    print("a comment was lost in the rewrite")
    raise SystemExit(1)
if "EXPERIMENTAL_UNKNOWN_KEY" not in d["config_after"]:
    print("an unknown key was lost in the rewrite")
    raise SystemExit(1)
if d["interval_line_after"] != d["interval_line_before"]:
    print("the file was reshuffled: line %d became %d"
          % (d["interval_line_before"], d["interval_line_after"]))
    raise SystemExit(1)
'
    check "the interval becomes a drop-in, and systemd is told" json_py '
if not d["dropin_path"].endswith("systemd/user/ztraytest.timer.d/interval.conf"):
    print("drop-in path: %r" % (d["dropin_path"],))
    raise SystemExit(1)
if "[Timer]" not in d["dropin"] or "OnUnitInactiveSec=15min" not in d["dropin"]:
    print("drop-in: %r" % (d["dropin"],))
    raise SystemExit(1)
if "systemctl --user daemon-reload" not in d["calls"]:
    print("calls: %r" % (d["calls"],))
    raise SystemExit(1)
'
    check "switching realtime sync off disables the watcher unit" json_py '
if "systemctl --user disable --now ztraytest-watch.service" not in d["calls"]:
    print("calls: %r" % (d["calls"],))
    raise SystemExit(1)
if any("enable --now ztraytest-watch.service" in line for line in d["calls"]):
    print("the watcher was enabled as well: %r" % (d["calls"],))
    raise SystemExit(1)
'
    check "start at login writes the autostart entry" json_py '
if not d["autostart_path"].endswith("autostart/rclone-onedrive-tray.desktop"):
    print("path: %r" % (d["autostart_path"],))
    raise SystemExit(1)
if "X-GNOME-Autostart-enabled=true" not in d["autostart"]:
    print("autostart: %r" % (d["autostart"],))
    raise SystemExit(1)
'
    check "hiding the icon takes the indicator out of the panel, live" json_py '
if d["indicator_status"] != d["status_passive"] or d["icon_visible"]:
    print("status=%r passive=%r visible=%r"
          % (d["indicator_status"], d["status_passive"], d["icon_visible"]))
    raise SystemExit(1)
'
    check "the language changes without a restart" json_py '
for wanted in ("设置…", "关于", "立即同步", "退出"):
    if wanted not in d["menu_labels"]:
        print("%r is missing after the switch: %r" % (wanted, d["menu_labels"]))
        raise SystemExit(1)
if d["pause_items"][1:4] != ["30 分钟", "2 小时", "8 小时"]:
    print("the pause submenu was left behind: %r" % (d["pause_items"],))
    raise SystemExit(1)
left = [x for x in d["menu_labels"]
        if x in ("Sync now", "Quit", "About", "Settings…")]
if left:
    print("still English after the switch: %r" % left)
    raise SystemExit(1)
if not any("\u4e00" <= c <= "\u9fff" for c in d["status_label"]):
    print("the status row is not translated: %r" % d["status_label"])
    raise SystemExit(1)
'
fi

title "Writing the config in place"
# The file is sourced by onedrive-sync with `.`, so a value the dialog writes
# has to survive a round trip through the shell unchanged.
check "a changed value is escaped so the file stays sourceable" \
    env -i PATH="$WORK/stubs:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK/cache" \
        XDG_RUNTIME_DIR="$WORK/run" XDG_CONFIG_HOME="$WORK/quote" \
        GDK_BACKEND=broadway BROADWAY_DISPLAY=:9 DISPLAY=:77 LANG=C.UTF-8 \
        python3 - "$TRAY" "$WORK/quote" <<'PY'
import importlib.machinery
import importlib.util
import os
import subprocess
import sys

# env -i above means no PYTHONDONTWRITEBYTECODE is inherited, and loading bin/
# would otherwise leave a __pycache__ directory in the source tree.
sys.dont_write_bytecode = True

tray_path, work = sys.argv[1], sys.argv[2]
os.makedirs(work, exist_ok=True)
path = os.path.join(work, "config")
with open(path, "w", encoding="utf-8") as fh:
    fh.write("# a comment that is not the tray's business\n"
             'A_KEY="old"\n'
             'NOT_MINE="hands off"\n'
             'B_KEY="keep"\n')

loader = importlib.machinery.SourceFileLoader("tray_quote", tray_path)
spec = importlib.util.spec_from_loader("tray_quote", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)

value = 'new "quoted" $HOME `x`'
appended = module.update_config_file(path, {"A_KEY": value, "C_KEY": "added"})
with open(path, encoding="utf-8") as fh:
    lines = fh.read().splitlines()

problems = []
if lines[0] != "# a comment that is not the tray's business":
    problems.append("the comment moved or went away: %r" % lines[0])
if lines[1] != 'A_KEY="new \\"quoted\\" \\$HOME \\`x\\`"':
    problems.append("A_KEY was not escaped: %r" % lines[1])
if lines[2:4] != ['NOT_MINE="hands off"', 'B_KEY="keep"']:
    problems.append("other keys were rewritten: %r" % lines[2:4])
if appended != ["C_KEY"]:
    problems.append("appended=%r" % (appended,))
if not any(line == 'C_KEY="added"' for line in lines):
    problems.append("the missing key was not appended")
sourced = subprocess.run(["/bin/sh", "-c", '. "$1"; printf "%s" "$A_KEY"',
                          "sh", path], capture_output=True, text=True)
if sourced.stdout != value:
    problems.append("after sourcing the file A_KEY is %r (%s)"
                    % (sourced.stdout, sourced.stderr.strip()))
if problems:
    print("; ".join(problems))
    raise SystemExit(1)
PY

title "The autostart entry's Exec line"
# A home directory can hold a space, and the desktop environment reads the line
# as a command line: written bare, the path is two arguments and the tray never
# starts at login. A % is a field code as well. The line is read back here with
# GLib, which is what a desktop environment uses: the key-file reader first, then
# the Exec parser, then the field codes.
check "a path with a space, a % or a backslash is quoted and reads back whole" \
    env -i PATH="$WORK/stubs:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK/cache" \
        XDG_RUNTIME_DIR="$WORK/run" XDG_CONFIG_HOME="$WORK/exec-home" \
        GDK_BACKEND=broadway BROADWAY_DISPLAY=:9 DISPLAY=:77 LANG=C.UTF-8 \
        python3 - "$TRAY" "$WORK/exec-home" <<'PY'
import importlib.machinery
import importlib.util
import os
import sys

# env -i above means no PYTHONDONTWRITEBYTECODE is inherited, and loading bin/
# would otherwise leave a __pycache__ directory in the source tree.
sys.dont_write_bytecode = True

import gi
# Only GLib is used here. GioUnix is not, and requiring it would fail on any
# distribution older than GLib 2.80, which is how this case first failed on
# ubuntu-22.04 in CI.
gi.require_version("GLib", "2.0")
from gi.repository import GLib

tray_path, work = sys.argv[1], sys.argv[2]
os.makedirs(work, exist_ok=True)

loader = importlib.machinery.SourceFileLoader("tray_exec", tray_path)
spec = importlib.util.spec_from_loader("tray_exec", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)

problems = []
paths = [
    "/home/my user/bin/onedrive-tray",
    "/home/100%/bin/onedrive-tray",
    "/home/a\\b/bin/onedrive-tray",
    '/home/o"d/bin/onedrive-tray',
    "/home/a$b/bin/onedrive-tray",
    "/home/space% and\\slash/onedrive-tray",
]
for index, path in enumerate(paths):
    entry = os.path.join(work, "entry-%d.desktop" % index)
    with open(entry, "w", encoding="utf-8") as fh:
        fh.write(module.autostart_contents(path))
    line = [x for x in open(entry, encoding="utf-8").read().splitlines()
            if x.startswith("Exec=")][0]
    value = line[len("Exec="):]
    if not (value.startswith('"') and value.endswith('"')):
        problems.append("%r was written unquoted: %s" % (path, line))
        continue
    # The key-file layer is what makes the file parse at all, so it is part of
    # the check: an Escaped quote that GLib rejects is a file that never loads.
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

title "A systemd action that fails"
: > "$WORK/calls/systemctl-fail"
if run_driver settings-fail XDG_CONFIG_HOME="$SETTINGS_HOME"; then
    check "the window stays open and lists what failed" json_py '
if d["done"]:
    print("the window closed as if the change had worked")
    raise SystemExit(1)
if len(d["failures"]) != 2:
    print("failures: %r" % (d["failures"],))
    raise SystemExit(1)
if not d["status_shown"] or "mock systemctl failure" not in d["status_text"]:
    print("status: %r" % (d["status_text"],))
    raise SystemExit(1)
if not d["save_sensitive"]:
    print("Save was left disabled, so the change cannot be retried")
    raise SystemExit(1)
'
    check "the config and the drop-in were still written" json_py '
if "INTERVAL_MIN" not in d["config_text"]:
    print("config: %r" % (d["config_text"],))
    raise SystemExit(1)
if "OnUnitInactiveSec=30min" not in d["dropin"]:
    print("the drop-in was not written: %r" % (d["dropin"],))
    raise SystemExit(1)
'
fi
rm -f "$WORK/calls/systemctl-fail"

title "About"
if run_driver about; then
    check "it names the application and the version" json_py '
want = "%s %s" % (d["app"], d["version"])
if d["text"] != want:
    print("title: %r, wanted %r" % (d["text"], want))
    raise SystemExit(1)
'
    check "and carries the version, the config path and the project URL" json_py '
for wanted in (d["version"], d["config_file"], d["url"]):
    if wanted not in d["body"]:
        print("missing from the About text: %r" % wanted)
        raise SystemExit(1)
if len(d["body"].splitlines()) < 4:
    print("the About text is not the four lines it should be: %r" % (d["body"],))
    raise SystemExit(1)
if d["buttons"] != ["Close"]:
    print("buttons: %r" % (d["buttons"],))
    raise SystemExit(1)
'
fi

title "The success notification"
if run_driver notify TRAY_NOTIFY=1; then
    check "a finished sync is announced when it is switched on" json_py '
if not any("Sync finished" in body for body in d["success_bodies"]):
    print("bodies with NOTIFY_ON_SUCCESS=%r: %r"
          % (d["notify_on_success"], d["success_bodies"]))
    raise SystemExit(1)
'
    check "a failure is announced as well" json_expr "bool(d['failure_bodies'])"
fi
if run_driver notify TRAY_NOTIFY=0; then
    check "a finished sync says nothing when it is switched off" \
        json_expr "not d['success_bodies']"
    check "a failure is announced even then" json_expr "bool(d['failure_bodies'])"
fi

title "The status icons"
if run_driver icons; then
    check "all five states are drawn" json_py '
if sorted(d["icons"]) != sorted(d["states"]) or len(d["icons"]) != 5:
    print("states: %r" % (sorted(d["icons"]),))
    raise SystemExit(1)
'
    check "each is a 64x64 8-bit RGBA PNG" json_py '
for state, icon in d["icons"].items():
    shape = (icon["width"], icon["height"], icon["depth"], icon["colour_type"])
    if shape != (64, 64, 8, 6):
        print("%s is %r, wanted 64x64x8 RGBA(6)" % (state, shape))
        raise SystemExit(1)
'
    check "the five are five different drawings, at 64px and at 22px" json_py '
if len(set(d["digests"].values())) != 5:
    print("64px digests: %r" % (d["digests"],))
    raise SystemExit(1)
if len(set(icon["hash"] for icon in d["sizes"].values())) != 5:
    print("22px versions are not distinct: %r" % (d["sizes"],))
    raise SystemExit(1)
'
    check "regenerating them writes the same bytes" json_py '
repeat = sorted(s for s, icon in d["icons"].items() if not icon["idempotent"])
if repeat:
    print("these differed on a second draw: %r" % repeat)
    raise SystemExit(1)
'
    check "a cloud, a badge and a transparent margin on every one" json_py '
for state, icon in d["icons"].items():
    if icon["cloud"] < 300 or icon["badge"] < 200:
        print("%s: cloud=%d badge=%d" % (state, icon["cloud"], icon["badge"]))
        raise SystemExit(1)
    if icon["clear"] < icon["total"] // 4 or icon["corner_clear"] != 3:
        print("%s: clear=%d corners=%d"
              % (state, icon["clear"], icon["corner_clear"]))
        raise SystemExit(1)
    if icon["colours"] < 20:
        print("%s: only %d colours, so nothing is smoothed"
              % (state, icon["colours"]))
        raise SystemExit(1)
'
    check "the badge glyph still has contrast at the 22px a panel uses" json_py '
weak = {s: v["glyph_contrast"] for s, v in d["sizes"].items()
        if v["glyph_contrast"] < 70}
if weak:
    print("glyphs that wash out at 22px: %r" % (weak,))
    raise SystemExit(1)
'
    check "a percentage in the log becomes an arc in the syncing icon" json_py '
if not d["progress_differs"] or d["tray_pct"] != 15 or not d["tray_redrew_syncing"]:
    print("differs=%r pct=%r redrew=%r"
          % (d["progress_differs"], d["tray_pct"], d["tray_redrew_syncing"]))
    raise SystemExit(1)
'
fi

title "The command line"
CLI_HOME="$WORK/cli-home"
mkdir -p "$CLI_HOME/rclone-onedrive-tray"
cp "$WORK/config/rclone-onedrive-tray/config" "$CLI_HOME/rclone-onedrive-tray/config"
cli() {
    env -i PATH="$WORK/stubs:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK/cache" \
        XDG_RUNTIME_DIR="$WORK/run" XDG_CONFIG_HOME="$CLI_HOME" \
        XDG_CACHE_HOME="$WORK/cache" XDG_DATA_HOME="$WORK/data" \
        XDG_STATE_HOME="$WORK/state" LANG=C.UTF-8 \
        python3 "$TRAY" "$@"
}
run "--version answers with the version, with no display at all" \
    0 "1.4.0" cli --version
run "--help describes the flags, with no display at all" \
    0 "--settings" cli --help
run "an unknown option is refused" 2 "unknown option" cli --nope
run "with no display the tray still explains itself" \
    1 "graphical session" cli
run "--hide-icon writes the setting and says so" 0 "SHOW_ICON=0" cli --hide-icon
cp "$CLI_HOME/rclone-onedrive-tray/config" "$WORK/cli-before"
cli --hide-icon >/dev/null 2>&1
check "the flag edits the config in place instead of rewriting it" \
    python3 - "$WORK/cli-before" "$CLI_HOME/rclone-onedrive-tray/config" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    before = fh.read()
with open(sys.argv[2], encoding="utf-8") as fh:
    after = fh.read()
gone = [line for line in before.splitlines() if line and line not in after]
if gone:
    print("lines that vanished: %r" % gone)
    raise SystemExit(1)
if 'SHOW_ICON="0"' not in after:
    print("SHOW_ICON was not written: %r" % after)
    raise SystemExit(1)
PY
run "--show-icon writes it back" 0 "SHOW_ICON=1" cli --show-icon
check "and the value is in the file" \
    grep -q '^SHOW_ICON="1"$' "$CLI_HOME/rclone-onedrive-tray/config"
# Both flags at once is a contradiction. --show-icon used to win wherever it
# sat, so "hide then show" and the other order meant the same thing.
run "given both icon flags, the last one wins: hide then show" \
    0 "SHOW_ICON=1" cli --hide-icon --show-icon
run "given both icon flags, the last one wins: show then hide" \
    0 "SHOW_ICON=0" cli --show-icon --hide-icon

title "--settings with and without a tray already running"
if run_driver cli-settings; then
    check "with no tray running it opens the window and stays up" json_py '
if not d["free_alive"]:
    print("it exited instead of showing a window: %r" % (d["free_stderr"],))
    raise SystemExit(1)
if "graphical session" in d["free_stderr"]:
    print("it refused for want of a display")
    raise SystemExit(1)
'
    check "with a tray already running it opens the window too" json_py '
if not d["held_alive"]:
    print("it exited instead of showing a window: %r" % (d["held_stderr"],))
    raise SystemExit(1)
if "already running" in d["held_stderr"]:
    print("it refused because another tray holds the lock, which is the case "
          "the flag exists for")
    raise SystemExit(1)
'
fi

summary
