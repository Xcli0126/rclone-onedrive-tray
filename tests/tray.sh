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

# The version the script carries, read out of it the way
# tests/dependency-matrix.sh does. A literal here went stale once already, and the
# next release bump would then fail this case for no reason at all.
WANT_VERSION="$(sed -n 's/^VERSION = "\([0-9.]*\)"/\1/p' "$TRAY" | head -1)"
[ -n "$WANT_VERSION" ] || bad "could not read VERSION out of bin/onedrive-tray"

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
    # A listing that fails is what remote_folders() reports as None, so one
    # marker file is all a scenario needs to ask for one.
    lsf)   [ -f "$WORK/calls/rclone-lsf-fail" ] && exit 1
           [ -f "$WORK/calls/folders" ] && cat "$WORK/calls/folders" ;;
    # A remote that takes seconds to answer. The re-authorise scenario uses this
    # to hold one sign-in in flight while a second activation arrives.
    lsd)   [ -f "$WORK/calls/slow-lsd" ] && sleep 3 ;;
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

# A second rclone, so a config that names RCLONE can be shown to use it: the
# literal "rclone" on PATH records under its own name, and the two lines in this
# file make the difference visible without reading the tray's mind.
cat > "$WORK/stubs/rclone-other" <<STUB
#!/bin/sh
printf 'rclone-other %s\n' "\$*" >> "$WORK/calls/calls"
case "\$1" in
    about) [ -f "$WORK/calls/quota-json" ] && cat "$WORK/calls/quota-json" ;;
    lsf)   [ -f "$WORK/calls/folders" ] && cat "$WORK/calls/folders" ;;
esac
exit 0
STUB

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


def scenario_folders_failed():
    """A folder listing that failed keeps the previous one.

    remote_folders() answers None when rclone cannot list the remote. Storing
    that replaced the last listing with nothing, so the submenu collapsed to one
    greyed "Loading…" row: a folder the user had unticked could not be ticked
    again until the half-hour refresh, and the menu said nothing was there.
    """
    tray = MODULE.Tray(CFG)
    # The listing the tray asks for at startup has to land before one is seeded,
    # or its answer would arrive after this one and replace it.
    wait_for(lambda: not tray.folders_busy, 8.0)
    tray.folders = ["Docs", "Music"]
    tray.folders_seen = ["Docs", "Music"]
    tray._build_folder_menu()
    pump(0.3)
    data = {"labels_before": visible_labels(tray.menu)}
    # The stub refuses every listing from here on.
    failure = os.path.join(os.environ["TRAY_CALLS"], "rclone-lsf-fail")
    with open(failure, "w", encoding="utf-8"):
        pass
    try:
        clear_calls()
        tray.refresh_folders()
        data["asked"] = wait_for(
            lambda: any("lsf" in line for line in call_lines()), 8.0)
        data["settled"] = wait_for(lambda: not tray.folders_busy, 8.0)
        pump(0.5)
        data["folders_after"] = (list(tray.folders)
                                 if tray.folders is not None else None)
        # What the poll does when the listing changed is rebuild the submenu; the
        # same call renders whatever self.folders now holds.
        tray._build_folder_menu()
        pump(0.3)
        data["labels_after"] = visible_labels(tray.menu)
    finally:
        try:
            os.remove(failure)
        except OSError:
            pass
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
    """What the settings window opens with, before anything is touched.

    The autostart control is read back twice: once with the entry the shell put
    there, and once after this scenario removes it. A fixture without the file
    could not tell "reads the file" from "always unchecked", so the mutation
    that hardwires the box off left the suite green - and on a machine where the
    entry exists, a Save then deletes it without the user touching the control.
    """
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
        "autostart_path": MODULE.AUTOSTART,
        "autostart": read_text(MODULE.AUTOSTART),
    }
    dialog.destroy()
    # The other half of the same read: with no entry the box is unchecked. The
    # file goes away here rather than in the fixture, because the scenarios after
    # this one drive the write path and need it to start from nothing.
    try:
        os.remove(MODULE.AUTOSTART)
    except OSError:
        pass
    again = MODULE.SettingsDialog(tray)
    again.show_all()
    pump(0.3)
    data["boot_without_entry"] = bool(again.check_boot.get_active())
    again.destroy()
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


def scenario_settings_bandwidth():
    """A bandwidth value the list does not offer survives a Save.

    BW_LIMIT is a free string in the config file, and rclone takes sizes the
    window's list does not hold. 1.5M is one of them: the combo had no entry for
    it, so get_active_id() returned None and any Save wrote BW_LIMIT="" over a
    limit that was working.

    values() is asked twice: once as the window really stands, and once with the
    selection cleared, which is the None get_active_id() the fallback in values()
    exists for. Appending the value is what keeps the first answer right, and the
    two together are what this asserts.
    """
    tray = MODULE.Tray(CFG)
    pump(0.3)
    dialog = MODULE.SettingsDialog(tray)
    dialog.show_all()
    pump(0.3)
    # Read what is on screen before touching it: combo_texts() selects every row
    # in turn and puts the selection back.
    shown = dialog.combo_bw.get_active_text() or ""
    data = {
        "shown": shown,
        "choices": combo_texts(dialog.combo_bw),
        "values": dialog.values(),
        "original": dialog.original["BW_LIMIT"],
    }
    dialog.combo_bw.set_active(-1)
    data["values_no_selection"] = dialog.values()
    # Put the window back the way it was before saving it.
    dialog.combo_bw.set_active_id(MODULE.bw_id(data["original"]))
    dialog.on_save()
    saved = wait_for(lambda: dialog.done or dialog.failures, 20.0)
    pump(0.5)
    data["saved"] = bool(saved and dialog.done)
    data["failures"] = dialog.failures
    data["config_after"] = read_text(MODULE.CONFIG_FILE)
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
        if case == "fail":
            # The recovery re-enabled the units through _set_units, and the poll
            # that follows has to ask systemctl again rather than reuse the
            # "disabled" it cached while the pair was paused. The cached answer
            # describes the units as they were before, and the menu then says
            # automatic sync is off for up to half a minute.
            data["settled"] = wait_for(
                lambda: getattr(tray, "auto_seen", None) in ("on", "off"), 12.0)
            pump(0.3)
            data["auto_seen_after"] = getattr(tray, "auto_seen", None)
            data["pause_label_after"] = tray.item_pause.get_label() or ""
    finally:
        MODULE.Notify = real_notify
    return data


def scenario_config_reload():
    """A running tray follows the two live settings in the config file.

    --show-icon, --hide-icon and a --settings window all live in a process that
    exits, so the file is the only way any of them can reach a tray that is
    already running. Only the settings that are meant to be live may follow it:
    this checks that the icon and the language move, and that a key belonging to
    the next sync leaves the running tray exactly where it was.
    """
    tray = build()
    pump(0.5)
    data = {
        "visible_before": bool(tray.icon_visible),
        "status_before": int(tray.ind.get_status()),
        "labels_before": visible_labels(tray.menu),
        "active": int(MODULE.AppIndicator.IndicatorStatus.ACTIVE),
        "passive": int(MODULE.AppIndicator.IndicatorStatus.PASSIVE),
    }

    # The icon goes away and the language changes, both written from outside the
    # process: this is what --hide-icon and a standalone --settings window do.
    MODULE.update_config_file(MODULE.CONFIG_FILE,
                              {"SHOW_ICON": "0", "UI_LANG": "zh"})
    data["hid"] = wait_for(lambda: not tray.icon_visible, 8.0)
    data["switched"] = wait_for(
        lambda: any("\u4e00" <= c <= "\u9fff"
                    for c in "".join(visible_labels(tray.menu))), 8.0)
    data["visible_after"] = bool(tray.icon_visible)
    data["status_after"] = int(tray.ind.get_status())
    data["labels_after"] = visible_labels(tray.menu)

    # A key that belongs to the next sync, not to the running tray. The widget is
    # remembered by identity: _build_menu() always makes new items, so the same
    # object is proof that the menu was not rebuilt for a key nothing live uses.
    item = tray.item_status
    status_text = tray.item_status.get_label() or ""
    MODULE.update_config_file(MODULE.CONFIG_FILE, {"INTERVAL_MIN": "15"})
    pump(1.0)
    data["unrelated_kept_item"] = tray.item_status is item
    data["unrelated_labels"] = visible_labels(tray.menu)
    data["unrelated_visible"] = bool(tray.icon_visible)
    data["unrelated_status_text"] = tray.item_status.get_label() or ""
    data["status_text_before"] = status_text
    data["config_text"] = read_text(MODULE.CONFIG_FILE)

    # A key the running tray reads when a run ends rather than when the window
    # opens. Applying only the two live settings left this one at its old value
    # in self.cfg, so a standalone --settings save never took effect.
    MODULE.update_config_file(MODULE.CONFIG_FILE, {"NOTIFY_ON_SUCCESS": "0"})
    data["notify_followed"] = wait_for(
        lambda: str(tray.cfg.get("NOTIFY_ON_SUCCESS")) == "0", 8.0)

    # UNIT_NAME is not one of the live settings. self.service, self.timer and
    # self.watch were resolved from it when the tray started and every poll keeps
    # asking about those, so a reload that moved the name would leave the settings
    # window writing a drop-in for a unit nothing polls. The calls below are what
    # the poll asks for; the config is what the settings window would read.
    clear_calls()
    MODULE.update_config_file(MODULE.CONFIG_FILE, {"UNIT_NAME": "zmoved"})
    pump(4.5)                      # one poll, which is where the reload happens
    data["unit_after"] = str(tray.cfg.get("UNIT_NAME") or "")
    data["unit"] = str(tray.unit)
    data["unit_calls"] = call_lines()
    return data


def scenario_config_comments():
    """A trailing comment in the config is a comment to the tray too.

    bash reads config with `.`, which drops an unquoted `#` and everything after
    it. The tray's own reader kept the comment as part of the value, so a
    hand-edited INTERVAL_MIN="15"   # every fifteen minutes showed the default 15
    in the settings dialog while the wrapper and systemd used the real number, and
    a comment after LOG or LOCAL pointed a menu item at a path with prose in it.
    A # that is not preceded by whitespace is inside the word bash is reading and
    stays, which is why `foo --tag#1` and a bare `a#b` have to survive - including
    a # that directly follows the =, because the value was already stripped of its
    whitespace before the rule was applied, and `KEY=#x` and `KEY=   #x` then look
    the same to it. bash keeps the first and empties the second.

    One deliberate divergence, and the shell side says so where it is asserted:
    bash removes the backslash from an unquoted `\\#`, and this reader keeps it.
    That is the tray's writer escaping `\\`, `"` and `$` with no reader to undo it,
    the same family as "Four parsers for one file format" in KNOWN-ISSUES.
    """
    # A table, so the shell side names what it is checking rather than indexing
    # into a list whose order nothing else depends on.
    values = {
        # Removed: a comment at the end of the line, after the closing quote or
        # after a bare word, with one or more spaces in front of the #. The last
        # one is the space-only value bash leaves empty.
        "INTERVAL_MIN": '"15" # every fifteen minutes',
        "SHOW_ICON": '1 # keep the icon',
        "BW_LIMIT": "5M\t# megabytes",
        "SPACED_EMPTY": "   # y",
        # Kept: a # inside the quotes, a # inside the word, a # in the middle of
        # a quoted value, and a # that directly follows the =.
        "MIXED": 'value#1  # comment',
        "QUOTED": '"a # b"',
        "TAGGED": 'foo --tag#1',
        "UNQUOTED": "a#b",
        "SINGLE": "'b # c'",
        "BARE": "#x",
        # Kept with its backslash, which bash would have eaten: see the docstring
        # and the check that names it.
        "ESCAPED": "x\\#y",
    }
    config = os.path.join(WORK, "comments-config")
    with open(config, "w", encoding="utf-8") as fh:
        fh.write('OPEN_APP_CMD="foo --tag#1"   # the launcher\n')
        fh.write('UNIT_NAME="a#b"\n')
        fh.write('LOCAL="%s"   # the sync folder\n' % os.path.join(WORK, "local"))
        for key, value in values.items():
            fh.write("%s=%s\n" % (key, value))

    # load_config() reads the module global, so pointing that at the file above is
    # how this scenario reads a file the rest of the suite does not share. It is
    # put back before anything else runs.
    real_config = MODULE.CONFIG_FILE
    try:
        MODULE.CONFIG_FILE = config
        cfg = MODULE.load_config()
    finally:
        MODULE.CONFIG_FILE = real_config
    return {
        "values": {key: cfg.get(key) for key in values},
        "open_app_cmd": cfg.get("OPEN_APP_CMD"),
        "unit_name": cfg.get("UNIT_NAME"),
        "local": cfg.get("LOCAL"),
        "local_want": os.path.join(WORK, "local"),
    }


def scenario_config_export():
    """`export KEY=value` names the same key as `KEY=value`.

    bash sources this file with `.`, which is how onedrive-sync and
    onedrive-doctor read it, so a hand-written `export REMOTE="onedrive:Notes"` is
    a value both of them see. Splitting the line on its first `=` alone filed it
    under the key `export REMOTE` and left REMOTE unset, so the tray refused to
    start with "REMOTE is not set ...; run setup.sh or onedrive-doctor to set it
    up" - naming two programs that read the very file the tray had just misread.
    The tray's own KEY_RE, which reads the file it writes, already allows the
    prefix.
    """
    config = os.path.join(WORK, "export-config")
    exported = os.path.join(WORK, "exported-local")
    with open(config, "w", encoding="utf-8") as fh:
        fh.write('export REMOTE="export-remote:Notes"\n')
        fh.write('  export   LOCAL="%s"\n' % exported)
        # A name that merely starts with the word is its own key, and one that
        # has the word inside it stays as it is: only a leading `export` followed
        # by whitespace is the shell's keyword.
        fh.write('exportexport=kept\n')
        fh.write('EXPORTED=1\n')

    # load_config() reads the module global, so pointing that at the file above is
    # how this scenario reads a file the rest of the suite does not share. It is
    # put back before anything else runs.
    real_config = MODULE.CONFIG_FILE
    try:
        MODULE.CONFIG_FILE = config
        cfg = MODULE.load_config()
    finally:
        MODULE.CONFIG_FILE = real_config
    return {
        "remote": cfg.get("REMOTE"),
        "local": cfg.get("LOCAL"),
        "local_want": exported,
        "prefix_is_a_key": "export REMOTE" in cfg,
        "not_a_prefix": cfg.get("exportexport"),
        "other": cfg.get("EXPORTED"),
    }


