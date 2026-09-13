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
- Four test suites, runnable with no OneDrive account and no risk to a working setup.
  `tests/dependency-matrix.sh` hides one dependency at a time and checks that the behaviour matches
  what `docs/DEPENDENCIES.md` promises. `tests/install-flow.sh` runs the documented install path,
  uninstall included, inside a sandbox and checks the files and the rclone command line it
  produces. `tests/filters.sh` runs rclone over a fixture tree to prove each default rule really
  filters. `tests/docs.sh` checks that the internal links resolve, that no page has picked up an em
  dash, that the files the READMEs name still exist, and that the prose does not contradict the
  number of suites. All four are wired into CI.
- `docs/COMPATIBILITY.md`: the versions this was developed against, the behaviour measured on a
  real account, and an explicit list of what has never been tried.
- `onedrive-check`, a pre-flight walk of the local tree that reports names OneDrive will refuse,
  names rclone will silently rename on the way up, and paths that are too long. It exits non-zero
  when something will actually fail, so it can be scripted. `onedrive-sync --resync` runs it first
  and logs the report, and the tray has it as a menu item. The limits it uses are measured rather
  than copied: a 383-character cloud path failed where 364 passed, so it treats 380 as the ceiling
  instead of Microsoft's documented 400.
- `tests/install-flow.sh` gained regression cases for the delete cap: the conversion from a count
  to a percentage, the abort being reported as a delete-cap problem with a way forward, and an
  unrelated failure not being blamed on it.
- `tests/filters.sh`: one file per default rule in a fixture tree, checked against rclone. Plus
  regression cases for everything above: a tray with no display, an unusable `TMPDIR`, a
  non-interactive `setup.sh` with no remote, an installer that must not enable someone else's unit,
  and an uninstaller that must not run `sudo`.
- `docs` gained an account-free way to try the whole loop (`rclone config create trial alias remote
  /tmp/onedrive-trial`), a guide to installing alongside an existing setup with `--prefix` and
  `--unit-name`, the two paths in the installed-file list that were missing, and the exit statuses
  `onedrive-check` uses.
- `docs/FEATURE-PARITY.md`: what the Windows and macOS OneDrive clients actually do, sourced from
  Microsoft's own pages, sorted into must have, worth having and skip, with a status column for this
  project and an ordered list of the gaps. It records two things Microsoft does not document, a
  conflict winner rule and any LAN sync feature, so nobody researches them twice.
- `docs/SIGNING-IN.md`, for the one step this project does not wrap. Signing in belongs to rclone,
  so the page covers what the browser flow asks, how to pick the right drive when an account has
  more than one, the `ObjectHandle is Invalid` trap that follows a wrong pick, `rclone authorize`
  for a machine with no browser, work and school accounts, and the 90-day token expiry. `setup.sh`
  points at it when it finds no remote, and so does `docs/DEPENDENCIES.md`.

### Fixed

- The tray had ten defects, all found by constructing its real menu on a private Broadway display
  and activating every handler with stubs. The two dialogs that confirm a destructive action read
  literally `dlg_resync_body` and `lcl_deselected_body` under the default English interface,
  because those two strings existed only as translation keys. Every `systemctl`, `systemd-run` and
  `rmtree` call ran on the GTK main loop, so a slow one froze the interface: with a one-second stub
  a single poll blocked for two seconds and pressing Pause blocked for six. A missing or disabled
  timer unit was reported as "Automatic sync paused", inventing a pause that never happened. The
  quota row stayed visible and empty whenever `rclone about` failed, because `menu.show_all()`
  undid `set_visible(False)`. A failed "Start tray at login" write left the tick in place with no
  file behind it. A quoted `OPEN_APP_CMD` launched nothing and said nothing. The resync dialog's
  buttons followed the system locale rather than `UI_LANG`. The single-instance lock file was left
  behind on every exit. And the icon was handed to the indicator twice at startup and again on
  every poll even when nothing had changed.
- Three smaller defects in the same file, found while reviewing those fixes: a failed write of the
  folder list reported "Could not read the folder list" and left the tick disagreeing with
  `exclude-folders.txt`; `unit_states` treated systemd's `enabled-runtime` as off; and the resync
  command quoted the script path by hand instead of using `shlex.quote`.
- `onedrive-check` had eight defects, all found by attacking it rather than reading it. A trailing
  slash on `LOCAL` defeated the relative-path strip, which suppressed the whole "too long" group and
  made a tree with 520-character paths report "nothing to fix" and exit 0. `--max` was not
  validated, so `--max abc` printed every entry and leaked `integer expected` into stderr. A newline
  inside a file name truncated the rename scan. A directory that could not be read was silently
  skipped, so an incomplete walk looked like a clean tree. Four of rclone's encoding classes were
  missing from the renamed group: a leading `~`, control characters, `0x7f` and bytes that are not
  valid UTF-8. Reserved names matched only the whole name, so `CON.txt` and `aux.md` slipped through.
  A missing `LOCAL` exited 1 with a raw bash error instead of the documented 2, and the closing
  count counted a path twice when it appeared in two groups. Verified per defect against fixtures
  that reproduce each one, plus a differential run showing the verdicts for the pre-existing
  classes are unchanged.
