# Updating

Three commands, and the configuration is kept:

```bash
cd rclone-onedrive-tray
git pull
./install.sh            # add --no-start to leave the tray alone
```

Then restart the tray so the new menu and translations are loaded. The panel
icons are drawn at that start as well, so a redrawn set appears with the same
restart. `onedrive-sync` needs nothing: it is a oneshot service that systemd runs
fresh on every tick, so the next run uses the new code. The watcher is different,
because it is a long-lived process: `install.sh` restarts it for you after
rewriting its unit, and if you installed by copying files by hand you have to
restart it yourself (`systemctl --user restart <unit>-watch.service`).

```bash
kill "$(pgrep -f 'python3 .*/onedrive-tray')" ; onedrive-tray &
```

`install.sh` keeps an existing `config` and `filters.txt` and tells you so. It
rewrites the systemd units from the current templates, and it leaves the autostart
entry alone if you removed it, so unticking "Start tray at login" survives an
update. It does not interrupt a sync that is already running.

## Did the update take effect?

Two checks, both cheap.

```bash
# the installed scripts against the checkout
for s in onedrive-sync onedrive-tray onedrive-watch onedrive-check onedrive-check-access onedrive-doctor; do
    cmp -s "$HOME/.local/bin/$s" "bin/$s" && echo "$s same" || echo "$s DIFFERS"
done

# the running tray against the file it was started from
ps -o lstart= -p "$(pgrep -f 'python3 .*/onedrive-tray')"
stat -c '%y' "$HOME/.local/bin/onedrive-tray"
```

If the process started before the file was last written, that process is running
the older code.

## When a resync is needed after updating

Changing any of these invalidates the baseline, so one `onedrive-sync --resync`
is needed afterwards:

- `REMOTE` or `LOCAL`
- `FILTERS_FILE`, or the contents of `filters.txt`
- `BISYNC_ARGS`

Changing these does not: `MAX_DELETE`, `CHECK_ACCESS`, `CHECK_FILENAME`,
`INTERVAL_MIN`, `WATCH`, `LOG`, `BW_LIMIT`, `UI_LANG`, `SHOW_ICON`,
`NOTIFY_ON_SUCCESS`, and the folder list in `exclude-folders.txt`.
Measured on rclone 1.75.1: toggling a folder in that list touches neither side
and needs no resync.

Turning `CHECK_ACCESS` on is the one update that deliberately fails until it is
finished: bisync looks for the marker file on both sides and aborts while one is
missing. Create them first, then enable it:

```bash
onedrive-check-access          # safe to run twice
# then set CHECK_ACCESS="1" in the config
```

## Rolling back

The tag tells you which version you are on, and the config, the filters and the
bisync listings all survive a downgrade:

```bash
git checkout v1.1.0
./install.sh
```

If the older version refuses to start because of the listings the newer one
wrote, one `onedrive-sync --resync` rebuilds them. Nothing is deleted by a
resync; it rebuilds the comparison state by reading both sides.

## What changed in each version

`CHANGELOG.md` is the list. Six entries are worth reading before updating an
install that has been running for a while:

- 1.4.0 finishes that job and fixes three ways a machine could stop syncing
  quietly. Unticking a folder whose name starts with `#` never actually
  excluded it, while the delete dialog promised the cloud was untouched, so
  the deletion propagated; such a name is refused now. A timed pause did not
  survive a reboot, and the menu went on promising a resume that no longer
  existed. And a typo in `RETRIES`, `RETRY_DELAY` or `MAX_LOG_BYTES` stopped
  syncing altogether while reporting failed attempts that never happened.
- 1.3.0 tightened the tray's offer to delete the local copy of a folder you
  deselected. A two-component name reached `shutil.rmtree` under the old
  checks, so a crafted or unusual listing could have removed a nested
  directory. The rule is now one path component inside the sync root, and
  the same release adds `onedrive-doctor`, which is the first thing to run
  when something looks wrong.
- 1.2.0 added the tray's settings window. It edits the config file in place: the
  lines it does not change, including your own comments, are left alone, and a
  key it needs but cannot find is appended at the end with a note saying where it
  came from. Nothing is rewritten from a template.
- 1.1.0 made `MAX_DELETE` cap what it always claimed to. Before it, the value was
  passed to rclone as a percentage, so 100 meant "no limit". If you rely on large
  deletions going through unattended, raise the value or run with `--force` once.
- The same version stopped reporting a network failure as an expired sign-in, and
  added the tray's "Re-authorise OneDrive" item for the cases that really are an
  expiry.
- `CHECK_ACCESS` is off by default and stays off unless you ask for it.