def scenario_config_reload_fresh():
    """A reload re-resolves the six paths, and a changed one rebuilds the menu.

    __init__ turns six config keys into attributes once and the rest of the class
    reads the attributes: the two menu items that open a path, the "Open {app}"
    label and its command, the exclusion list the folder submenu reads, the remote
    the quota and folder listing ask about, and the root the delete guard checks
    against. A reload that only refilled self.cfg left every one of them pointing
    at the old file while the menu and the dialog claimed the new one, so the
    folder menu read the wrong exclusion list and the delete guard checked the
    wrong root.
    """
    paths = {
        "local_old": os.path.join(WORK, "local"),
        "local_new": os.path.join(WORK, "reloaded", "local"),
        "log_old": os.path.join(WORK, "cache", "sync.log"),
        "log_new": os.path.join(WORK, "reloaded", "cache", "sync.log"),
        "exclude_old": os.path.join(WORK, "config", "rclone-onedrive-tray",
                                    "exclude-folders.txt"),
        "exclude_new": os.path.join(WORK, "reloaded", "exclude-folders.txt"),
        "old_link": os.path.join(WORK, "reloaded", "local", "link-to-old-root"),
        "open_name_old": "the old app",
        "open_name_new": "the new app",
        "remote_old": "old-remote:",
        "remote_new": "fresh-remote:",
        # What the old remote answered and what the new one will. The two listings
        # share the folders the exclusion checks below use and differ by one name
        # each way, so a listing left over from the old remote is a visible row
        # rather than a missing one.
        "listing_old": ["src", "git", "old-remote-only"],
        "listing_new": ["Docs", "git", "src"],
        "quota_old": [111, 222],
        "quota_new": [7, 8],
        "folders_file": os.path.join(WORK, "calls", "folders"),
        "quota_file": os.path.join(WORK, "calls", "quota-json"),
    }
    # The tray polls a config file whose path is a module global, so swapping that
    # global is how the file's new contents reach the reload without a second tray
    # process. Nothing else in the suite depends on the new path.
    real_config = MODULE.CONFIG_FILE
    config = os.path.join(WORK, "reloaded-config")
    os.makedirs(os.path.dirname(paths["local_new"]), exist_ok=True)
    os.makedirs(os.path.join(paths["local_new"], "ordinary", "sub"), exist_ok=True)
    os.makedirs(os.path.join(paths["local_new"], "sibling-old"), exist_ok=True)
    os.makedirs(os.path.join(paths["local_old"], "ordinary"), exist_ok=True)
    # A symlink inside the new root pointing back at the old one. Its real path is
    # outside the new root, so the guard has to refuse it - and refusing it is only
    # possible if the guard is using the reloaded root, because the old root's own
    # prefix would accept it.
    if not os.path.lexists(paths["old_link"]):
        os.symlink(paths["local_old"], paths["old_link"])
    with open(paths["exclude_new"], "w", encoding="utf-8") as fh:
        fh.write("git\n")

    # Where the two path items would open, and what launching the app would run.
    # Captured instead of opening a window or starting a program.
    opened = []
    spawned = []

    def fake_open_path(self, path, *args, **kwargs):
        opened.append(path)
        return ""

    def fake_spawn(argv):
        spawned.append(list(argv))
        return True

    real_open_path = MODULE.Tray.open_path
    real_spawn = MODULE.spawn
    real_message = MODULE.Gtk.MessageDialog
    MODULE.Tray.open_path = fake_open_path
    MODULE.spawn = fake_spawn

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

    MODULE.Gtk.MessageDialog = FakeDialog
    shown = []
    real_notify = MODULE.Notify
    MODULE.Notify = install_fake_notify(shown)

    def fresh(lang=None):
        with open(config, "w", encoding="utf-8") as fh:
            fh.write('REMOTE="%s"\n' % paths["remote_new"])
            fh.write('LOCAL="%s"\n' % paths["local_new"])
            fh.write('LOG="%s"\n' % paths["log_new"])
            fh.write('EXCLUDE_FOLDERS_FILE="%s"\n' % paths["exclude_new"])
            fh.write('OPEN_APP_CMD="/bin/true"\n')
            fh.write('OPEN_APP_NAME="%s"\n' % paths["open_name_new"])
            fh.write('UNIT_NAME="zmoved"\n')
            fh.write('SHOW_ICON="1"\n')
            if lang is not None:
                fh.write('UI_LANG="%s"\n' % lang)

    # This scenario is the one that writes a config file of its own, and writing
    # "ordinary" into the exclusion list is part of driving the delete guard. Both
    # files are put back afterwards, because the writes would otherwise leak into
    # the scenarios that run after this one. The two stub answers below are put
    # back for the same reason: the listing and the quota are the remote's answer,
    # and this scenario is about which remote they belong to.
    original_config = read_text(real_config)
    original_excludes = read_text(paths["exclude_old"])
    original_folders = read_text(paths["folders_file"])
    original_quota = read_text(paths["quota_file"])

    try:
        # The tray starts on the file it will keep polling, with the old values in
        # it. The table above says what those are, so this does not depend on what
        # the suite wrote into its own config at startup.
        with open(config, "w", encoding="utf-8") as fh:
            fh.write('REMOTE="%s"\n' % paths["remote_old"])
            fh.write('LOCAL="%s"\n' % paths["local_old"])
            fh.write('LOG="%s"\n' % paths["log_old"])
            fh.write('EXCLUDE_FOLDERS_FILE="%s"\n' % paths["exclude_old"])
            fh.write('OPEN_APP_CMD="/bin/false"\n')
            fh.write('OPEN_APP_NAME="%s"\n' % paths["open_name_old"])
            fh.write('UNIT_NAME="zmoved"\n')
            fh.write('UI_LANG="en"\n')
        MODULE.CONFIG_FILE = config
        tray = MODULE.Tray(MODULE.load_config())
        GLib.timeout_add(200, tray.poll)
        pump(0.5)
        data = {"start_local": tray.local, "start_app_cmd": tray.open_cmd}
        data["start_local_want"] = paths["local_old"]
        # The paths the shell side compares against, so the expectations are not
        # rebuilt there from a second guess at the sandbox layout.
        data.update({key: value for key, value in paths.items()
                     if key in ("local_new", "log_new", "exclude_new",
                                "open_name_old", "open_name_new")})
        # The remote is put out of the way so the assertion below is about the
        # reload rather than about what the suite's config happens to say.
        tray.remote = paths["remote_old"]

        # The listing and the quota the old remote answered. The listing is seeded
        # rather than left to the stub because both names below are on the new
        # exclusion list or not on it, which is what makes a stale exclusion list
        # a tick in the wrong place instead of a missing row. It carries a name
        # only the old remote has, so leaving it in place after the remote moves is
        # visible; the new remote's listing, written to the stub just before the
        # reload, carries a name only it has.
        wait_for(lambda: not tray.folders_busy, 8.0)
        tray.folders = list(paths["listing_old"])
        tray.folders_seen = list(paths["listing_old"])
        tray.quota = tuple(paths["quota_old"])
        with open(paths["folders_file"], "w", encoding="utf-8") as fh:
            fh.write("".join("%s/\n" % name for name in paths["listing_new"]))
        with open(paths["quota_file"], "w", encoding="utf-8") as fh:
            fh.write('{"total": %d, "used": %d}\n'
                     % (paths["quota_new"][1], paths["quota_new"][0]))
        clear_calls()

        # No UI_LANG change here on purpose: apply_settings only rebuilds the menu
        # for a language change, so the label below moves only if the code that
        # re-resolves the paths is also what rebuilds it.
        fresh()
        data["reloaded"] = wait_for(
            lambda: (tray.open_name == paths["open_name_new"]
                     and tray.local == paths["local_new"]), 8.0)

        # The folders and the quota were the old remote's answer. A reload that
        # moved REMOTE has to drop them and ask the new one, or the submenu lists
        # the old account's folders until the half-hour refresh and unticking one
        # writes that name into the exclusion file that now governs the new
        # remote, while the quota row shows the old account's usage.
        data["listing_old"] = list(paths["listing_old"])
        data["relisted"] = wait_for(
            lambda: (tray.folders is not None
                     and "Docs" in tray.folders
                     and "old-remote-only" not in tray.folders), 8.0)
        data["quota_seen"] = wait_for(
            lambda: tray.quota == tuple(paths["quota_new"]), 8.0)
        pump(0.5)
        data["folders_after"] = (list(tray.folders)
                                 if tray.folders is not None else None)
        data["quota_after"] = list(tray.quota) if tray.quota else None
        data["quota_new"] = list(paths["quota_new"])
        data["quota_asked"] = any("about %s" % paths["remote_new"]
                                  in line for line in call_lines())
        data["quota_label"] = tray.item_quota.get_label() or ""

        labels = visible_labels(tray.menu)
        data["old_label"] = "Open %s" % paths["open_name_old"]
        data["new_label"] = "Open %s" % paths["open_name_new"]
        data["old_label_gone"] = data["old_label"] not in labels
        data["new_label_there"] = data["new_label"] in labels

        data["remote"] = tray.remote
        data["log"] = tray.log
        data["exclude_file"] = tray.exclude_file

        # Activating a menu item resolves its handler the same way a right-click
        # does, so this is what the two "open" rows would really do. The app row
        # is looked up by the new label rather than assumed: when the menu was not
        # rebuilt, the old label is what is there, and that is a failure the shell
        # side reports rather than a crash here.
        find_at(tray.menu, "Open sync folder").activate()
        find_at(tray.menu, "View sync log").activate()
        try:
            app_item = find_at(tray.menu, data["new_label"])
            data["app_item_found"] = True
        except SystemExit:
            app_item = find_at(tray.menu, data["old_label"])
            data["app_item_found"] = False
        app_item.activate()
        pump(0.3)
        data["opened"] = opened
        data["spawned"] = spawned
        data["open_name"] = tray.open_name

        # The folder submenu is built from the exclusion list at build time.
        data["folder_checks"] = {}
        for item in find_at(tray.menu, "Folders to sync").get_submenu().get_children():
            label = item.get_label()
            if label and hasattr(item, "get_active"):
                data["folder_checks"][label] = bool(item.get_active())

        # The delete guard checks against the new root. A folder inside it is
        # offered, a sibling whose name merely starts with the root's is outside it
        # once reached through a symlink, and a symlink pointing at the old root
        # resolves outside the new one - which is the shape that only the reloaded
        # root refuses.
        link = os.path.join(paths["local_new"], "link-to-sibling")
        if not os.path.lexists(link):
            os.symlink(os.path.join(paths["local_new"], "sibling-old"), link)
        data["new_delete"] = tray._local_delete_path("ordinary")
        data["link_delete"] = tray._local_delete_path("link-to-old-root")
        # The offer only stands on an exclusion that really took effect, and
        # unticking a folder is the only way the handler ever reaches it.
        MODULE.write_excluded_folders(tray.exclude_file, ["ordinary", "sibling-old"])
        del shown[:]
        MODULE.Gtk.MessageDialog = FakeDialog
        del asked[:]
        tray._offer_local_delete("ordinary")
        data["asked"] = list(asked)
        data["deleted_new"] = wait_for(
            lambda: not os.path.isdir(os.path.join(paths["local_new"], "ordinary")), 8.0)
        # The notification is posted from an idle callback after the tree is gone,
        # so reading it once could land between the two: under load this case
        # failed about once in twenty runs. Wait for it the way the other cases
        # wait for a state change.
        data["told_deleted"] = wait_for(
            lambda: any("deleted" in body.lower() for body in shown), 8.0)
        data["old_kept"] = os.path.isdir(os.path.join(paths["local_old"], "ordinary"))
        data["sibling_kept"] = os.path.isdir(
            os.path.join(paths["local_new"], "sibling-old"))

        # A remote whose answers never come back still must not keep the previous
        # remote's. This is the shape that makes clearing them, rather than
        # waiting for the refresh to overwrite them, the thing that matters: a
        # listing that fails leaves self.folders alone and a quota that fails
        # leaves self.quota alone, so an answer that never arrives would otherwise
        # be an answer from the wrong account.
        third_failure = os.path.join(os.environ["TRAY_CALLS"], "rclone-lsf-fail")
        with open(third_failure, "w", encoding="utf-8"):
            pass
        try:
            os.remove(paths["quota_file"])
        except OSError:
            pass
        held = read_text(config)
        with open(config, "w", encoding="utf-8") as fh:
            fh.write('REMOTE="third-remote:"\n')
            for line in held.splitlines():
                if not line.startswith("REMOTE="):
                    fh.write(line + "\n")
        data["third_reloaded"] = wait_for(
            lambda: tray.remote == "third-remote:", 8.0)
        wait_for(lambda: not tray.folders_busy and not tray.quota_busy, 8.0)
        pump(0.5)
        data["folders_third"] = (list(tray.folders)
                                 if tray.folders is not None else None)
        data["quota_third"] = list(tray.quota) if tray.quota else None
        data["quota_third_visible"] = bool(tray.item_quota.get_visible())
        data["quota_third_label"] = tray.item_quota.get_label() or ""
        data["labels_third"] = visible_labels(tray.menu)
        try:
            os.remove(third_failure)
        except OSError:
            pass

        # A language change on top of the same file still reaches the menu, which
        # is the mechanism the rebuild above reuses.
        fresh(lang="zh")
        data["switched"] = wait_for(
            lambda: any("\u4e00" <= c <= "\u9fff"
                        for c in "".join(visible_labels(tray.menu))), 8.0)
    finally:
        MODULE.CONFIG_FILE = real_config
        MODULE.Tray.open_path = real_open_path
        MODULE.spawn = real_spawn
        MODULE.Gtk.MessageDialog = real_message
        MODULE.Notify = real_notify
        with open(real_config, "w", encoding="utf-8") as fh:
            fh.write(original_config)
        with open(paths["exclude_old"], "w", encoding="utf-8") as fh:
            fh.write(original_excludes)
        with open(paths["folders_file"], "w", encoding="utf-8") as fh:
            fh.write(original_folders)
        with open(paths["quota_file"], "w", encoding="utf-8") as fh:
            fh.write(original_quota)
    return data


def unreadable_fixture():
    """A readable config, and the trees the delete guard could be aimed at.

    Returns (config path, configured root, exclusion file, log path). The tree
    under the default LOCAL matters: ~/OneDrive is where an unreadable config used
    to move the guard's root, so there has to be something there for the guard to
    return instead of the configured root.
    """
    base = os.path.join(WORK, "unreadable")
    config = os.path.join(WORK, "unreadable-config")
    local = os.path.join(base, "local")
    exclude = os.path.join(base, "exclude-folders.txt")
    log = os.path.join(base, "sync.log")
    for path in (os.path.join(local, "Archive"),
                 os.path.join(WORK, "OneDrive", "Archive")):
        os.makedirs(path, exist_ok=True)
        with open(os.path.join(path, "keep.txt"), "w", encoding="utf-8") as fh:
            fh.write("keep\n")
    with open(config, "w", encoding="utf-8") as fh:
        fh.write('REMOTE="unreadable-remote:"\n')
        fh.write('LOCAL="%s"\n' % local)
        fh.write('UNIT_NAME="zunreadable"\n')
        fh.write('LOG="%s"\n' % log)
        fh.write('EXCLUDE_FOLDERS_FILE="%s"\n' % exclude)
        fh.write('UI_LANG="en"\n')
    return config, local, exclude, log


def scenario_config_unreadable():
    """A config that cannot be read is not a config that says "use the defaults".

    load_config() answers the defaults when the file cannot be read, and the poll
    reloads whenever the file's signature moves, including the move to "cannot be
    read". Deleting the config of a running tray therefore copied those defaults
    onto the six startup snapshots: LOCAL became ~/OneDrive, and LOCAL is the root
    the folder menu's delete guard checks, so the menu offered to delete a
    directory under ~/OneDrive while the confirmation promised the folder stays in
    OneDrive. The reload refuses such a file here, which is the same rule main()
    applies to a config with no REMOTE before it builds a tray.
    """
    config, local, exclude, log = unreadable_fixture()
    real_config = MODULE.CONFIG_FILE
    try:
        MODULE.CONFIG_FILE = config
        tray = MODULE.Tray(MODULE.load_config())
        before = {
            "local": tray.local,
            "remote": tray.remote,
            "log": tray.log,
            "exclude_file": tray.exclude_file,
            "delete": tray._local_delete_path("Archive"),
            "cfg_remote": str(tray.cfg.get("REMOTE") or ""),
            "cfg_local": str(tray.cfg.get("LOCAL") or ""),
        }
        os.remove(config)
        tray._reload_config()
        data = {
            "before": before,
            "local": tray.local,
            "remote": tray.remote,
            "log": tray.log,
            "exclude_file": tray.exclude_file,
            "delete": tray._local_delete_path("Archive"),
            "cfg_remote": str(tray.cfg.get("REMOTE") or ""),
            "cfg_local": str(tray.cfg.get("LOCAL") or ""),
            "local_want": local,
            "log_want": log,
            "exclude_want": exclude,
            "default_root": os.path.join(os.path.expanduser("~/OneDrive"), "Archive"),
        }
    finally:
        MODULE.CONFIG_FILE = real_config
    return data


def scenario_config_unreadable_poll():
    """A tick over a config that cannot be read is not news either.

    The other half of the same defect, and the reason both gates exist: poll()
    compares the file's signature against the last one it saw, and None - "the
    signature could not be read" - is unequal to every real signature, so every
    tick after the file went away treated the absence as a change and asked for a
    reload. Counting the reloads says which gate did the work; the values after it
    say the file coming back with news is still noticed.
    """
    config, local, exclude, log = unreadable_fixture()
    real_config = MODULE.CONFIG_FILE
    real_reload = MODULE.Tray._reload_config
    reloads = []

    def counted(self, *args, **kwargs):
        reloads.append(self._config_signature())
        return real_reload(self, *args, **kwargs)

    MODULE.Tray._reload_config = counted
    try:
        MODULE.CONFIG_FILE = config
        tray = MODULE.Tray(MODULE.load_config())
        GLib.timeout_add(200, tray.poll)
        pump(0.5)
        del reloads[:]              # the ticks before the file went away
        before = {
            "local": tray.local,
            "remote": tray.remote,
            "log": tray.log,
            "exclude_file": tray.exclude_file,
            "delete": tray._local_delete_path("Archive"),
        }
        os.remove(config)
        data = {"before": before, "local_want": local, "log_want": log,
                "exclude_want": exclude}
        pump(1.2)                   # several ticks with the file gone
        data["reloads"] = len(reloads)
        data["signature_now"] = tray._config_signature()
        data["local"] = tray.local
        data["remote"] = tray.remote
        data["log"] = tray.log
        data["exclude_file"] = tray.exclude_file
        data["delete"] = tray._local_delete_path("Archive")
        data["cfg_remote"] = str(tray.cfg.get("REMOTE") or "")
        # The spell has to end. A file that comes back with a different config is
        # a change like any other, so the poll has to pick it up again.
        with open(config, "w", encoding="utf-8") as fh:
            fh.write('REMOTE="restored-remote:"\n')
            fh.write('LOCAL="%s"\n' % local)
            fh.write('UNIT_NAME="zunreadable"\n')
            fh.write('LOG="%s"\n' % log)
            fh.write('EXCLUDE_FOLDERS_FILE="%s"\n' % exclude)
            fh.write('UI_LANG="en"\n')
            fh.write("PADDING=1\n")
        data["resumed"] = wait_for(
            lambda: tray.local == local and tray.remote == "restored-remote:", 8.0)
        data["reloads_after"] = len(reloads)
    finally:
        MODULE.CONFIG_FILE = real_config
        MODULE.Tray._reload_config = real_reload
    return data