- `onedrive-check` was also slow: it started one `grep` process per path component, so 20,200 items
  took about 30 seconds and a 300,000-item account would have taken minutes. The check is now bash
  pattern matching, measured at 3.4 seconds for the same tree, about 8.8 times faster.
- The delete cap did not cap anything, which is the one defect here that could lose data. rclone
  bisync reads `--max-delete` as a percentage of the file pair, while `MAX_DELETE` and the
  documentation promise a file count, so the shipped `MAX_DELETE="100"` allowed every deletion.
  Measured on rclone 1.75.1: with 250 of 300 files deleted locally, `--max-delete 100` exited 0 and
  propagated the deletions to the other side in both directions, while `--max-delete 5` aborted with
  "Safety abort: too many deletes (>5%, 150 of 200)". The wrapper now converts the configured count
  into the equivalent percentage using the size of the pair from rclone's own listing, and falls
  back to a small cap when it cannot measure one. End to end afterwards: `MAX_DELETE=100` over a
  200-file pair aborted and left the far side untouched, and `MAX_DELETE=200` let the same 150
  deletions through as intended.
- The `[maxdelete]` hint never fired, because rclone words the abort as "too many deletes" and the
  pattern looked for `max-delete`. Adding that literal then made every unrelated failure report a
  delete cap, because the wrapper logs its own `--max-delete N%` line before each run; the match is
  now on the abort wording only. `onedrive-sync --force` exists so the hint can name the way
  forward, and `--resync`, `--dry-run` and `--verbose` are passed through too.
- `uninstall.sh` and `install.sh` now compare `HOME` against the password database before touching
  the machine-wide NetworkManager hook. A test that redirects `HOME` while keeping the default unit
  name used to look exactly like the main install.
- Personal data in a published file: `docs/TROUBLESHOOTING.md` carried a real OneDrive drive
  identifier in three places, twice as the literal argument of a fix command. Replaced with
  placeholders.
- Documentation that contradicted the code, all found by reading the published tree: the example
  filter rule in both READMEs was quoted, which is the exact mistake that made the shipped rules
  inert; `config/config.example` said a deselected folder's local copy is deleted, which is the
  opposite of the measured behaviour; `docs/TROUBLESHOOTING.md` recommended the fixed `/tmp` lock
  file this project moved away from, and stated that any `--exclude` needs a resync, which is not
  true of the tray's folder selection; the Chinese README managed both "two test scripts" and "four
  test scripts" in the same section; the changelog said two suites and then three. `tests/docs.sh`
  now checks the count claim in the changelog and in the Chinese README as well.
- `install.sh` could enable and start a unit belonging to another installation. It wrote the units
  into the configured directory and then ran `systemctl --user enable --now`, but the user manager
  reads its own search path: with `XDG_CONFIG_HOME` redirected it never sees those files, while a
  same-named unit from the real install is still visible, and that is the one that gets started.
  It now asks systemd for the unit's fragment path first and refuses to enable anything it does not
  own. Found by a fresh-eyes install into a sandbox.
- `uninstall.sh` removed `/etc/NetworkManager/dispatcher.d/90-rclone-onedrive-tray` regardless of
  which install was being removed, because the hook is one machine-wide file that names a unit. It
  now only touches it when the install is the default one and the hook names the unit being
  uninstalled. The test suite had been running that code path with the real `sudo`, which happened
  to fail with no terminal; `tests/install-flow.sh` now stubs `sudo` so it cannot reach `/etc` at
  all.
- `setup.sh --yes` with no rclone remote started the browser sign-in and blocked forever, with the
  terminal showing nothing and no config written. A non-interactive run now stops and says how to
  create a remote first, including an account-free trial remote.
- `onedrive-tray` aborted with a core dump when there was no display, because GTK does that rather
  than returning an error. It now checks `DISPLAY` and `WAYLAND_DISPLAY` first and explains that a
  server wants `onedrive-sync` and the timer.
- `onedrive-tray` printed "already running" and exited 0 when its lock file could not be created at
  all, so an unusable `TMPDIR` looked like a second copy of the tray. The two cases are told apart
  and the second one exits non-zero with the path it could not write.
- `onedrive-check --help` was cut off mid-sentence: the header comment had grown past the hard-coded
  line range in its own `usage()`.
- The default filter rules did not work. Every pattern in `config/filters.example` was wrapped in
  single quotes on the assumption that a shell would read the file, and rclone reads it itself, so
  `- '*.tmp'` was a pattern beginning with an apostrophe. Temp files, swap files, editor backups
  and `__pycache__` were synced despite the rules that were supposed to stop them. The quotes are
  gone, and `tests/filters.sh` now runs rclone over a fixture tree so a rule that stops working
  fails the build.
- `- .Trash-*` never excluded anything inside `.Trash-1000`. rclone still walks into a directory it
  excludes, so the contents need the `/**` as well. It is `- .Trash-*/**` now, which the same test
  covers.
- An rclone older than the flags in `BISYNC_ARGS` rejected them before opening its log file, so
  `onedrive-sync` reported `[other] see log` and pointed at a log with nothing in it. It now copies
  rclone's stderr into its own log and reports `[oldrclone]` naming the version requirement.
- The lock file moved from a fixed `/tmp/onedrive-sync.lock` to `$CACHE_DIR/sync.lck`. A shared
  name serialised every configuration on the machine against each other, and `/tmp` is
  world-writable, so any local user could have held the lock and stalled the timer.

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
