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


def scenario_reauth():
    """The re-authorise item must run rclone's sign-in for the right remote.

    The handler asks for confirmation first, so Gtk.MessageDialog is replaced by
    something that answers yes; the rest of the path is untouched.
    """
    tray = build()
    clear_calls()
    asked = {}

    class FakeDialog:
        def __init__(self, *a, **k):
            asked["text"] = k.get("text", "")
            asked["buttons"] = []

        def format_secondary_text(self, text):
            asked["body"] = text

        def add_button(self, label, response):
            asked["buttons"].append(label)

        def run(self):
            return MODULE.Gtk.ResponseType.OK

        def destroy(self):
            pass

    real = MODULE.Gtk.MessageDialog
    MODULE.Gtk.MessageDialog = FakeDialog
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

    class FakeDialog:
        def __init__(self, *a, **k):
            seen["text"] = k.get("text", "")
            seen["buttons"] = []

        def format_secondary_text(self, text):
            seen["body"] = text

        def add_button(self, label, response):
            seen["buttons"].append(label)

        def run(self):
            return 0

        def destroy(self):
            pass

    real = MODULE.Gtk.MessageDialog
    MODULE.Gtk.MessageDialog = FakeDialog
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
        json_expr "all(x in d['menu_labels'] for x in ['立即同步', '打开同步文件夹', '查看同步日志', '同步的文件夹', '暂停自动同步', '开机自动启动图标', '检查文件名', '重新登录 OneDrive…', '设置…', '关于', '退出', '30 分钟', '2 小时', '8 小时', '立即恢复'])"
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
          "Tell me when a sync succeeds", "Delete cap (files)",
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
    0 "1.2.0" cli --version
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