def scenario_log_result():
    """The [tag] in a wrapper hint line is what the tray localises.

    onedrive-sync writes "ERROR: attempt 3/3 failed (rc=1) [network] ..." into a
    log shared with rclone, and the tray decides the icon and the notification
    text from the tail of it. The tag is the contract between the two; without a
    case here, a reworded tag or a changed regex kept the icon red and the hint
    English with nothing failing.
    """
    cfg = dict(MODULE.load_config())
    cfg["UI_LANG"] = "zh"
    cfg["LOG"] = os.path.join(WORK, "reloaded", "result.log")
    os.makedirs(os.path.dirname(cfg["LOG"]), exist_ok=True)
    # The wrapper's own format, copied from bin/onedrive-sync: log_line prefixes
    # date and time, and hint_for prints "[tag] message".
    lines = [
        "2026/10/03 22:20:58 NOTICE: delete cap MAX_DELETE=100 of about 1200 files "
        "= --max-delete 8%",
        "2026/10/03 22:21:14 ERROR : : error listing: dial tcp: i/o timeout",
        "2026/10/03 22:21:16 ERROR: attempt 3/3 failed (rc=1) [network] network "
        "problem reaching the remote, so nothing was changed; the next run will retry",
    ]
    with open(cfg["LOG"], "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    tray = MODULE.Tray(cfg)
    tail = read_text(cfg["LOG"])
    kind, when, tag, raw = MODULE.read_last_result(tail)
    cases = {"tagged": [kind, when, tag, raw, tray._hint(tag, raw)]}

    success = ("2026/10/03 22:30:00 INFO  : Bisync successful\n")
    kind, when, tag, raw = MODULE.read_last_result(success)
    cases["synced"] = [kind, when, tag, raw, tray._hint(tag, raw)]

    plain = ("2026/10/03 22:40:00 ERROR : Bisync aborted. Must run --resync to "
             "recover.\n")
    kind, when, tag, raw = MODULE.read_last_result(plain)
    cases["untagged"] = [kind, when, tag, raw, tray._hint(tag, raw)]

    # The same three lines as this tray sees them through poll(), not only through
    # the parser: the icon and the notification come from _apply_state, and the
    # log is read behind a size/mtime cache. The timer answer is the stub's own,
    # so what the state machine is handed is what a tick hands it.
    real_notify = MODULE.Notify
    MODULE.Notify = install_fake_notify([])
    try:
        _, timer_state = tray.unit_states()
        tray.was_syncing = True
        tray.notified_error_at = None
        tray.state = None
        tray._apply_state(False, timer_state)
        cases["state"] = tray.state
        cases["status"] = tray.item_status.get_label() or ""
    finally:
        MODULE.Notify = real_notify
    return cases


def scenario_log_cache_moved():
    """A reload that moves LOG drops the cached tail rather than reusing it.

    _log_snapshot() decides whether to re-read the log from its size and mtime
    alone, which is what keeps an idle tick cheap. A reload that moves LOG to a
    file matching the old one's pair, which is what a `cp -p` of a log leaves
    behind, was therefore read as unchanged: the status line went on describing
    the file the tray had been reading while the menu, the settings window and
    the poll all pointed at the new one. The second file is written to the same
    byte length and given the first one's timestamp on purpose, because that
    collision is the whole of the bug.
    """
    old = os.path.join(WORK, "cache", "moved-from.log")
    new = os.path.join(WORK, "moved", "moved-to.log")
    os.makedirs(os.path.dirname(new), exist_ok=True)
    failure = "2026/10/01 10:00:00 ERROR: [network] no such host\n"
    success = "2026/10/01 11:00:00 INFO  : Bisync successful"
    success = success + " " * (len(failure) - len(success) - 1) + "\n"
    with open(old, "w", encoding="utf-8") as fh:
        fh.write(failure)
    with open(new, "w", encoding="utf-8") as fh:
        fh.write(success)
    info = os.stat(old)
    os.utime(new, ns=(info.st_atime_ns, info.st_mtime_ns))

    cfg = dict(MODULE.load_config())
    cfg["LOG"] = old
    tray = MODULE.Tray(cfg)
    tray._log_snapshot()          # the tick that caches the old file
    data = {"before": list(tray.log_result),
            "same_pair": (os.stat(new).st_size == info.st_size
                          and os.stat(new).st_mtime_ns == info.st_mtime_ns)}

    # The reload the poll performs when the config file's signature moves, on a
    # file whose only change is LOG. Nothing else in the config moves, so the log
    # cache is the only thing this can be measuring.
    real_config = MODULE.CONFIG_FILE
    config = os.path.join(WORK, "moved-log-config")
    with open(config, "w", encoding="utf-8") as fh:
        fh.write('REMOTE="%s"\n' % (cfg.get("REMOTE") or ""))
        fh.write('LOCAL="%s"\n' % cfg["LOCAL"])
        fh.write('LOG="%s"\n' % new)
        fh.write('UI_LANG="en"\nSHOW_ICON="1"\n')
    try:
        MODULE.CONFIG_FILE = config
        tray._reload_config()
    finally:
        MODULE.CONFIG_FILE = real_config
    tray._log_snapshot()
    data["after"] = list(tray.log_result)
    data["want"] = list(MODULE.read_last_result(success))
    return data


def scenario_pause_survives_poll():
    """A pause the tray arranged survives the poll that follows it.

    The enabled answer is cached to save a fork per tick, and the tray itself
    disables the units when it pauses. Reusing the answer from before the pause
    reported automatic sync as on three seconds later, which deleted the pause
    stamp and left the menu saying sync was off.
    """
    tray = build()
    wait_for(lambda: getattr(tray, "auto_seen", None) == "on", 8.0)
    # What pause_for() leaves behind: the units disabled, which the stub answers
    # from this marker, and an is-active that stays unhappy either way.
    with open(os.path.join(os.environ["TRAY_CALLS"], "timer-disabled"), "w"):
        pass
    clear_calls()
    tray.pause_for(30)
    stamped = wait_for(lambda: os.path.exists(MODULE.PAUSE_STAMP), 8.0)
    pump(7.0)                      # two polls, with no run in between
    return {"stamped": stamped,
            "stamp_left": os.path.exists(MODULE.PAUSE_STAMP),
            "auto_seen": getattr(tray, "auto_seen", None),
            "pause_label": tray.item_pause.get_label() or ""}


def scenario_manual_missed():
    """A manual run the poll never saw does not mark the next scheduled success.

    on_sync_now asks systemd to start the service and the poll notices the run
    ending. A run that starts and finishes between two ticks is never noticed, so
    the request has to expire by itself; otherwise the next scheduled success was
    announced as one the user had started.
    """
    tray = build()
    shown = []
    real_notify = MODULE.Notify
    MODULE.Notify = install_fake_notify(shown)
    try:
        tray.manual_requested = True
        tray.manual_seen_syncing = False
        tray.manual_ticks = 0
        tray._announce_finish(False, "ok", "14:00", "")
        tray._announce_finish(False, "ok", "14:00", "")
        data = {"forgotten": not tray.manual_requested, "notices": list(shown)}
        # The scheduled run that follows must stay quiet.
        tray.was_syncing = True
        tray._announce_finish(False, "ok", "14:05", "")
        data["notices_after"] = list(shown)

        # The other side of the same coin: while the start is still in flight
        # nothing may be counted, because systemd has been asked and the run has
        # simply not appeared yet. Expiring the request here would forget a run
        # that is slow to come up, and its success would then be announced as
        # somebody else's.
        tray.was_syncing = False
        tray.busy = True
        tray.manual_requested = True
        tray.manual_seen_syncing = False
        tray.manual_ticks = 0
        for _ in range(3):
            tray._announce_finish(False, "ok", "14:10", "")
        data["kept_while_busy"] = bool(tray.manual_requested)
        tray.busy = False
    finally:
        MODULE.Notify = real_notify
    return data


def scenario_poll_cost():
    """What one idle tick pays for.

    The tick used to fork systemctl twice and re-read 64 KB of log every three
    seconds whether or not either had changed. Both are counted here by wrapping
    the calls the tray makes, so the assertions are about what the tray asked for
    rather than about a wall clock. The log is this scenario's own file, so what
    is measured is an idle tray rather than one sharing the suite's log.
    """
    counts = {"apply": 0, "tail": 0, "parse": 0}
    real_tail = MODULE.tail_text
    real_parse = MODULE.read_last_result
    real_apply = MODULE.Tray._apply_state

    def tail(path, *args, **kwargs):
        counts["tail"] += 1
        return real_tail(path, *args, **kwargs)

    def parse(text):
        counts["parse"] += 1
        return real_parse(text)

    def apply_state(self, syncing, timer_state, generation=None):
        counts["apply"] += 1
        return real_apply(self, syncing, timer_state, generation)

    cfg = dict(CFG)
    cfg["LOG"] = os.path.join(os.path.dirname(cfg["LOG"]), "poll-cost.log")
    with open(cfg["LOG"], "w", encoding="utf-8") as fh:
        fh.write("%s INFO  : Bisync successful\n"
                 % time.strftime("%Y/%m/%d %H:%M:%S"))

    MODULE.tail_text = tail
    MODULE.read_last_result = parse
    MODULE.Tray._apply_state = apply_state
    try:
        clear_calls()
        tray = MODULE.Tray(cfg)
        GLib.timeout_add(200, tray.poll)
        pump(0.5)                    # the first read of the log lands here
        base = dict(counts)
        pump(4.0)                    # the log does not change
        idle = {key: counts[key] - base[key] for key in counts}
        calls = call_lines()
        # Now the log grows, so the next tick has to notice.
        seen = counts["tail"]
        with open(cfg["LOG"], "a", encoding="utf-8") as fh:
            fh.write("%s INFO  : Transferred:   \t1 B / 1 B, 100%%, 1 B/s, "
                     "ETA 0s\n" % time.strftime("%Y/%m/%d %H:%M:%S"))
        reread = wait_for(lambda: counts["tail"] > seen, 8.0)
    finally:
        MODULE.tail_text = real_tail
        MODULE.read_last_result = real_parse
        MODULE.Tray._apply_state = real_apply
    return {
        "applies": idle["apply"],
        "log_reads": idle["tail"],
        "log_parses": idle["parse"],
        "reread_on_change": reread,
        "active_asks": sum(1 for line in calls
                           if "is-active ztraytest.service ztraytest.timer" in line),
        "enabled_asks": sum(1 for line in calls
                            if "is-enabled ztraytest.timer" in line),
        "calls": calls,
    }


def scenario_notify_manual():
    """A failed manual run must not make the next scheduled success announce itself.

    manual_requested is what tells a success the user asked for from one the
    timer ran. It used to be cleared only on the success path, so a manual run
    that failed stayed marked as manual for the life of the process and the next
    scheduled success was announced as if the user had started it.
    """
    shown = []
    cfg = dict(CFG)
    cfg["NOTIFY_ON_SUCCESS"] = "1"
    log = os.path.join(os.path.dirname(cfg["LOG"]), "manual-notify.log")
    cfg["LOG"] = log
    real = MODULE.Notify
    MODULE.Notify = install_fake_notify(shown)
    try:
        tray = MODULE.Tray(cfg)
        pump(0.3)

        def run(text, manual):
            del shown[:]
            with open(log, "w", encoding="utf-8") as fh:
                fh.write(text)
            tray.state = None
            tray.was_syncing = True
            if manual:
                tray.manual_requested = True
            tray._apply_state(False, "enabled")
            pump(0.3)
            return list(shown)

        failed = run("2026/01/02 03:05:05 ERROR : [network] remote unreachable\n",
                     True)
        # The next run is the timer's. Nothing marks it manual here, because the
        # tray has to have cleared the flag when the failed run ended.
        scheduled = run("2026/01/02 03:06:06 INFO  : Bisync successful\n", False)
        manual = run("2026/01/02 03:07:07 INFO  : Bisync successful\n", True)
    finally:
        MODULE.Notify = real
    return {"failed_bodies": failed, "scheduled_bodies": scheduled,
            "manual_bodies": manual}


def scenario_no_remote():
    """A config with no REMOTE gets one sentence, not a traceback.

    A hand-edited config can have REMOTE commented out, and a tray started from
    the autostart entry has no terminal to show a traceback in. This runs the real
    main() against a config that has REMOTE commented out and reports what it
    said and how it exited.
    """
    import subprocess

    home = os.environ["TRAY_NO_REMOTE_HOME"]
    os.makedirs(os.path.join(home, "rclone-onedrive-tray"), exist_ok=True)
    path = os.path.join(home, "rclone-onedrive-tray", "config")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# REMOTE is commented out.\n"
                 '#REMOTE="traytest-remote:"\n'
                 'LOCAL="%s"\n' % os.path.join(WORK, "local"))
    env = dict(os.environ)
    env["XDG_CONFIG_HOME"] = home
    proc = subprocess.run([sys.executable, sys.argv[2]], capture_output=True,
                          text=True, timeout=120, env=env)
    return {"exit_code": proc.returncode, "stdout": proc.stdout,
            "stderr": proc.stderr, "config_file": path}


def scenario_diagnostics():
    """Diagnostics… runs onedrive-doctor and shows what it printed.

    The README tells a user to run this first when something looks wrong, and the
    point of the tray is not needing a terminal. The wiring is what this checks:
    that the tray asks for the doctor, hands its output to the dialog, and uses the
    diagnostics wording rather than the name check's.
    """
    tray = build()
    asked = []
    shown = []
    real_sibling = MODULE.sibling_script
    real_run = MODULE.run_script
    real_show = MODULE.Tray._show_check
    MODULE.sibling_script = lambda name: (asked.append(name) or "/stub/onedrive-doctor")
    MODULE.run_script = lambda cmd, timeout=900: (
        True, "ok   rclone    1.75 at /usr/local/bin/rclone\n"
              "warn log       the newest failure hint is a network problem\n")

    def capture(self, report, clean, title=None, blurb=None):
        shown.append({"report": report, "clean": clean, "title": title,
                      "blurb": blurb})
        return False

    MODULE.Tray._show_check = capture
    try:
        tray._diagnose()
        data = {"ran": wait_for(lambda: bool(shown), 8.0), "asked": asked,
                "shown": shown}
    finally:
        MODULE.sibling_script = real_sibling
        MODULE.run_script = real_run
        MODULE.Tray._show_check = real_show
    return data


def scenario_rclone_binary():
    """A config that names an rclone binary sends all four queries to it.

    RCLONE exists so a build outside PATH can be used, and onedrive-sync,
    onedrive-check-access and onedrive-doctor all honour it. The tray ran the
    literal "rclone" in every query it makes, so the quota row, the folder
    submenu and the sign-in could describe a different binary's remote than the
    one that actually syncs.
    """
    cfg = dict(CFG)
    cfg["RCLONE"] = os.path.join(WORK, "stubs", "rclone-other")
    clear_calls()
    tray = MODULE.Tray(cfg)
    GLib.timeout_add(200, tray.poll)
    wait_for(lambda: any("rclone-other" in line for line in call_lines()), 8.0)
    pump(0.5)
    shown = []
    asked = {}
    real_notify = MODULE.Notify
    real_dialog = MODULE.Gtk.MessageDialog
    MODULE.Notify = install_fake_notify(shown)
    MODULE.Gtk.MessageDialog = fake_message_dialog(
        asked, MODULE.Gtk.ResponseType.OK)
    try:
        find_at(tray.menu, "Re-authorise OneDrive…").activate()
        reconnect = wait_for(
            lambda: any("config reconnect" in line for line in call_lines()), 8.0)
        listed = wait_for(
            lambda: any(" lsd " in line for line in call_lines()), 8.0)
    finally:
        MODULE.Notify = real_notify
        MODULE.Gtk.MessageDialog = real_dialog
    pump(0.3)
    data = {"binary": getattr(tray, "rclone", ""),
            "calls": call_lines()}
    # A reload that moves RCLONE has to move with it, the same way the other
    # startup snapshots do. The config file is a module global, so a private one
    # is the whole fixture.
    moved = os.path.join(WORK, "rclone-moved-config")
    with open(moved, "w", encoding="utf-8") as fh:
        fh.write('REMOTE="%s"\n' % tray.remote)
        fh.write('LOCAL="%s"\n' % tray.local)
        fh.write('LOG="%s"\n' % tray.log)
        fh.write('EXCLUDE_FOLDERS_FILE="%s"\n' % tray.exclude_file)
        fh.write('OPEN_APP_CMD=""\n')
        fh.write('OPEN_APP_NAME="%s"\n' % tray.open_name)
        fh.write('RCLONE="%s"\n' % os.path.join(WORK, "stubs", "rclone-third"))
    real_config = MODULE.CONFIG_FILE
    MODULE.CONFIG_FILE = moved
    try:
        tray._reload_config()
    finally:
        MODULE.CONFIG_FILE = real_config
    data["binary_after_reload"] = getattr(tray, "rclone", "")
    return data


