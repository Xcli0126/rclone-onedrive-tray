# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Realtime sync. `onedrive-watch` watches the local folder with inotify and starts a run as soon
  as edits stop arriving, so local changes no longer wait for the timer. Measured end to end, a
  new file reached the cloud 26 seconds after it was written. The timer stays in place as the
  trigger for changes made on another machine, which no local watcher can see. Needs the
  `inotify-tools` package; the installer warns and carries on without it.
- `onedrive-watch.service`, a systemd user unit that keeps the watcher alive.
- `install.sh` installs the watcher and enables its unit when `WATCH=1`.
- New configuration keys: `WATCH`, `WATCH_DEBOUNCE`, `WATCH_SETTLE`, `WATCH_EXCLUDE`.
- The tray menu reports account usage, read from `rclone about` on a background thread and
  refreshed every 30 minutes.
- Live sync progress in the tray status line: percentage, throughput and the file being
  transferred, parsed from rclone's stats output. `BISYNC_ARGS` now defaults to `--stats 2s` so
  the blocks arrive often enough to be useful. A block older than 30 seconds is ignored, so an
  idle tray no longer reports the final numbers of the previous run.
- Timed pause in the tray: 30 minutes, 2 hours or 8 hours. Both the timer and the watcher stop,
  and a transient systemd timer (`systemd-run --user --on-active`) brings them back, so a pause
  ends even if the tray exits. The menu shows the resume time.
- `setup.sh`, a first-run wizard: picks the remote, the remote folder, the local directory and the
  filter set, writes the config, then hands over to `install.sh`. Non-interactive through
  `--remote/--local/--filters/--unit-name/--yes`. It resolves `XDG_CONFIG_HOME` and
  `XDG_CACHE_HOME` rather than assuming `~/.config` and `~/.cache`, and `--yes` deliberately does
  not start the first sync, which is long and must not be interrupted.
- Optional NetworkManager dispatcher hook (`./install.sh --with-nm-dispatcher`) that starts a
  sync as soon as an interface comes up, so waking from suspend catches up in seconds instead of
  waiting for the timer. This is the only component that needs root.
- Selective folder sync. Names in `$CONFIG_DIR/exclude-folders.txt`, one per line, become
  `--exclude "/<name>/**"` on every run, and the tray grows a "Folders to sync" submenu that
  edits that file. Two things were measured on rclone 1.75.1 before designing around them:
  changing the filter set does not require `--resync`, and excluding a folder touches neither
  side. The `File was deleted` lines that appear during bisync's diff phase are listing
  bookkeeping, not actions; the file counts on both sides stay the same.
  Since a folder that is present locally but no longer synced is a trap (edits in it go
  nowhere), the tray asks whether to delete the local copy when you untick one.

### Fixed

- A missing `flock` made `onedrive-sync` print "another sync is already running" and exit 0 without
  ever invoking rclone. Every run looked normal in the log while nothing synced. It now refuses to
  start and says why.
- A missing GTK, AppIndicator or cairo binding made the tray die with a Python traceback. It now
  exits with the exact apt command, and a missing notification binding degrades to running without
  notifications instead of being fatal.
- `install.sh` probes each dependency on its own and names the package that is actually absent,
  rather than pointing at a bundle the reader has to unpick. Optional pieces are reported
  separately and do not block the install.
- The requirements listed `libnotify-bin`, which provides the `notify-send` command line tool. The
  tray needs the Python binding, which is `gir1.2-notify-0.7`.

### Added

- `extras/watch-issues.sh` and its timer installer, for maintainers: polls the GitHub API twice a
  day, ignores pull requests, notifies on anything not seen before, and appends to
  `~/.cache/rclone-onedrive-tray/issues.log`. It is not part of the syncing and needs `curl` and
  `notify-send`.

## [1.0.0] - 2026-09-13

First public release.

### Added

- `onedrive-sync`, a wrapper around `rclone bisync` that makes an unattended
  sync loop survivable:
  - runs with `--resilient --recover` so a suspend, crash or power loss is
    followed by a normal sync instead of a demand for a manual `--resync`
    (requires rclone ≥ 1.65)
  - clears stale bisync lock files whose owning PID is gone, rather than waiting
    for the whole `--max-lock` window
  - holds a `flock` for the duration of a run, so a manual sync and a scheduled
    one can never race and corrupt bisync's listing files
  - retries a failed run (`RETRIES`, `RETRY_DELAY`) and rotates its own log at
    5 MB
  - classifies the failure and tags it (`[network]`, `[maxdelete]`, `[resync]`,
    `[lock]`, `[auth]`, `[other]`) so a UI can localise it and the log stays
    greppable
  - supports `onedrive-sync --resync` as the documented way out of an
    inconsistent state
- `onedrive-tray`, a GTK/AppIndicator status icon:
  - five states (synced / syncing / failed / paused / no-record) with
    procedurally drawn icons
  - desktop notification on failure, carrying the localised reason
  - menu: sync now, open the synced folder, view the log, pause automatic sync,
    start at login, rebuild the baseline, quit
  - English and Simplified Chinese UI, selected by `UI_LANG` or the locale
  - single-instance lock; reads only the last 64 KB of the log
- systemd user units, a `oneshot` service with `TimeoutStartSec=1800`
  (systemd's 90 s default would kill a first full sync) and a timer using
  `OnUnitInactiveSec` so runs cannot overlap.
- `install.sh` / `uninstall.sh`, per-user install with dependency checks,
  unit generation from templates, and no `sudo`.
- Example configuration, `config/config.example` and
  `config/filters.example`, covering caches and per-machine state that should not
  be synced.
- `docs/TROUBLESHOOTING.md`, the failure modes that cost the most time to
  diagnose, including Microsoft deprecating the `nativeclient` redirect
  (`/common/wrongplace`), the rclone `ObjectHandle is Invalid` drive-ID trap,
  bisync lock and resync behaviour, and `oneshot` services reporting
  `activating` rather than `active`.
- GitHub Actions workflow running `shellcheck` and syntax checks.

### Notes

- Requires rclone ≥ 1.65 for automatic recovery from an interrupted run. Older
  versions still work, but an interruption will require `--resync` by hand.
- The tray icon needs an AppIndicator-compatible shell; on stock GNOME that means
  the AppIndicator extension.
- `rclone bisync` is marked experimental upstream. See the "Known limitations"
  section of the README.

[Unreleased]: https://github.com/Xcli0126/rclone-onedrive-tray/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Xcli0126/rclone-onedrive-tray/releases/tag/v1.0.0