def scenario_bad_bytes():
    """A config that is not UTF-8 is a sentence, not a traceback.

    load_config() caught OSError only, so one bad byte raised
    UnicodeDecodeError out of main(): the tray died with a traceback in a
    process whose autostart entry has Terminal=false, while the shell half kept
    syncing the same file happily. A value that holds the byte is refused rather
    than repaired, because LOCAL is a path.
    """
    import subprocess

    home = os.environ["TRAY_BAD_BYTES_HOME"]
    os.makedirs(os.path.join(home, "rclone-onedrive-tray"), exist_ok=True)
    path = os.path.join(home, "rclone-onedrive-tray", "config")
    env = dict(os.environ)
    env["XDG_CONFIG_HOME"] = home
    local = os.path.join(WORK, "local")

    def run_main(raw):
        with open(path, "wb") as fh:
            fh.write(raw)
        proc = subprocess.run([sys.executable, sys.argv[2]],
                              capture_output=True, text=True, timeout=120, env=env)
        return {"exit_code": proc.returncode, "stdout": proc.stdout,
                "stderr": proc.stderr}

    prefix = ('REMOTE="traytest-remote:"\nLOCAL="%s"\n' % local).encode("utf-8")
    in_comment = run_main(prefix + b"# a caf\xe9 folder\n")
    # The same byte inside a value, which is the half that must not be guessed
    # at: LOCAL is the root the delete guard checks.
    in_value = run_main(b'REMOTE="traytest-remote:"\nLOCAL="'
                        + os.path.join(WORK, "caf").encode("utf-8")
                        + b'\xe9"\n')
    data = {"config_file": path, "in_comment": in_comment, "in_value": in_value}

    # And a running tray that meets the same file keeps what it has rather than
    # dying inside the reload its own poll asked for.
    tray = MODULE.Tray(CFG)
    pump(0.3)
    held_local = tray.local
    real_config = MODULE.CONFIG_FILE
    MODULE.CONFIG_FILE = path
    try:
        crashed = ""
        try:
            tray._reload_config()
        except Exception as exc:                    # noqa: BLE001
            crashed = "%s: %s" % (type(exc).__name__, exc)
    finally:
        MODULE.CONFIG_FILE = real_config
    data["reload_crashed"] = crashed
    data["reload_kept_local"] = (tray.local == held_local)
    return data


def scenario_sync_fail():
    """A start systemd refuses is reported, and the wrapper runs instead.

    _start_service and _run dropped the (rc, out, err) that systemctl answered
    with, so a refused start still left "Syncing…" on screen over a run that
    never began: no error, no status change and no retry. The wrapper is the
    same sync without the scheduler, which is what the resync item already
    relies on.

    systemctl is replaced here rather than stubbed by a file, so the direct run
    the fallback makes is recorded rather than executed.
    """
    case = os.environ.get("TRAY_SYNC_FAIL", "fallback")
    tray = build()
    pump(0.5)
    calls = []
    real_sh = MODULE.sh

    def failing(cmd, timeout=30):
        calls.append(cmd)
        if cmd.startswith("systemctl --user start"):
            return 1, "", "mock systemctl failure: the unit could not be started"
        if "onedrive-sync" in cmd:
            if case == "both":
                return 1, "", ""
            return 0, "", ""
        return real_sh(cmd, timeout=timeout)

    shown = []
    real_notify = MODULE.Notify
    MODULE.sh = failing
    MODULE.Notify = install_fake_notify(shown)
    try:
        find_at(tray.menu, "Sync now").activate()
        told = wait_for(
            lambda: any("mock systemctl failure" in body for body in shown), 8.0)
        # The status row is the other half: it may not go on claiming a run.
        settled = wait_for(
            lambda: "mock systemctl failure" in (tray.item_status.get_label() or ""),
            8.0)
        pump(0.5)
        data = {"told": told, "settled": settled, "notices": list(shown),
                "status": tray.item_status.get_label() or "",
                "busy": bool(tray.busy),
                "manual": bool(tray.manual_requested),
                "starts": [c for c in calls if c.startswith("systemctl --user start")],
                "direct": [c for c in calls if "onedrive-sync" in c]}
        # The folder toggle's own start shares the silence, and shares the fix.
        del shown[:]
        del calls[:]
        tray._start_service()
        pump(0.8)
        data["service_notices"] = list(shown)
        data["service_direct"] = [c for c in calls if "onedrive-sync" in c]
    finally:
        MODULE.sh = real_sh
        MODULE.Notify = real_notify
    return data


def scenario_folders_unlisted():
    """A remote that has never listed says so, and offers the retry now.

    Until a listing succeeded, self.folders stayed None and the submenu held one
    greyed "Loading…" row. A tray started offline, with an expired sign-in, or
    against the wrong REMOTE therefore said "Loading…" for up to half an hour:
    the selective-sync feature was unusable and the label was wrong. The quota
    row already hides itself in the same state.
    """
    failure = os.path.join(os.environ["TRAY_CALLS"], "rclone-lsf-fail")
    with open(failure, "w", encoding="utf-8"):
        pass
    try:
        clear_calls()
        tray = build()
        wait_for(lambda: not tray.folders_busy, 8.0)
        pump(0.8)
        data = {"folders": (list(tray.folders) if tray.folders is not None else None),
                "labels": visible_labels(tray.menu),
                "remote": tray.remote}
        sub = find_at(tray.menu, "Folders to sync").get_submenu()
        retry = [item for item in sub.get_children()
                 if item.get_label() and "try again" in item.get_label()]
        data["retry_label"] = retry[0].get_label() if retry else ""
        data["retry_sensitive"] = bool(retry[0].get_sensitive()) if retry else False
        # The row has to be a way out: clicking it asks again, and this time the
        # remote answers, so the folders arrive without the 1800-second timer.
        os.remove(failure)
        with open(os.path.join(os.environ["TRAY_CALLS"], "folders"), "w",
                  encoding="utf-8") as fh:
            fh.write("Docs/\nMusic/\n")
        clear_calls()
        if retry:
            retry[0].activate()
        data["asked_again"] = wait_for(
            lambda: any("lsf" in line for line in call_lines()), 8.0)
        data["retried"] = wait_for(
            lambda: tray.folders == ["Docs", "Music"], 8.0)
        pump(0.5)
        data["labels_after"] = visible_labels(tray.menu)
    finally:
        try:
            os.remove(failure)
        except OSError:
            pass
    return data


def scenario_settings_enabled():
    """A yes/no value spelled "enabled" is on, and a Save leaves it alone.

    onedrive-sync accepts 1|true|yes|on|enabled for CHECK_ACCESS and the doctor
    the same set for WATCH, while the tray's truthy() knew four of the five. The
    wrapper therefore turned the access check on while the window drew it
    unchecked, and a Save wrote 0 over it, dropping the one guard that stops a
    run treating an unreadable side as mass deletion.
    """
    tray = MODULE.Tray(CFG)
    pump(0.3)
    dialog = MODULE.SettingsDialog(tray)
    dialog.show_all()
    pump(0.3)
    before = read_text(MODULE.CONFIG_FILE)
    data = {"access": bool(dialog.check_access.get_active()),
            "watch": bool(dialog.check_watch.get_active()),
            "values": dialog.values(),
            "original": {key: dialog.original[key]
                         for key in ("WATCH", "CHECK_ACCESS")},
            "config_before": before}
    # Nothing is touched: a Save here is the "the user opened the window and
    # closed it again" case, which must not rewrite the file.
    dialog.on_save()
    saved = wait_for(lambda: dialog.done or dialog.failures, 20.0)
    pump(0.5)
    data["saved"] = bool(saved and dialog.done)
    data["failures"] = dialog.failures
    data["config_after"] = read_text(MODULE.CONFIG_FILE)
    dialog.destroy()
    return data


# The child half of scenario_lock_race(). It does what acquire_lock() does, in
# the one ordering no API can be asked to produce on request: the open happens
# before the other tray releases, and the flock happens after. fcntl.flock is the
# only place that ordering can be held still, so the hook parks there.
LOCK_RACE_CHILD = r'''
import fcntl
import importlib.machinery
import importlib.util
import json
import os
import sys
import time

sys.dont_write_bytecode = True

tray_path, work = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("tray_lock_child", tray_path)
spec = importlib.util.spec_from_loader("tray_lock_child", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


def marker(name):
    return os.path.join(work, name)


calls = []
real_flock = fcntl.flock


def parked_flock(handle, op):
    calls.append(op)
    if len(calls) == 1:
        # The path has been opened and this process is about to flock it. Hold
        # here until the other tray has released and unlinked the file, which is
        # the window the defect lives in.
        open(marker("b-parked"), "w").close()
        deadline = time.time() + 20.0
        while not os.path.exists(marker("a-released")):
            if time.time() > deadline:
                break
            time.sleep(0.005)
    return real_flock(handle, op)


module.fcntl.flock = parked_flock
lock = module.acquire_lock()
with open(marker("b-result"), "w", encoding="utf-8") as fh:
    json.dump({"acquired": lock is not None, "flock_calls": len(calls)}, fh)
# Hold whatever was taken until the other process has tried. Leaving is what a
# tray that quits does, and it drops the flock.
deadline = time.time() + 20.0
while not os.path.exists(marker("p-tried")):
    if time.time() > deadline:
        break
    time.sleep(0.005)
'''


def scenario_stale_state():
    """An answer computed before a pause must not delete the pause.

    unit_states() runs in a worker, so its answer can land after the tray has
    paused the units itself. The answer still says "enabled", _auto_state() reads
    that as automatic sync being on, and the pause stamp goes with it: the row
    then says sync is on for up to ENABLED_EVERY ticks and "Automatic sync is
    off" for the rest of the pause, and recover_pause() has nothing to restore
    after a restart. The answer is held back until the pause has landed, which is
    the ordering the reviewer reproduced; the control run, with nothing held
    back, is the pause-survives-poll scenario above.
    """
    import threading

    tray = build()
    started = threading.Event()
    release = threading.Event()

    def held():
        if not started.is_set():
            # What the units said before the pause: enabled, nothing active.
            started.set()
            release.wait(10.0)
            return False, "enabled"
        # Every later poll sees the units as pause_for() left them.
        return False, "off"

    real_states = tray.unit_states
    tray.unit_states = held
    try:
        parked = wait_for(started.is_set, 12.0)
        with open(os.path.join(os.environ["TRAY_CALLS"], "timer-disabled"), "w"):
            pass
        # A clean slate for the stamp: the pause-survives-poll scenario before
        # this one leaves its own behind, and a stamp that is already there would
        # make the wait below return before pause_for() has written anything.
        try:
            os.remove(MODULE.PAUSE_STAMP)
        except OSError:
            pass
        tray.pause_for(30)
        stamped = wait_for(lambda: os.path.exists(MODULE.PAUSE_STAMP), 8.0)
        # The stale answer lands now, and the polls after it are the window it
        # used to poison.
        release.set()
        pump(7.0)
        return {"parked": parked,
                "stamped": stamped,
                "stamp_left": os.path.exists(MODULE.PAUSE_STAMP),
                "auto_seen": getattr(tray, "auto_seen", None),
                "pause_label": tray.item_pause.get_label() or "",
                "timer_state": getattr(tray, "timer_state", None)}
    finally:
        tray.unit_states = real_states
        release.set()
        try:
            os.remove(os.path.join(os.environ["TRAY_CALLS"], "timer-disabled"))
        except OSError:
            pass


def scenario_stale_state_cache():
    """A stale answer must not become the cache the next tick reuses either.

    Clearing the cache in _units_changed() does nothing about the answer a worker
    has already been handed, and unit_states() writes that answer into the cache
    itself. Dropping it in _apply_state() keeps it off the screen; this is the
    other half, where the next tick reads it back as though the units had not
    moved. sh is replaced here so the pause lands in the middle of the ask, which
    is the ordering a slow systemctl produces on its own.
    """
    tray = build()
    wait_for(lambda: not tray.state_busy, 8.0)
    tray.timer_state = None
    state = {"bumped": False}
    real_sh = MODULE.sh

    def fake_sh(cmd, timeout=30):
        if "is-active" in cmd and not state["bumped"]:
            # The tray pauses while systemctl is being asked: the answer this
            # call is about to produce describes the units as they were.
            state["bumped"] = True
            tray._units_changed()
            return 0, "inactive\n", ""
        if "is-enabled" in cmd:
            return 0, "enabled\n", ""
        return real_sh(cmd, timeout=timeout)

    MODULE.sh = fake_sh
    try:
        active, timer = tray.unit_states()
    finally:
        MODULE.sh = real_sh
    return {"bumped": state["bumped"], "active": active, "timer": timer,
            "cached": getattr(tray, "timer_state", None)}


def scenario_reauth_twice():
    """A second activation while a sign-in is in flight starts nothing.

    rclone's config file has no cross-process locking, so two concurrent
    `rclone config reconnect` runs are last-writer-wins over the same remote's
    credentials, and the first one to finish fires "Signed in. Syncing now."
    while the other terminal is still open. A slow `rclone lsd` is what keeps the
    first flow in flight long enough for the second activation to arrive.
    """
    tray = build()
    clear_calls()
    slow = os.path.join(os.environ["TRAY_CALLS"], "slow-lsd")
    with open(slow, "w"):
        pass
    asked = {}
    real = MODULE.Gtk.MessageDialog
    MODULE.Gtk.MessageDialog = fake_message_dialog(
        asked, MODULE.Gtk.ResponseType.OK)
    item = find_at(tray.menu, "Re-authorise OneDrive…")
    try:
        item.activate()
        parked = wait_for(
            lambda: any(line.startswith("terminal ")
                        and "config reconnect" in line for line in call_lines()),
            8.0)
        data = {"parked": parked,
                "busy_while_busy": bool(getattr(tray, "reauth_busy", False)),
                "insensitive_while_busy": not item.get_sensitive()}
        # The row, which GTK refuses to activate while it is insensitive, and the
        # handler directly, so that the flag is what has to stop the second flow.
        item.activate()
        tray.on_reauth()
        pump(0.5)
        data["spawns"] = sum(
            1 for line in call_lines()
            if line.startswith("terminal ") and "config reconnect" in line)
        data["lsd_calls"] = sum(1 for line in call_lines() if " lsd " in line)
        # The flow ends when the slow listing answers.
        data["finished"] = wait_for(
            lambda: not getattr(tray, "reauth_busy", True), 15.0)
        data["busy_after"] = bool(getattr(tray, "reauth_busy", False))
        data["sensitive_after"] = item.get_sensitive()
    finally:
        MODULE.Gtk.MessageDialog = real
        try:
            os.remove(slow)
        except OSError:
            pass
    return data


def scenario_lock_inode():
    """release_lock() removes only the file it locked, and a second take works.

    os.remove(LOCK_FILE) was unconditional, so a tray on its way out deleted
    whatever was at the path, including a lock another process had just created
    and was holding. The path is replaced by a different inode here, which is
    what a second tray creates when it takes the lock at the same moment.
    """
    first = MODULE.acquire_lock()
    data = {"first": first is not None}
    if first is None:
        return data
    try:
        os.remove(MODULE.LOCK_FILE)
        with open(MODULE.LOCK_FILE, "w", encoding="utf-8") as fh:
            fh.write("another lock\n")
        MODULE.release_lock(first)
        data["path_kept"] = os.path.exists(MODULE.LOCK_FILE)
        data["content"] = read_text(MODULE.LOCK_FILE)
    finally:
        try:
            os.remove(MODULE.LOCK_FILE)
        except OSError:
            pass
    second = MODULE.acquire_lock()
    data["second"] = second is not None
    if second is not None:
        MODULE.release_lock(second)
    data["removed_after_release"] = not os.path.exists(MODULE.LOCK_FILE)
    return data


def scenario_lock_race():
    """A lock taken while another tray releases it is not a second lock.

    acquire_lock() opens the path and then flocks it. A process that opens before
    the release unlinks and flocks after the release closes holds an unlinked
    inode: the next process creates a fresh file and locks that one, and two
    trays run at once. The interleave is forced by LOCK_RACE_CHILD, whose flock
    is the point the release lands on - the ordering the reviewer measured 29
    times in 419 acquisitions.
    """
    import subprocess

    work = os.path.dirname(os.environ["TRAY_RECORDS"])
    child_path = os.path.join(work, "lock-race-child.py")
    with open(child_path, "w", encoding="utf-8") as fh:
        fh.write(LOCK_RACE_CHILD)
    for name in ("b-parked", "b-result", "a-released", "p-tried"):
        try:
            os.remove(os.path.join(work, name))
        except OSError:
            pass

    holder = MODULE.acquire_lock()
    if holder is None:
        return {"holder": False}
    child = subprocess.Popen([sys.executable, child_path, sys.argv[2], work],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, cwd=work)
    try:
        parked = wait_for(
            lambda: os.path.exists(os.path.join(work, "b-parked")), 20.0)
        # The one release, with the child parked between its open and its flock.
        MODULE.release_lock(holder)
        with open(os.path.join(work, "a-released"), "w"):
            pass
        # Wait for the child to settle before asking, so which of the two takes
        # the lock is decided by the protocol and not by this timing.
        settled = wait_for(
            lambda: os.path.exists(os.path.join(work, "b-result")), 20.0)
        second = MODULE.acquire_lock()
        with open(os.path.join(work, "p-tried"), "w"):
            pass
    finally:
        try:
            child.wait(timeout=30)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    try:
        child_result = json.loads(
            read_text(os.path.join(work, "b-result")) or "{}")
    except ValueError:
        child_result = {}
    data = {"holder": True, "parked": parked, "settled": settled,
            "child_acquired": bool(child_result.get("acquired")),
            "child_flock_calls": child_result.get("flock_calls", 0),
            "second_acquired": second is not None}
    if second is not None:
        MODULE.release_lock(second)
    return data


def scenario_relative_local():
    """A LOCAL that is not absolute is refused, by main() and by the guard.

    setup.sh writes LOCAL verbatim and a hand edit can leave it relative. The
    delete guard then resolves it against the tray process's own working
    directory - not the directory rclone syncs - so isdir, realpath and the
    prefix check all pass against a tree that has nothing to do with the sync
    pair, and the confirmation names only the folder.
    """
    import subprocess

    home = os.environ["TRAY_RELATIVE_LOCAL_HOME"]
    os.makedirs(os.path.join(home, "rclone-onedrive-tray"), exist_ok=True)
    config = os.path.join(home, "rclone-onedrive-tray", "config")
    with open(config, "w", encoding="utf-8") as fh:
        fh.write('REMOTE="traytest-remote:"\n'
                 'LOCAL="OneDrive"\n'
                 'UNIT_NAME="ztraytest"\n'
                 'UI_LANG="en"\n')

    # The sentence main() uses, called the way main() calls it. getattr, so that
    # an older tray answers "" here rather than taking the scenario down.
    check = getattr(MODULE, "local_path_problem", None)
    data = {"problem": check("OneDrive") if check else ""}

    # The guard, run from a directory where a same-named decoy exists: with a
    # relative LOCAL this is the path it used to hand to shutil.rmtree.
    decoy = os.path.join(WORK, "relative-local-decoy")
    os.makedirs(os.path.join(decoy, "OneDrive", "Documents"), exist_ok=True)

    class Bare:
        local = "OneDrive"

    here = os.getcwd()
    try:
        os.chdir(decoy)
        data["guard"] = MODULE.Tray._local_delete_path(Bare(), "Documents")
        data["decoy_path"] = os.path.join(os.path.realpath(decoy), "OneDrive",
                                          "Documents")
    finally:
        os.chdir(here)

    # And the real main(), which has to refuse before it builds a window.
    env = dict(os.environ)
    env["XDG_CONFIG_HOME"] = home
    try:
        proc = subprocess.run([sys.executable, sys.argv[2]], env=env,
                              capture_output=True, text=True, timeout=25)
        data.update({"refused": True, "exit_code": proc.returncode,
                     "stderr": proc.stderr})
    except subprocess.TimeoutExpired as exc:
        error = exc.stderr or ""
        if isinstance(error, bytes):
            error = error.decode("utf-8", "replace")
        data.update({"refused": False, "exit_code": None, "stderr": error})
    return data


def scenario_local_delete_path():
    """The delete confirmation names the directory it will remove.

    The guard resolves LOCAL against whatever directory the tray happens to run
    in, and the dialog named only the folder, so a wrong root was invisible until
    the tree was gone. The confirmation is answered Cancel, so what is under the
    dialog is what this measures.
    """
    tray = build()
    name = "ordinary"
    target = os.path.join(tray.local, name)
    os.makedirs(target, exist_ok=True)
    MODULE.write_excluded_folders(tray.exclude_file, [name])
    asked = {}
    real = MODULE.Gtk.MessageDialog
    MODULE.Gtk.MessageDialog = fake_message_dialog(
        asked, MODULE.Gtk.ResponseType.CANCEL)
    try:
        tray._offer_local_delete(name)
    finally:
        MODULE.Gtk.MessageDialog = real
    return {"asked": bool(asked),
            "title": asked.get("text", ""),
            "body": asked.get("body", ""),
            "target": os.path.realpath(target),
            "kept": os.path.isdir(target)}


SCENARIOS = {
    "menus": scenario_menus,
    "diagnostics": scenario_diagnostics,
    "rclone-binary": scenario_rclone_binary,
    "bad-bytes": scenario_bad_bytes,
    "sync-fail": scenario_sync_fail,
    "folders-unlisted": scenario_folders_unlisted,
    "settings-enabled": scenario_settings_enabled,
    "quota": scenario_quota,
    "sync": scenario_sync,
    "pause-durations": scenario_pause_durations,
    "timer-state": scenario_timer_state,
    "folders": scenario_folders,
    "folders-failed": scenario_folders_failed,
    "excluded-name": scenario_excluded_name,
    "folder-delete": scenario_folder_delete,
    "pause-recovery": scenario_pause_recovery,
    "openapp": scenario_openapp,
    "lock-hold": scenario_lock_hold,
    "lock-second": scenario_lock_second,
    "lock-inode": scenario_lock_inode,
    "lock-race": scenario_lock_race,
    "reauth": scenario_reauth,
    "reauth-twice": scenario_reauth_twice,
    "stale-state": scenario_stale_state,
    "stale-state-cache": scenario_stale_state_cache,
    "relative-local": scenario_relative_local,
    "local-delete-path": scenario_local_delete_path,
    "settings-view": scenario_settings_view,
    "settings-bandwidth": scenario_settings_bandwidth,
    "settings-markers": scenario_settings_markers,
    "settings-save": scenario_settings_save,
    "settings-fail": scenario_settings_fail,
    "about": scenario_about,
    "notify": scenario_notify,
    "notify-manual": scenario_notify_manual,
    "config-reload": scenario_config_reload,
    "config-comments": scenario_config_comments,
    "config-export": scenario_config_export,
    "config-reload-fresh": scenario_config_reload_fresh,
    "config-unreadable": scenario_config_unreadable,
    "config-unreadable-poll": scenario_config_unreadable_poll,
    "log-result": scenario_log_result,
    "log-cache-moved": scenario_log_cache_moved,
    "pause-survives-poll": scenario_pause_survives_poll,
    "manual-missed": scenario_manual_missed,
    "poll-cost": scenario_poll_cost,
    "no-remote": scenario_no_remote,
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
        json_expr "all(x in d['menu_labels'] for x in ['Sync now', 'Open sync folder', 'View sync log', 'Folders to sync', 'Pause automatic sync', 'Start tray at login', 'Check file names', 'Diagnostics…', 'Re-authorise OneDrive…', 'Rebuild sync baseline (resync)…', 'Settings…', 'About', 'Quit', 'Docs', 'Music', '.config', '30 minutes', '2 hours', '8 hours', 'Resume now'])"
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
        json_expr "all(x in d['menu_labels'] for x in ['立即同步', '打开同步文件夹', '查看同步日志', '同步的文件夹', '暂停自动同步', '开机自动启动托盘', '检查文件名', '诊断…', '重新登录 OneDrive…', '设置…', '关于', '退出', '30 分钟', '2 小时', '8 小时', '立即恢复'])"
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

title "The rclone binary the config names"
# RCLONE is documented as "the rclone binary to run, by name or by path", and
# onedrive-sync, onedrive-check-access and onedrive-doctor all honour it. The tray
# ran the literal "rclone" from PATH in all four of its own queries, so the quota
# row, the folder menu and the sign-in could describe a different binary's remote
# than the one that syncs - which is the case the key exists for.
if run_driver rclone-binary; then
    check "the tray resolved the binary RCLONE names" json_py '
if not d["binary"].endswith("rclone-other"):
    print("rclone=%r" % (d["binary"],))
    raise SystemExit(1)
'
    check "the folder listing asks that binary" json_py '
if not any(x.startswith("rclone-other lsf") for x in d["calls"]):
    print("calls: %r" % (d["calls"],))
    raise SystemExit(1)
'
    check "the quota row asks that binary" json_py '
if not any(x.startswith("rclone-other about") for x in d["calls"]):
    print("calls: %r" % (d["calls"],))
    raise SystemExit(1)
'
    check "the sign-in asks that binary" json_py '
if not any("rclone-other config reconnect" in x for x in d["calls"]):
    print("calls: %r" % (d["calls"],))
    raise SystemExit(1)
'
    check "the check after the sign-in asks that binary" json_py '
if not any(x.startswith("rclone-other lsd") for x in d["calls"]):
    print("calls: %r" % (d["calls"],))
    raise SystemExit(1)
'
    check "and the rclone on PATH is never run" json_py '
path = [x for x in d["calls"] if x.startswith("rclone ")]
if path:
    print("the binary on PATH was run anyway: %r" % (path,))
    raise SystemExit(1)
'
    check "a reload that moves RCLONE moves with it" json_py '
if not d["binary_after_reload"].endswith("rclone-third"):
    print("rclone after the reload: %r" % (d["binary_after_reload"],))
    raise SystemExit(1)
'
fi

title "Sync now"
if run_driver sync; then
    check "activating Sync now records a start of the configured service" \
        json_expr "any(x == 'systemctl --user start ztraytest.service' for x in d['calls'])"
fi

title "Sync now when systemctl refuses the start"
# _start_service and _run threw away the (rc, out, err) systemctl answered with,
# so a refused start still drew "Syncing…" over a run that never began: no error,
# no status change and no retry. The same file already reports systemd's failures
# from the settings window and from a pause that cannot be re-armed, and the
# resync item runs the wrapper directly - which is the retry the fallback uses.
if run_driver sync-fail TRAY_SYNC_FAIL=fallback; then
    check "the failure names what systemd said" json_py '
if not d["told"] or not any("mock systemctl failure" in body
                            for body in d["notices"]):
    print("notices: %r" % (d["notices"],))
    raise SystemExit(1)
'
    check "the status row does not claim a sync is running" json_py '
if "Syncing" in d["status"]:
    print("status: %r" % (d["status"],))
    raise SystemExit(1)
if d["busy"]:
    print("the run is still marked busy after the fallback came back")
    raise SystemExit(1)
'
    check "and the wrapper runs directly rather than nothing happening" json_py '
if not d["direct"]:
    print("starts: %r direct: %r" % (d["starts"], d["direct"]))
    raise SystemExit(1)
'
    check "the folder toggle's own start is reported the same way" json_py '
if not any("mock systemctl failure" in body for body in d["service_notices"]):
    print("notices: %r" % (d["service_notices"],))
    raise SystemExit(1)
if not d["service_direct"]:
    print("no direct run: %r" % (d["service_notices"],))
    raise SystemExit(1)
'
fi

if run_driver sync-fail TRAY_SYNC_FAIL=both; then
    check "a fallback that fails too is reported, and drops the run" json_py '
if not any("Could not start the sync" in body for body in d["notices"]):
    print("notices: %r" % (d["notices"],))
    raise SystemExit(1)
if not d["settled"] or "Syncing" in d["status"]:
    print("status: %r" % (d["status"],))
    raise SystemExit(1)
if d["manual"]:
    print("a request that never started is still marked as a manual run")
    raise SystemExit(1)
'
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
    # The units were just turned back on by the tray itself, and the enabled
    # answer is cached to save a fork per tick. The poll that follows has to ask
    # again: reusing the "disabled" from before the recovery says automatic sync
    # is off, which is the opposite of what the recovery just did.
    check "the poll after the recovery believes the units are on again" json_py '
if not d["settled"]:
    print("the poll never answered: auto_seen=%r" % (d["auto_seen_after"],))
    raise SystemExit(1)
if d["auto_seen_after"] != "on":
    print("the tray reports %r with the label %r, though the units were enabled"
          % (d["auto_seen_after"], d["pause_label_after"]))
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

title "A running tray follows the config file"
# --show-icon, --hide-icon and a --settings window all run in a process that
# exits, and the running tray owns no file watcher: the config file is the only
# way any of them can reach it. The reload is deliberately narrow, so a key that
# belongs to the next sync has to leave the running tray exactly where it was.
# The scenario writes to a private config home so the rewrites cannot leak into
# the other scenarios, which share $WORK/config.
RELOAD_HOME="$WORK/reload-home"
mkdir -p "$RELOAD_HOME/rclone-onedrive-tray"
cp "$WORK/config/rclone-onedrive-tray/config" \
   "$RELOAD_HOME/rclone-onedrive-tray/config"
if run_driver config-reload XDG_CONFIG_HOME="$RELOAD_HOME"; then
    check "the tray starts with its icon shown, in English" json_py '
if not d["visible_before"] or d["status_before"] != d["active"]:
    print("visible=%r status=%r active=%r"
          % (d["visible_before"], d["status_before"], d["active"]))
    raise SystemExit(1)
if "Settings…" not in d["labels_before"]:
    print("labels: %r" % (d["labels_before"],))
    raise SystemExit(1)
'
    check "a hidden icon in the config hides the running icon" json_py '
if not d["hid"] or d["visible_after"] or d["status_after"] != d["passive"]:
    print("hid=%r visible=%r status=%r passive=%r"
          % (d["hid"], d["visible_after"], d["status_after"], d["passive"]))
    raise SystemExit(1)
'
    check "a language change in the config reaches the running menu" json_py '
if not d["switched"]:
    print("the menu never changed language: %r" % (d["labels_after"],))
    raise SystemExit(1)
if not any("\u4e00" <= c <= "\u9fff" for c in d["labels_after"]):
    print("labels after the switch: %r" % (d["labels_after"],))
    raise SystemExit(1)
if "Settings…" in d["labels_after"] or "Sync now" in d["labels_after"]:
    print("still English after the switch: %r" % (d["labels_after"],))
    raise SystemExit(1)
'
    check "a key the tray reads when a run ends follows the file too" json_py '
if not d["notify_followed"]:
    print("NOTIFY_ON_SUCCESS did not reach the running tray")
    raise SystemExit(1)
'
    check "a reload never moves the unit the poll asks about" json_py '
if d["unit_after"] != d["unit"]:
    print("the config now says UNIT_NAME=%r while the tray polls %r"
          % (d["unit_after"], d["unit"]))
    raise SystemExit(1)
if d["unit"] != "ztraytest":
    print("the tray is polling %r, not the configured unit" % (d["unit"],))
    raise SystemExit(1)
if not any("is-active ztraytest.service ztraytest.timer" in x
           for x in d["unit_calls"]):
    print("no poll asked about ztraytest after the reload: %r"
          % (d["unit_calls"],))
    raise SystemExit(1)
'
    check "a key that is not live leaves the running tray alone" json_py '
if not d["unrelated_kept_item"]:
    print("the menu was rebuilt for a key nothing live uses")
    raise SystemExit(1)
if d["unrelated_labels"] != d["labels_after"]:
    print("labels changed: %r -> %r" % (d["labels_after"], d["unrelated_labels"]))
    raise SystemExit(1)
if d["unrelated_visible"] != d["visible_after"]:
    print("visibility changed: %r -> %r"
          % (d["visible_after"], d["unrelated_visible"]))
    raise SystemExit(1)
if d["unrelated_status_text"] != d["status_text_before"]:
    print("status text changed: %r -> %r"
          % (d["status_text_before"], d["unrelated_status_text"]))
    raise SystemExit(1)
'
fi

title "An inline comment in the config"
# bash drops an unquoted # from a sourced config and keeps a # inside a word or
# inside quotes. The tray's own reader used to keep the whole comment as part of
# the value, so a hand-edited INTERVAL_MIN="15"   # every fifteen minutes showed
# the default in the settings dialog while the wrapper and systemd used the real
# one. The scenario reads the file through load_config() and the shell side names
# each value it expects.
if run_driver config-comments; then
    check "a trailing comment is not part of the value" json_py '
cases = {"INTERVAL_MIN": "15", "SHOW_ICON": "1", "BW_LIMIT": "5M"}
for key, want in cases.items():
    got = d["values"].get(key)
    if got != want:
        print("%s=%r, bash reads %r" % (key, got, want))
        raise SystemExit(1)
if d["open_app_cmd"] != "foo --tag#1":
    print("a # inside the quotes was treated as a comment: %r"
          % (d["open_app_cmd"],))
    raise SystemExit(1)
'
    check "a # inside a word is not a comment" json_py '
cases = {"TAGGED": "foo --tag#1", "UNQUOTED": "a#b", "MIXED": "value#1"}
for key, want in cases.items():
    got = d["values"].get(key)
    if got != want:
        print("%s=%r, a # with no space in front of it is not a comment" % (key, got))
        raise SystemExit(1)
'
    check "a # in the middle of a quoted value survives" json_py '
cases = {"QUOTED": "a # b", "SINGLE": "b # c"}
for key, want in cases.items():
    got = d["values"].get(key)
    if got != want:
        print("%s=%r, wanted %r" % (key, got, want))
        raise SystemExit(1)
'
    # The space is the whole distinction, and it is gone by the time the value
    # has been stripped: stripping first made a # that directly followed the =
    # look exactly like one a space had introduced, so KEY=#x read as an empty
    # value while bash keeps "#x". Measured with `set -a; . config` on this
    # machine: BARE=[#x], SPACED_EMPTY=[].
    check "a # that directly follows the = is the value" json_py '
if d["values"].get("BARE") != "#x":
    print("BARE=%r, bash reads #x" % (d["values"].get("BARE"),))
    raise SystemExit(1)
if d["values"].get("SPACED_EMPTY") != "":
    print("SPACED_EMPTY=%r, bash reads an empty value"
          % (d["values"].get("SPACED_EMPTY"),))
    raise SystemExit(1)
'
    # bash removes the backslash from an unquoted \# and this reader keeps it.
    # The divergence is deliberate: the tray's own writer escapes \, " and $
    # with no reader to undo it (KNOWN-ISSUES, "Four parsers for one file
    # format"), so unescaping one character here would be a third answer rather
    # than a fix. The value below is what this reader documents, not what bash
    # would produce for the same line.
    check "an escaped # keeps its backslash, which is this reader's answer" json_py '
if d["values"].get("ESCAPED") != "x\\#y":
    print("ESCAPED=%r, this reader keeps the backslash (bash reads x#y)"
          % (d["values"].get("ESCAPED"),))
    raise SystemExit(1)
'
    check "a quoted value before the comment is unchanged" json_py '
if d["unit_name"] != "a#b":
    print("UNIT_NAME=%r" % (d["unit_name"],))
    raise SystemExit(1)
if d["local"] != d["local_want"]:
    print("LOCAL=%r wanted %r" % (d["local"], d["local_want"]))
    raise SystemExit(1)
'
fi

title "An exported key in the config"
# onedrive-sync and onedrive-doctor source the file with `.`, so a hand-written
# `export REMOTE="onedrive:Notes"` is a value both of them see. The tray split the
# line on its first = alone, filed it under the key "export REMOTE" and left
# REMOTE unset, so it refused to start with a sentence naming those two programs
# as the fix. KEY_RE, the tray's own reader for the file it writes, already
# allowed the prefix.
if run_driver config-export; then
    check "export REMOTE=... sets REMOTE and not a key called export REMOTE" json_py '
if d["remote"] != "export-remote:Notes":
    print("REMOTE=%r, prefix kept as a key: %r"
          % (d["remote"], d["prefix_is_a_key"]))
    raise SystemExit(1)
if d["prefix_is_a_key"]:
    print("the key came back as export REMOTE, with the prefix in it")
    raise SystemExit(1)
'
    check "the whitespace around the prefix does not become part of the key" json_py '
if d["local"] != d["local_want"]:
    print("LOCAL=%r wanted %r" % (d["local"], d["local_want"]))
    raise SystemExit(1)
'
    check "a name that only starts with export is a key of its own" json_py '
if d["not_a_prefix"] != "kept" or d["other"] != "1":
    print("exportexport=%r EXPORTED=%r" % (d["not_a_prefix"], d["other"]))
    raise SystemExit(1)
'
fi

title "A reload re-resolves the six startup snapshots"
# The config keys behind the two "open" rows, the folder submenu's exclusion
# list, the remote the quota asks about and the delete guard's root are resolved
# once in __init__ and read as attributes afterwards. A reload that only refilled
# self.cfg left every one of them on the old file. The scenario reloads a config
# with no language change in it, so the menu moves only if re-resolving the paths
# is also what rebuilds it.
if run_driver config-reload-fresh; then
    check "the tray reloads the file it is polling" \
        json_expr "d['reloaded']"
    check "the delete guard uses the reloaded LOCAL" json_py '
if d["new_delete"] is None:
    print("the guard refused a folder inside the reloaded LOCAL: %r"
          % (d["new_delete"],))
    raise SystemExit(1)
if d["link_delete"] is not None:
    print("a symlink to the old LOCAL passed the guard: %r"
          % (d["link_delete"],))
    raise SystemExit(1)
if not d["deleted_new"] or not d["old_kept"] or not d["sibling_kept"]:
    print("deleted=%r old_kept=%r sibling_kept=%r"
          % (d["deleted_new"], d["old_kept"], d["sibling_kept"]))
    raise SystemExit(1)
if not d["told_deleted"]:
    print("the delete was never reported: %r" % (d["asked"],))
    raise SystemExit(1)
'
    check "the Open {app} row follows OPEN_APP_NAME without a language change" json_py '
if not d["new_label_there"] or not d["old_label_gone"]:
    print("old=%r present=%r new=%r present=%r"
          % (d["old_label"], not d["old_label_gone"],
             d["new_label"], d["new_label_there"]))
    raise SystemExit(1)
'
    check "the two path rows and the app row use the reloaded values" json_py '
if d["opened"] != [d["local_new"], d["log_new"]]:
    print("opened %r, wanted %r" % (d["opened"], [d["local_new"], d["log_new"]]))
    raise SystemExit(1)
if d["spawned"] != [["/bin/true"]]:
    print("the app row ran %r, wanted the reloaded OPEN_APP_CMD" % (d["spawned"],))
    raise SystemExit(1)
if d["open_name"] != d["open_name_new"]:
    print("open_name=%r wanted %r" % (d["open_name"], d["open_name_new"]))
    raise SystemExit(1)
'
    check "the folder submenu reads the reloaded exclusion list" json_py '
if d["folder_checks"].get("git"):
    print("a folder on the new exclusion list is still ticked: %r"
          % (d["folder_checks"],))
    raise SystemExit(1)
if not d["folder_checks"].get("src"):
    print("a folder that is not excluded is unticked: %r" % (d["folder_checks"],))
    raise SystemExit(1)
'
    check "the remote and the log follow the file too" json_py '
if d["remote"] != "fresh-remote:" or d["log"] != d["log_new"]:
    print("remote=%r log=%r wanted fresh-remote: and %r"
          % (d["remote"], d["log"], d["log_new"]))
    raise SystemExit(1)
if d["exclude_file"] != d["exclude_new"]:
    print("exclude_file=%r wanted %r" % (d["exclude_file"], d["exclude_new"]))
    raise SystemExit(1)
'
    check "a language change after the reload still reaches the menu" json_py '
if not d["switched"]:
    print("the menu never changed language: %r" % (d["folder_checks"],))
    raise SystemExit(1)
'
    # The listing and the quota were answered by the remote the reload left
    # behind. Keeping them listed the old account's folders in the submenu, so
    # unticking one wrote that name into the exclusion file that now governs the
    # new remote, and the quota row showed the old account's usage. Both are
    # dropped and asked again, rather than waiting for the half-hour refresh.
    check "a moved REMOTE drops the old folder list and asks the new one" json_py '
if d["folders_after"] == d["listing_old"]:
    print("the old remote listing is still in place: %r" % (d["folders_after"],))
    raise SystemExit(1)
if not d["relisted"] or d["folders_after"] != ["Docs", "git", "src"]:
    print("the new remote listing never landed: relisted=%r folders=%r"
          % (d["relisted"], d["folders_after"]))
    raise SystemExit(1)
if "old-remote-only" in d["folder_checks"]:
    print("a folder only the old remote has is still in the submenu: %r"
          % (d["folder_checks"],))
    raise SystemExit(1)
if "Docs" not in d["folder_checks"]:
    print("a folder only the new remote has never reached the submenu: %r"
          % (d["folder_checks"],))
    raise SystemExit(1)
'
    check "a moved REMOTE drops the old quota and asks again" json_py '
if not d["quota_seen"] or d["quota_after"] != d["quota_new"]:
    print("quota=%r, wanted %r" % (d["quota_after"], d["quota_new"]))
    raise SystemExit(1)
if not d["quota_asked"]:
    print("rclone about was never asked about the new remote")
    raise SystemExit(1)
if d["quota_label"] and "111 B" in d["quota_label"]:
    print("the row still shows the old account: %r" % (d["quota_label"],))
    raise SystemExit(1)
'
    # The failing answers are the reason the two lines above clear the values
    # instead of letting the refresh replace them: an answer that never arrives
    # would otherwise leave the previous remote's folders and quota on screen.
    check "a remote whose answers never land keeps none of the last one's" json_py '
if not d["third_reloaded"]:
    print("the third remote never reached the tray")
    raise SystemExit(1)
if d["folders_third"] is not None:
    print("the previous remote listing is still held: %r" % (d["folders_third"],))
    raise SystemExit(1)
if "Docs" in d["labels_third"] or not any("try again" in x for x in d["labels_third"]):
    print("the folder submenu does not say the listing failed: %r"
          % (d["labels_third"],))
    raise SystemExit(1)
if d["quota_third_visible"] or d["quota_third"] is not None:
    print("the old quota is still held: visible=%r quota=%r label=%r"
          % (d["quota_third_visible"], d["quota_third"], d["quota_third_label"]))
    raise SystemExit(1)
'
fi

title "A config that cannot be read"
# load_config() answers the defaults when the file cannot be read, and the poll
# reloaded whenever the signature moved, including the move to "cannot be read".
# Deleting the config of a running tray therefore copied those defaults onto the
# six startup snapshots, and LOCAL is the root the folder menu's delete guard
# checks: the menu offered to delete a directory under ~/OneDrive while the
# confirmation promised the folder stays in OneDrive. Two gates, because one
# caller is one mistake away.
if run_driver config-unreadable; then
    check "a reload refuses a config it cannot trust" json_py '
if d["local"] != d["local_want"]:
    print("LOCAL moved to %r, wanted %r (the defaults aim the guard at %r)"
          % (d["local"], d["local_want"], d["default_root"]))
    raise SystemExit(1)
if d["remote"] != "unreadable-remote:":
    print("REMOTE became %r" % (d["remote"],))
    raise SystemExit(1)
if d["log"] != d["log_want"] or d["exclude_file"] != d["exclude_want"]:
    print("log=%r wanted %r; exclude_file=%r wanted %r"
          % (d["log"], d["log_want"], d["exclude_file"], d["exclude_want"]))
    raise SystemExit(1)
if d["cfg_remote"] != "unreadable-remote:" or d["cfg_local"] != d["local_want"]:
    print("self.cfg took the defaults: REMOTE=%r LOCAL=%r"
          % (d["cfg_remote"], d["cfg_local"]))
    raise SystemExit(1)
'
    check "the delete guard keeps the configured root" json_py '
if d["delete"] is None:
    print("the guard stopped offering a folder inside the configured root")
    raise SystemExit(1)
if d["delete"] != d["before"]["delete"]:
    print("the guard now targets %r, it targeted %r (the default root is %r)"
          % (d["delete"], d["before"]["delete"], d["default_root"]))
    raise SystemExit(1)
'
fi

title "A poll over a config that cannot be read"
# The other half of the same defect: poll() compares the file's signature with
# the last one it saw, and None - "the signature could not be read" - is unequal
# to every real signature, so every tick after the file went away treated the
# absence as news. Counting the reloads says which gate did the work, and the
# restored file says the spell still ends when there really is news.
if run_driver config-unreadable-poll; then
    check "the poll really is looking at an unreadable file" \
        json_expr "d['signature_now'] is None"
    check "a tick over an unreadable config does not ask for a reload" \
        json_expr "d['reloads'] == 0"
    check "and the tray keeps every value it was using" json_py '
if d["local"] != d["local_want"]:
    print("LOCAL moved to %r, wanted %r" % (d["local"], d["local_want"]))
    raise SystemExit(1)
if d["remote"] != "unreadable-remote:" or d["cfg_remote"] != "unreadable-remote:":
    print("REMOTE=%r cfg REMOTE=%r" % (d["remote"], d["cfg_remote"]))
    raise SystemExit(1)
if d["log"] != d["log_want"] or d["exclude_file"] != d["exclude_want"]:
    print("log=%r exclude_file=%r" % (d["log"], d["exclude_file"]))
    raise SystemExit(1)
if d["delete"] is None or d["delete"] != d["before"]["delete"]:
    print("the delete guard targets %r, it targeted %r"
          % (d["delete"], d["before"]["delete"]))
    raise SystemExit(1)
'
    check "the spell ends when the file comes back with news" json_py '
if not d["resumed"] or d["reloads_after"] < 1:
    print("resumed=%r reloads=%r local=%r remote=%r"
          % (d["resumed"], d["reloads_after"], d["local"], d["remote"]))
    raise SystemExit(1)
'
fi

title "The [tag] a wrapper hint line carries"
# The tag is the contract between onedrive-sync's hint_for and the tray's
# read_last_result/_hint: it is what lets a Chinese hint stand in for an English
# log line, and what decides the icon. The suite had no case for it, so a
# reworded tag or a changed regex would have kept the icon red and the hint
# English with nothing failing.
if run_driver log-result; then
    check "a tagged wrapper failure keeps its tag, time and raw hint" json_py '
want = ["error", "22:21", "network",
        "network problem reaching the remote, so nothing was changed; "
        "the next run will retry",
        "网络或 DNS 暂时不可用，稍后自动重试"]
if d["tagged"] != want:
    print("got %r" % (d["tagged"],))
    print("want %r" % (want,))
    raise SystemExit(1)
'
    check "Bisync successful is synced, with no tag and no hint" json_py '
if d["synced"] != ["synced", "22:30", "", "", ""]:
    print("got %r" % (d["synced"],))
    raise SystemExit(1)
'
    check "a failure with no tag falls back to other and the raw line" json_py '
line = ("2026/10/03 22:40:00 ERROR : Bisync aborted. Must run --resync to "
        "recover.")
want = ["error", "22:40", "other", line, "详见同步日志"]
if d["untagged"] != want:
    print("got %r" % (d["untagged"],))
    raise SystemExit(1)
'
    check "and poll() paints that failure from the same parse" json_py '
if d["state"] != "error":
    print("state=%r status=%r" % (d["state"], d["status"]))
    raise SystemExit(1)
if "22:21" not in d["status"] or "网络" not in d["status"]:
    print("status=%r" % (d["status"],))
    raise SystemExit(1)
'
fi

title "A reload that moves the log it reads"
# The snapshot cache is keyed on size and mtime, so the case has to build the
# collision by hand: a new log of the same length carrying the old one's
# timestamp, which is what copying a log with its times leaves behind.
if run_driver log-cache-moved; then
    check "the moved log really does carry the old one's size and mtime" \
        json_expr "d['same_pair']"
    check "the tick before the reload read the old file" json_py '
if d["before"][0] != "error" or d["before"][2] != "network":
    print("before the reload: %r" % (d["before"],))
    raise SystemExit(1)
'
    check "a reload that moves LOG re-reads it instead of reusing the cache" json_py '
if d["after"] != d["want"]:
    print("after the reload: %r" % (d["after"],))
    print("want %r" % (d["want"],))
    raise SystemExit(1)
'
fi

title "What an idle tick costs"
# The three-second tick used to fork systemctl twice and re-read 64 KB of log
# every time, whether or not either had changed. Both are counted by the driver,
# which wraps the calls the tray makes.
if run_driver poll-cost; then
    check "an unchanged log is neither re-read nor re-parsed" json_py '
if d["applies"] < 5:
    print("only %d ticks landed, so nothing was measured" % (d["applies"],))
    raise SystemExit(1)
if d["log_reads"] or d["log_parses"]:
    print("an unchanged log was read %d times and parsed %d times over %d ticks"
          % (d["log_reads"], d["log_parses"], d["applies"]))
    raise SystemExit(1)
'
    check "a log that grew is read again" json_expr "d['reread_on_change']"
    check "the enabled state is not asked on every tick" json_py '
if d["active_asks"] < 5:
    print("only %d active-state ticks, so nothing was measured"
          % (d["active_asks"],))
    raise SystemExit(1)
if (d["enabled_asks"] >= d["active_asks"]
        or d["enabled_asks"] * 3 > d["active_asks"]):
    print("is-enabled ran %d times for %d ticks"
          % (d["enabled_asks"], d["active_asks"]))
    raise SystemExit(1)
'
fi

title "Folders to sync"
if run_driver folders; then
    check "unticking a folder writes it to exclude-folders.txt" \
        json_expr "d['unchecked_written'] and d['excluded_after_uncheck'] == ['Music'] and d['music_stayed_unchecked']"
    check "a failed write puts the tick back" \
        json_expr "d['reverted']"
    check "the menu and the file still agree after a failed write" \
        json_expr "d['excluded_after_failure'] == ['Music'] and d['check_states']['Docs'] and not d['check_states']['Music']"
fi

title "A folder listing that failed"
# remote_folders() answers None when rclone cannot list the remote, and storing
# that replaced the last listing with nothing: the submenu collapsed to one
# greyed "Loading…" row until the half-hour refresh, and a folder the user had
# unticked could not be ticked again.
if run_driver folders-failed; then
    check "a listing that failed leaves the folders the menu already had" json_py '
if not d["asked"] or not d["settled"]:
    print("the failing listing was never asked for: %r" % (d,))
    raise SystemExit(1)
if d["folders_after"] != ["Docs", "Music"]:
    print("the last listing became %r" % (d["folders_after"],))
    raise SystemExit(1)
if "Loading…" in d["labels_after"]:
    print("the submenu went back to Loading…: %r" % (d["labels_after"],))
    raise SystemExit(1)
missing = [name for name in ("Docs", "Music") if name not in d["labels_after"]]
if missing:
    print("these folders left the menu: %r (it was %r)"
          % (missing, d["labels_before"]))
    raise SystemExit(1)
'
fi
rm -f "$WORK/calls/rclone-lsf-fail"

title "Folders that have never been listed"
# The other half of the same state: a tray started offline, with an expired
# sign-in, against the wrong REMOTE or with rclone missing has never stored a
# listing at all, so the submenu held one greyed "Loading…" row while the label
# was wrong and the retry was up to 1800 seconds away. The quota row hides itself
# in the same state; the folder row has to say what happened and offer the retry.
if run_driver folders-unlisted; then
    check "there is no listing, and the row says the listing failed" json_py '
if d["folders"] is not None:
    print("a listing appeared from a failing stub: %r" % (d["folders"],))
    raise SystemExit(1)
if "Loading…" in d["labels"]:
    print("the submenu still says Loading…: %r" % (d["labels"],))
    raise SystemExit(1)
'
    check "and it names the remote the listing failed on" json_py '
if d["remote"] not in d["retry_label"]:
    print("row: %r, remote: %r" % (d["retry_label"], d["remote"]))
    raise SystemExit(1)
'
    check "the row is a way to try again now, not a dead end" json_py '
if not d["retry_sensitive"]:
    print("the retry row is not sensitive: %r" % (d["retry_label"],))
    raise SystemExit(1)
if not d["asked_again"]:
    print("activating it never asked rclone again")
    raise SystemExit(1)
if not d["retried"] or "Docs" not in d["labels_after"]:
    print("the retry did not bring the folders in: %r" % (d["labels_after"],))
    raise SystemExit(1)
'
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
# The guard resolves LOCAL against the tray process's own directory, so the path
# it returns is the one thing that says which root the delete is aimed at. The
# dialog used to name only the folder.
if run_driver local-delete-path; then
    check "the delete confirmation names the directory it will remove" json_py '
if not d["asked"]:
    print("no confirmation was put on screen at all")
    raise SystemExit(1)
if d["target"] not in d["body"]:
    print("body=%r target=%r" % (d["body"], d["target"]))
    raise SystemExit(1)
'
    check "and still names the folder, and Cancel deletes nothing" json_py '
if "ordinary" not in d["title"]:
    print("title=%r" % (d["title"],))
    raise SystemExit(1)
if not d["kept"]:
    print("the folder was deleted by a cancelled confirmation")
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

# The lock file carries no state; the flock is the lock. Removing it is what made
# two trays possible: a process that opens the path before the release unlinks it
# and flocks it after the release closes holds an inode nobody else will ever
# open, so the next process creates a fresh file and locks that one instead.
if run_driver lock-inode; then
    check "a release keeps a lock file it did not lock" json_py '
if not d["first"]:
    print("the lock could not be taken at all")
    raise SystemExit(1)
if not d["path_kept"] or d["content"].strip() != "another lock":
    print("the file at the lock path was removed: kept=%r content=%r"
          % (d["path_kept"], d["content"]))
    raise SystemExit(1)
'
    check "and the next tray can still take the lock afterwards" json_py '
if not d["second"] or not d["removed_after_release"]:
    print("second=%r removed_after_release=%r"
          % (d["second"], d["removed_after_release"]))
    raise SystemExit(1)
'
fi
if run_driver lock-race; then
    check "a lock taken across a release is not a second lock" json_py '
if not d["holder"] or not d["parked"] or not d["settled"]:
    print("the interleave never happened: %r" % (d,))
    raise SystemExit(1)
if not d["child_acquired"]:
    print("the second process never took a lock, so nothing was measured: %r"
          % (d,))
    raise SystemExit(1)
if d["second_acquired"]:
    print("two processes hold the lock at once: %r" % (d,))
    raise SystemExit(1)
'
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
# Every other worker in the class has a guard; this one had none, so two
# activations started two `rclone config reconnect` terminals and two pollers,
# and the first one to finish said "Signed in. Syncing now." while the other was
# still open. rclone's config file has no cross-process locking, so the two are
# last-writer-wins over the same remote's credentials.
if run_driver reauth-twice; then
    check "a second activation starts no second sign-in" json_py '
if not d["parked"]:
    print("the first flow was never in flight, so nothing was measured")
    raise SystemExit(1)
if d["spawns"] != 1 or d["lsd_calls"] != 1:
    print("spawns=%r lsd_calls=%r" % (d["spawns"], d["lsd_calls"]))
    raise SystemExit(1)
'
    check "and the row is out of action while the flow runs" json_py '
if not d["busy_while_busy"] or not d["insensitive_while_busy"]:
    print("busy=%r sensitive=%r"
          % (d["busy_while_busy"], d["insensitive_while_busy"]))
    raise SystemExit(1)
'
    check "and it comes back when the flow is over" json_py '
if not d["finished"] or d["busy_after"] or not d["sensitive_after"]:
    print("finished=%r busy_after=%r sensitive_after=%r"
          % (d["finished"], d["busy_after"], d["sensitive_after"]))
    raise SystemExit(1)
'
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

# The autostart entry the settings window reads is the one for the config home
# this scenario runs under, which is the sandbox's own. A fixture without the
# file made os.path.exists(AUTOSTART) false no matter what, so the "Start tray at
# login" control could not tell "reads the file" from "always unchecked" - and on
# a machine where the entry exists, a Save wrote it away without the user
# touching the control. scenario_settings_view removes it again for the cases
# below, which drive the write path from nothing.
mkdir -p "$WORK/config/autostart"
cat > "$WORK/config/autostart/rclone-onedrive-tray.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=OneDrive tray
Exec="$SRC_DIR/bin/onedrive-tray"
X-GNOME-Autostart-enabled=true
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
    check "start at login follows the autostart file" json_py '
if not d["boot"]:
    print("the box is unchecked while %s exists (%r)"
          % (d["autostart_path"], d["autostart"]))
    raise SystemExit(1)
'
    check "and is unchecked when the entry is not there" \
        json_expr "not d['boot_without_entry']"
fi

title "A yes/no value spelled enabled"
# The accepted spellings are 1|true|yes|on|enabled, and three of the four readers
# disagree about the last one: onedrive-sync and onedrive-doctor take it, the
# tray's truthy() did not. The wrapper then turned CHECK_ACCESS on while the
# window drew the box unchecked, and a Save wrote 0 over it - dropping the one
# guard that stops a run treating an unreadable side as mass deletion.
ACCESS_HOME="$WORK/access"
mkdir -p "$ACCESS_HOME/rclone-onedrive-tray"
cat > "$ACCESS_HOME/rclone-onedrive-tray/config" <<EOF
# Spelled the way the wrapper's own yes/no reader accepts.
REMOTE="traytest-remote:"
LOCAL="$ACCESS_HOME/local"
UNIT_NAME="ztraytest"
LOG="$WORK/cache/sync.log"
UI_LANG="en"
WATCH="enabled"
CHECK_ACCESS="enabled"
EOF
if run_driver settings-enabled XDG_CONFIG_HOME="$ACCESS_HOME"; then
    check "an enabled spelling is shown as a ticked box" json_py '
if not d["access"] or not d["watch"]:
    print("access=%r watch=%r (values read back %r)"
          % (d["access"], d["watch"], d["values"]))
    raise SystemExit(1)
'
    check "and a Save leaves the spelling, and the file, where it found them" json_py '
if not d["saved"] or d["failures"]:
    print("saved=%r failures=%r" % (d["saved"], d["failures"]))
    raise SystemExit(1)
if d["config_after"] != d["config_before"]:
    print("the file was rewritten: %r -> %r"
          % (d["config_before"], d["config_after"]))
    raise SystemExit(1)
'
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

title "A bandwidth value the list does not offer"
# BW_LIMIT is a free string in the config file: rclone takes sizes the window's
# list does not hold, and 1.5M is one of them. The combo had no entry for it, so
# get_active_id() returned None and the next Save wrote BW_LIMIT="" over a limit
# that was working. Its own home keeps the rewrite away from the other cases.
BW_HOME="$WORK/bw-home"
mkdir -p "$BW_HOME/rclone-onedrive-tray"
cat > "$BW_HOME/rclone-onedrive-tray/config" <<EOF
REMOTE="traytest-remote:"
LOCAL="$BW_HOME/local"
UNIT_NAME="ztraytest"
LOG="$WORK/cache/sync.log"
UI_LANG="en"
INTERVAL_MIN="5"
WATCH="1"
BW_LIMIT="1.5M"
EOF
if run_driver settings-bandwidth XDG_CONFIG_HOME="$BW_HOME"; then
    check "a hand-set bandwidth is on the list and survives a Save" json_py '
if d["original"] != "1.5M":
    print("the dialog did not read the config: %r" % (d["original"],))
    raise SystemExit(1)
if d["shown"] != "1.5M" or "1.5M" not in d["choices"]:
    print("the combo shows %r, out of %r" % (d["shown"], d["choices"]))
    raise SystemExit(1)
if d["values"]["BW_LIMIT"] != "1.5M":
    print("the widgets read back %r" % (d["values"]["BW_LIMIT"],))
    raise SystemExit(1)
if d["values_no_selection"]["BW_LIMIT"] != "1.5M":
    print("with no entry selected the widgets read back %r"
          % (d["values_no_selection"]["BW_LIMIT"],))
    raise SystemExit(1)
if not d["saved"] or d["failures"]:
    print("saved=%r failures=%r" % (d["saved"], d["failures"]))
    raise SystemExit(1)
if "BW_LIMIT=\"1.5M\"" not in d["config_after"]:
    print("the config now holds: %r" % (d["config_after"],))
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

title "A write that cannot finish"
# The four files the tray rewrites are read back by other programs - onedrive-sync
# sources the config, the menu reads the exclusion list - and open(path, "w")
# empties one before a byte of the new text is known to fit. A kernel file-size
# limit is the smallest honest way to make a write stop part way: the reviewer
# used `ulimit -f 8` and left the 8.6 KB config at 8192 bytes, mid-word, with
# MAX_LOG_BYTES, RCLONE, RETRIES and RETRY_DELAY destroyed. Each writer is driven
# under the limit against a target that already has content, and what is left on
# disk afterwards is what the assertions read.
atomic_fixture() {
    env -i PATH="$WORK/stubs:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK/cache" \
        XDG_RUNTIME_DIR="$WORK/run" \
        XDG_CONFIG_HOME="$WORK/atomic-config" XDG_CACHE_HOME="$WORK/cache" \
        XDG_DATA_HOME="$WORK/data" XDG_STATE_HOME="$WORK/state" \
        LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        python3 - "$TRAY" "$WORK/atomic" <<'PY'
import importlib.machinery
import importlib.util
import json
import os
import resource
import signal
import sys

sys.dont_write_bytecode = True

tray_path, work = sys.argv[1], sys.argv[2]
os.makedirs(work, exist_ok=True)
loader = importlib.machinery.SourceFileLoader("tray_atomic", tray_path)
spec = importlib.util.spec_from_loader("tray_atomic", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)

# Every writer's new content is longer than this, so each one stops part way.
LIMIT = 100


def under_limit(call):
    """Run `call` under a file-size limit; report what it raised and answered.

    `raised` is the OSError that escaped the call, `result` is what the call
    returned when it handled the fault itself.
    """
    # The kernel raises SIGXFSZ as well as failing the write, and its default
    # action kills the process: a killed process proves nothing about the file.
    previous = signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    soft, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
    raised, result = "", None
    try:
        resource.setrlimit(resource.RLIMIT_FSIZE, (LIMIT, hard))
        try:
            result = call()
        except OSError as exc:
            raised = str(exc)
        finally:
            resource.setrlimit(resource.RLIMIT_FSIZE, (soft, hard))
    finally:
        signal.signal(signal.SIGXFSZ, previous)
    return {"raised": raised, "result": result}


def text_of(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def temp_files(directory):
    return sorted(name for name in os.listdir(directory)
                  if name.startswith("."))


data = {}

# 1. the config: the file install.sh hands the user, and the one the wrapper
#    sources before anything else.
config = os.path.join(work, "config")
config_body = ('REMOTE="traytest-remote:"\n'
               'LOCAL="/nonexistent/local"\n'
               'MAX_LOG_BYTES="5242880"\n'
               'RCLONE="rclone"\n'
               'RETRIES="3"\n'
               'RETRY_DELAY="5"\n')
config_body += "".join("# padding line %04d\n" % index for index in range(400))
with open(config, "w", encoding="utf-8") as fh:
    fh.write(config_body)
data["config"] = under_limit(
    lambda: module.update_config_file(config, {"RETRIES": "9"}))
data["config_kept"] = text_of(config) == config_body
data["config_leftovers"] = temp_files(work)

# 2. the exclusion list the folder menu and onedrive-sync share.
exclude = os.path.join(work, "exclude-folders.txt")
exclude_body = ("# Folders not kept on this machine, one per line.\n"
                "# Edited by the tray. The cloud keeps them either way.\n"
                + "Archive\n" * 40)
with open(exclude, "w", encoding="utf-8") as fh:
    fh.write(exclude_body)
data["exclude"] = under_limit(
    lambda: module.write_excluded_folders(exclude, ["Archive", "Scratch"]))
data["exclude_kept"] = text_of(exclude) == exclude_body
data["exclude_leftovers"] = temp_files(work)

# 3. the timer drop-in the interval lives in.
dropin = module.timer_dropin_path("ztraytest")
os.makedirs(os.path.dirname(dropin), exist_ok=True)
dropin_body = ("# Set by the tray's settings dialog.\n[Timer]\n"
               "OnUnitInactiveSec=5min\n")
with open(dropin, "w", encoding="utf-8") as fh:
    fh.write(dropin_body)
data["dropin"] = under_limit(
    lambda: module.write_timer_dropin("ztraytest", 15))
data["dropin_kept"] = text_of(dropin) == dropin_body
data["dropin_leftovers"] = temp_files(os.path.dirname(dropin))

# 4. the autostart entry.
autostart = module.AUTOSTART
os.makedirs(os.path.dirname(autostart), exist_ok=True)
autostart_body = ("[Desktop Entry]\nType=Application\nName=old entry\n"
                  "Exec=/usr/bin/onedrive-tray\nTerminal=false\n")
with open(autostart, "w", encoding="utf-8") as fh:
    fh.write(autostart_body)
data["autostart"] = under_limit(lambda: module.write_autostart(True))
data["autostart_kept"] = text_of(autostart) == autostart_body
data["autostart_leftovers"] = temp_files(os.path.dirname(autostart))

# 5. and a write that does finish has to arrive as one file. Editing the target
#    in place is what leaves a reader able to see half of it, so the whole point
#    is that the old file is replaced rather than rewritten: a new inode at the
#    path is the observable half of that.
before = os.stat(config).st_ino
module.update_config_file(config, {"RETRIES": "4"})
data["config_replaced"] = os.stat(config).st_ino != before
data["config_now"] = text_of(config)
data["config_leftovers_after"] = temp_files(work)

print(json.dumps(data))
PY
}
if atomic_fixture > "$LAST_JSON" 2>"$DRIVER_ERR"; then
    check "a config write that cannot finish keeps the old content" json_py '
if not d["config"]["raised"]:
    print("the failing write reported success")
    raise SystemExit(1)
if not d["config_kept"]:
    print("the config was left truncated")
    raise SystemExit(1)
'
    check "a write that finishes replaces the file with no litter" json_py '
if not d["config_replaced"]:
    print("the config was edited in place, so a reader can see half of it")
    raise SystemExit(1)
leftovers = sorted(set(d["config_leftovers"] + d["exclude_leftovers"]
                       + d["dropin_leftovers"] + d["autostart_leftovers"]
                       + d["config_leftovers_after"]))
if leftovers:
    print("temporary files left behind: %r" % (leftovers,))
    raise SystemExit(1)
if "RETRIES=\"4\"" not in d["config_now"]:
    print("the replacement lost the change: %r" % (d["config_now"][:200],))
    raise SystemExit(1)
'
    check "the exclusion list reports the failure and keeps its content" json_py '
if d["exclude"]["result"][0]:
    print("the failed write was reported as ok: %r" % (d["exclude"]["result"],))
    raise SystemExit(1)
if not d["exclude_kept"]:
    print("the exclusion list was left truncated")
    raise SystemExit(1)
'
    check "the timer drop-in reports the failure and keeps its content" json_py '
if not d["dropin"]["result"]:
    print("the failed write reported success: %r" % (d["dropin"],))
    raise SystemExit(1)
if not d["dropin_kept"]:
    print("the timer drop-in was left truncated")
    raise SystemExit(1)
'
    check "the autostart entry reports the failure and keeps its content" json_py '
if not d["autostart"]["result"]:
    print("the failed write reported success: %r" % (d["autostart"],))
    raise SystemExit(1)
if not d["autostart_kept"]:
    print("the autostart entry was left truncated")
    raise SystemExit(1)
'
else
    bad "the write fixture could not be run"
    sed -n '1,6p' "$DRIVER_ERR" | sed 's/^/        /'
fi

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

title "A manual run that failed"
# The setting covers "a sync I start", and a scheduled run is meant to stay
# quiet. A run that failed used to leave the tray marked as if the user had
# started one, so the next run the timer made was announced as a manual success.
if run_driver notify-manual; then
    check "a manual run that succeeds is still announced" json_py '
if not any("Sync finished" in body for body in d["manual_bodies"]):
    print("manual bodies: %r" % (d["manual_bodies"],))
    raise SystemExit(1)
'
    check "a scheduled success after a failed manual run stays quiet" json_py '
if any("Sync finished" in body for body in d["scheduled_bodies"]):
    print("the scheduled run announced itself: %r (the failure before it was %r)"
          % (d["scheduled_bodies"], d["failed_bodies"]))
    raise SystemExit(1)
'
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
    0 "$WANT_VERSION" cli --version
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

title "A config with no REMOTE"
# A hand-edited config can have REMOTE commented out, and a tray started from the
# autostart entry has no terminal to show a traceback in. The wrapper and the
# doctor both report this condition; the tray has to say the same kind of thing.
if run_driver no-remote TRAY_NO_REMOTE_HOME="$WORK/noremote"; then
    check "the tray exits 1 instead of starting" json_expr "d['exit_code'] == 1"
    check "and names REMOTE and the file it is missing from" json_py '
if "REMOTE" not in d["stderr"] or d["config_file"] not in d["stderr"]:
    print("stderr: %r" % (d["stderr"],))
    raise SystemExit(1)
'
    check "and points at setup.sh or onedrive-doctor" json_py '
if "setup.sh" not in d["stderr"]:
    print("nothing points at setup.sh: %r" % (d["stderr"],))
    raise SystemExit(1)
'
    check "the edit that fixes it, and the file to make it in, are spelled out" json_py '
if "REMOTE=\"" not in d["stderr"]:
    print("the edit to make is not spelled out: %r" % (d["stderr"],))
    raise SystemExit(1)
if d["config_file"] not in d["stderr"]:
    print("the file to edit is not named: %r" % (d["stderr"],))
    raise SystemExit(1)
'
    check "and the read-only doctor is not offered as the fix" json_py '
if "onedrive-doctor" in d["stderr"]:
    print("a read-only tool is offered as the fix for a missing key: %r"
          % (d["stderr"],))
    raise SystemExit(1)
'
    check "and no traceback reaches stderr" json_py '
if "Traceback" in d["stderr"] or "KeyError" in d["stderr"]:
    print("stderr: %r" % (d["stderr"],))
    raise SystemExit(1)
'
fi

title "A LOCAL that is not absolute"
# LOCAL is written verbatim by setup.sh and by hand, and nothing checked it. When
# it is relative the delete guard resolves it against the tray process's own
# working directory, not the directory rclone syncs: isdir, realpath and the
# prefix check all pass against a tree outside the sync pair, and the
# confirmation named only the folder. The scenario plants a decoy of the same
# name in a directory of its own and runs the guard from there.
if run_driver relative-local TRAY_RELATIVE_LOCAL_HOME="$WORK/relative-home"; then
    check "the refusal names LOCAL and the value it holds" json_py '
if "LOCAL" not in d["problem"] or "OneDrive" not in d["problem"]:
    print("the sentence names neither the key nor the value: %r" % (d["problem"],))
    raise SystemExit(1)
'
    check "main() exits 1 on a relative LOCAL instead of starting" json_py '
if d["exit_code"] != 1:
    print("refused=%r exit_code=%r stderr=%r"
          % (d["refused"], d["exit_code"], d["stderr"][:300]))
    raise SystemExit(1)
if "LOCAL" not in d["stderr"] or "OneDrive" not in d["stderr"]:
    print("stderr: %r" % (d["stderr"],))
    raise SystemExit(1)
'
    check "and the delete guard refuses the wrong root" json_py '
if d["guard"] is not None:
    print("the guard returned %r, which is under the process own directory %r"
          % (d["guard"], d["decoy_path"]))
    raise SystemExit(1)
'
fi

title "A config that is not valid UTF-8"
# load_config() caught OSError only, so one bad byte raised UnicodeDecodeError out
# of main() and the tray died with a traceback, in a process whose autostart entry
# has Terminal=false. The shell half sources the same file happily, so the sync
# kept running while the tray never appeared. The offending byte has to be named,
# and a byte inside a value has to be refused rather than repaired, because LOCAL
# is a path.
if run_driver bad-bytes TRAY_BAD_BYTES_HOME="$WORK/badbytes"; then
    check "a bad byte in a comment is a sentence, not a traceback" json_py '
got = d["in_comment"]
if got["exit_code"] != 1:
    print("exit %r, stderr %r" % (got["exit_code"], got["stderr"]))
    raise SystemExit(1)
if "Traceback" in got["stderr"]:
    print("stderr: %r" % (got["stderr"],))
    raise SystemExit(1)
if d["config_file"] not in got["stderr"]:
    print("the file is not named: %r" % (got["stderr"],))
    raise SystemExit(1)
if "UTF-8" not in got["stderr"]:
    print("the fault is not named as an encoding: %r" % (got["stderr"],))
    raise SystemExit(1)
if "0xe9" not in got["stderr"]:
    print("the offending byte is not named: %r" % (got["stderr"],))
    raise SystemExit(1)
'
    check "a bad byte in a value is refused the same way" json_py '
got = d["in_value"]
if got["exit_code"] != 1:
    print("exit %r, stderr %r" % (got["exit_code"], got["stderr"]))
    raise SystemExit(1)
if "Traceback" in got["stderr"]:
    print("stderr: %r" % (got["stderr"],))
    raise SystemExit(1)
if "0xe9" not in got["stderr"] or "UTF-8" not in got["stderr"]:
    print("the fault is not named: %r" % (got["stderr"],))
    raise SystemExit(1)
if "REMOTE is not set" in got["stderr"]:
    print("the unreadable file was read as the defaults: %r" % (got["stderr"],))
    raise SystemExit(1)
'
    check "and a running tray keeps what it has instead of dying" json_py '
if d["reload_crashed"]:
    print("the reload died: %s" % (d["reload_crashed"],))
    raise SystemExit(1)
if not d["reload_kept_local"]:
    print("the reload moved LOCAL to make sense of a file it could not read")
    raise SystemExit(1)
'
fi

title "A pause survives the poll that follows it"
if run_driver pause-survives-poll; then
    check "the pause stamp is still there after two polls" json_py '
if not d["stamped"]:
    print("pause_for never wrote the stamp")
    raise SystemExit(1)
if not d["stamp_left"]:
    print("the poll after the pause deleted the stamp, so nothing will resume it")
    raise SystemExit(1)
'
    check "and the menu still says when it comes back" json_py '
if d["auto_seen"] != "paused":
    print("auto_seen=%r, so the tray stopped believing its own pause"
          % (d["auto_seen"],))
    raise SystemExit(1)
if "Paused until" not in d["pause_label"]:
    print("pause label: %r" % (d["pause_label"],))
    raise SystemExit(1)
'
fi
# The other ordering, and the one the cache alone could not help with: the
# is-enabled answer is computed before the pause and delivered after it. It still
# says "enabled", which reads as automatic sync being on, and the stamp is thrown
# away by the answer rather than by the cache.
title "An answer that arrives after the pause"
if run_driver stale-state; then
    check "the pause survives an answer computed before it" json_py '
if not d["parked"]:
    print("no state query was ever in flight, so nothing was measured")
    raise SystemExit(1)
if not d["stamped"]:
    print("pause_for never wrote the stamp")
    raise SystemExit(1)
if not d["stamp_left"]:
    print("the answer from before the pause deleted the stamp (timer_state=%r)"
          % (d["timer_state"],))
    raise SystemExit(1)
'
    check "and the menu still says when the pause comes back" json_py '
if d["auto_seen"] != "paused":
    print("auto_seen=%r, so the tray stopped believing its own pause"
          % (d["auto_seen"],))
    raise SystemExit(1)
if "Paused until" not in d["pause_label"]:
    print("pause label: %r" % (d["pause_label"],))
    raise SystemExit(1)
'
fi
# And the answer must not survive in the cache: the tick after the pause would
# read it back as the units' current state, for as long as ENABLED_EVERY ticks.
if run_driver stale-state-cache; then
    check "a stale answer does not become the cached state" json_py '
if not d["bumped"]:
    print("the units never moved during the ask, so nothing was measured")
    raise SystemExit(1)
if d["timer"] != "enabled":
    print("the ask did not produce the stale answer: %r" % (d["timer"],))
    raise SystemExit(1)
if d["cached"] is not None:
    print("the stale answer was cached as %r, so the next tick reuses it"
          % (d["cached"],))
    raise SystemExit(1)
'
fi

title "A manual run the poll never saw"
if run_driver manual-missed; then
    check "the request expires when no run is ever seen" json_py '
if not d["forgotten"]:
    print("the manual request outlived a run that was never observed")
    raise SystemExit(1)
'
    # The same two ticks, but with the start still in flight: systemd has been
    # asked and the run has not appeared yet, so there is nothing yet to expire.
    check "a request whose start is still in flight is not expired" \
        json_expr "d['kept_while_busy']"
    check "and the scheduled success after it stays quiet" json_py '
if d["notices_after"]:
    print("notifications: %r" % (d["notices_after"],))
    raise SystemExit(1)
'
fi

title "Diagnostics… runs the doctor"
if run_driver diagnostics; then
    check "the tray asks for onedrive-doctor" json_py '
if d["asked"] != ["onedrive-doctor"]:
    print("asked for %r" % (d["asked"],))
    raise SystemExit(1)
'
    check "and shows what it printed, under its own heading" json_py '
if not d["ran"] or not d["shown"]:
    print("nothing reached the dialog")
    raise SystemExit(1)
got = d["shown"][0]
if "rclone" not in got["report"]:
    print("report: %r" % (got["report"],))
    raise SystemExit(1)
if "diagnostic" not in (got["title"] or "").lower():
    print("title: %r" % (got["title"],))
    raise SystemExit(1)
if got["blurb"] == "Nothing needs fixing.":
    print("the doctor report was announced with the name check wording")
    raise SystemExit(1)
'
fi

title "Progress, in the shapes a real run writes"
# The fixture above feeds one statistics block, the one with a percentage. A real
# log is mostly the other shape: a run that transfers nothing prints "-" where the
# percentage would be, and one that is starting prints the same while a file is
# already in flight. Both are copied out of this machine's own log, which holds 68
# blocks with a percentage and several hundred without.
check "the block with no percentage means no progress, not 0%" \
    python3 - "$TRAY" <<'PY'
import importlib.machinery
import importlib.util
import sys

sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("tray_progress", sys.argv[1])
spec = importlib.util.spec_from_loader("tray_progress", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)

problems = []
nothing = ("2026/10/02 17:32:01 INFO  : \n"
           "Transferred:   \t          0 B / 0 B, -, 0 B/s, ETA -\n"
           "Checks:              1658 / 1658, 100%, Listed 1776\n")
if module.read_progress(nothing, max_age=10 ** 9) is not None:
    problems.append("an idle run reported progress: %r"
                    % (module.read_progress(nothing, max_age=10 ** 9),))

starting = ("Transferring:\n"
            " *                  99-Daily/note.md:  0% / 752 B, 0 B/s, -\n"
            "\n"
            "Transferred:   \t          0 B / 752 B, -, 0 B/s, ETA -\n")
if module.read_progress(starting, max_age=10 ** 9) is not None:
    problems.append("a run that has moved no bytes reported progress: %r"
                    % (module.read_progress(starting, max_age=10 ** 9),))

real = ("Transferred:   \t        752 B / 752 B, 100%, 188 B/s, ETA 0s\n"
        "Checks:              1657 / 1657, 100%, Listed 1884\n"
        "Transferring:\n"
        " *                  99-Daily/2026-10-02-dsh.md:100% / 752 B, 187 B/s, 0s\n")
got = module.read_progress(real, max_age=10 ** 9)
if not got or got.get("pct") != 100 or got.get("speed") != "188 B/s":
    problems.append("a real finished block read as %r" % (got,))
elif got.get("file") != "99-Daily/2026-10-02-dsh.md":
    problems.append("the file in flight was reported as %r" % (got.get("file"),))

if problems:
    print("; ".join(problems))
    raise SystemExit(1)
PY

# rclone writes the file name, then a colon, then the percentage, and a name can
# hold a colon of its own. A parser that stops at the first colon reports
# "archive" for "archive:2026/plan.md", and the status line is the tray's only
# per-file signal, so naming a file that does not exist is worse than naming
# none. Both shapes rclone writes are checked: the finished one has no space
# after the colon, the one still in flight has one.
check "a colon in the file name is not read as the percentage separator" \
    python3 - "$TRAY" <<'PY'
import importlib.machinery
import importlib.util
import sys

sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("tray_colon", sys.argv[1])
spec = importlib.util.spec_from_loader("tray_colon", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)

problems = []
cases = {
    "finished": ("Transferred:   \t        752 B / 752 B, 100%, 188 B/s, ETA 0s\n"
                 "Transferring:\n"
                 " *         archive:2026/plan.md:100% / 752 B, 187 B/s, 0s\n"),
    "in flight": ("Transferred:   \t        1.5 MiB / 10 MiB, 15%, 250 KiB/s, "
                  "ETA 1m0s\n"
                  "Transferring:\n"
                  " *         archive:2026/plan.md: 15% / 752 B, 187 B/s, 1s\n"),
}
for shape, text in cases.items():
    got = module.read_progress(text, max_age=10 ** 9)
    if not got:
        problems.append("the %s block read as None" % shape)
    elif got.get("file") != "archive:2026/plan.md":
        problems.append("the %s block named %r" % (shape, got.get("file")))
if problems:
    print("; ".join(problems))
    raise SystemExit(1)
PY

summary
