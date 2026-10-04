# Known issues

What this project knows is wrong, unproven, or deliberately left alone. It is not
the same page as [TROUBLESHOOTING](TROUBLESHOOTING.md): that one is for a user
whose sync has stopped, this one is for the code itself.

Everything found and fixed goes in `CHANGELOG.md`. What stays here is the work
that was reported and not done, with the reason, so it does not have to be
rediscovered. An audit of the tree at the 1.2.0 release produced 22 ranked
findings and fixed 19 of them, a second pass by a different model at 1.3.0 found
twelve more and fixed all of them, and the same loop of review and fix has run
since, closing what each round found apart from what is written down below. Each
round uses a different model with a different lens, which is how the entries here
were found in the first place.

## Open
### The pause can outlive the tray, and four other systemd problems

Round sixteen's systemd reviewer read the three units, the interval drop-in, the
transient pause timer and the NetworkManager hook against upstream systemd 259 and
this machine's man pages. Ten findings came out. Three of them have a fix in that
reviewer's patch and are listed here with the rest because none is applied yet:
validating `INTERVAL_MIN`, comparing the whole drop-in value rather than one
spelling of it, and making the hook ask the timer before it starts a sync.

- A pause is stored as "the units are disabled" plus a transient `systemd-run`
  timer, and only the tray can undo it. With the tray not running (no GTK, the
  autostart box unticked, a headless machine) a reboot during a pause leaves nothing
  syncing, forever, and a disabled timer looks like a deliberate off. In the other
  direction `install.sh` enables both units on every run, so `git pull &&
  ./install.sh` silently ends a pause. The stamp the tray writes is the only record
  of which it was, and the poll deletes that stamp when `is-enabled` answers
  something the code does not know.
- `INTERVAL_MIN` reaches `OnUnitInactiveSec` unvalidated. A value systemd cannot
  parse is dropped with a warning and leaves `OnActiveSec=2min` as the timer's only
  trigger, which fires once per login; `0` asks for `0min`, which is past due the
  moment it is armed, so the sync re-triggers after every run.
- The NetworkManager hook starts the sync service on any link-up without asking the
  timer, so a paused install syncs on every wifi, dock or VPN event.
- The sync service sets no `TimeoutStopSec`, so the manager's 90 second default
  applies to a `oneshot` bisync that can run longer: a shutdown or a logout with
  lingering off can SIGTERM it and SIGKILL it 90 seconds later. The comment in the
  unit template has the premise backwards, because the manager's default for
  `Type=oneshot` is no timeout at all, so the directive adds a cap rather than
  restoring one.
- Pause and resume re-enable the watcher without reading `WATCH`, so a user who had
  realtime sync off gets it back after any pause, and the resume timer is recognised
  by matching the English `Running timer` in `systemd-run`'s stderr, which is the
  locale-dependent match this project removed from the log readers.

### The panel's state is only in pixels

Round sixteen's accessibility reviewer walked the real menu and the real settings
dialog with ATK, on a private Broadway display, and measured what a screen reader
gets. The fix for the first finding is in that reviewer's patch, with a test that
drives it; these are the rest, and the whole set is one pass of work rather than
eight.

- The tray's state has no text channel. The AppIndicator is not a `Gtk.Widget`, so
  it has no ATK object at all: `get_title()` is null in every state and
  `get_icon_desc()` is the constant "OneDrive" whether the icon is syncing, failed
  or paused. Six states (syncing with a percentage, error with a reason, paused
  until a time, automatic sync off, timer unknown, icon hidden) are conveyed by
  colour and a badge and by nothing else. `set_label`, `set_title` and
  `set_attention_icon` exist for exactly this and were never called. The patched
  version publishes the same sentence the status row carries.
- The one sentence that spells the state out is an insensitive menu item, and GTK's
  arrow keys skip insensitive items: 20 presses of Down select 13 items and never
  reach `menu/0` or `menu/1`. The menu's own accessible name is null too.
- In the settings dialog both spin buttons have accessible name `None` (a reader
  announces a bare "5.0"), and both combo boxes are named after their current
  selection, so the Language row is called "English" and the bandwidth row
  "Unlimited". None of the 15 controls has an ATK relation to its label, and no
  label carries a mnemonic: the dialog cannot be driven from the keyboard.
- The dialog has no default action, and all three modal dialogs announce as their
  message type ("Sign in again?" reads as "Question") with no default button.
- A successful Save is indistinguishable from Cancel in the accessible tree: the
  same names, an empty status line, and the window disappears either way.
- The access-check warning appears as a plain label with no alert node, so nothing
  announces it.

### `Tray` is one 900-line class

Menu construction, the three-second poll, the six actions, the folder submenu and
the settings hand-off all live in one class in `bin/onedrive-tray`. The audit's
suggestion is a `TrayMenu` holding the widgets and the `_build_*` methods, which
would roughly halve it.

It moves attributes the test suite reaches into directly (`tray.menu`,
`tray.item_status`, `tray.pause`, `tray.ind`), so it needs a decision about what a
test is allowed to touch before anyone starts.


## Accepted, with the reason

- One format, three readers, and the agreement is a test rather than a promise. The
  entry here used to count four readers of the config file and call the count the
  remaining cost. What changed is that the two installers share one implementation,
  `lib/config.sh`, so a change to the format cannot land in one of them and not the
  other, and the tray's parser is held to what bash does by
  `tests/dependency-matrix.sh`, which reads one file three ways and compares the
  answers. The three are there for reasons rather than by accident: the tray parses
  the file without executing it, because a config it did not write should not run;
  `onedrive-sync` sources it with `.`, because the shipped example expands variables
  and only a shell does that; and the installers may not execute a config they are
  about to replace or remove, which is why they use `sed`. What is left is the
  count, and a new key still has to be read by whichever of the three wants it.
- The tools' own report text is English, and that is now the same answer in the
  GUI. `onedrive-check-access`'s report inside the settings window, and
  `onedrive-doctor`'s rows inside the Diagnostics window, are English blocks with
  Chinese labels and buttons around them. The alternative is translating two
  programs' output, and every row of it is a sentence about rclone's or systemd's
  own English, which a translation would have to leave in place anyway. The tray's
  own windows are fully translated; what is not is the output of a command-line
  tool the tray runs, and `onedrive-check` already declared that about itself
  before this was found. The tray's own command-line and stderr text is English
  for the same reason: it is read in a terminal, and no page promises otherwise.
- A GNU userland is a requirement rather than an accident. The shell half uses
  `stat -c`, `find -mindepth`, `sed -i`, `getent passwd`, `install -o`, `nl -w2`
  and a `mktemp` with no template, and the supported target is Ubuntu, which has
  all of them. BusyBox and the BSD userlands stay untested and unsupported, and
  `docs/DEPENDENCIES.md` says so where a reader looks for what the project needs,
  which is where the entry was missing an answer. The one failure in that list
  which was silent is fixed: the wrapper took the log's size from `stat -c%s` and
  the `|| echo 0` beside it turned an unreadable size into a zero byte log, so the
  cap stopped being a cap on a userland without it. The size comes from `wc -c`
  now, which every userland has, and a size it cannot read is a warning in the
  log. The rest of the list is closed as a requirement rather than a cleanup.
- The tray writes a failure to read its config, and a failure to write its icons,
  to stderr, and says the icon problem once rather than once per poll. A launch
  from a desktop entry gives stderr no window, which is why the two facts are also
  visible where the user would go looking: the tray refuses to start on a config
  it cannot read instead of running on the defaults, and `onedrive-doctor` tells a
  directory holding icons from one holding none. A notification was the
  alternative and it is the wrong channel for "the icon is blank".
- `install.sh` warns about a unit pair left by an earlier `UNIT_NAME` or
  `--prefix`, rather than disabling it. What was wrong there was the warning, and
  that is fixed: it names every file this installer writes under the old name and
  prints the `systemctl --user disable --now` line for both halves of the pair.
  Turning the pair off stays `uninstall.sh`'s job, which does it. An install that
  disabled units it is no longer managing would also break the promise
  `docs/UPDATING.md` makes, that an update does not interrupt a sync already
  running: `disable --now` on the watcher kills that loop outright, and the
  watcher is the half that would be running a sync at the time.
- One sync pair per user account, and the three names that decide it. The entry
  here used to say that a second pair would collide on the wrapper's lock, the
  tray's pause stamp and the tray's single-instance lock, and that either those
  names get the unit name appended or the single-pair limit becomes a decision.
  The limit is the decision, because the three names are not what makes it one:
  `~/.config/rclone-onedrive-tray/config` holds a single `REMOTE` and `LOCAL`, so
  two pairs in a session would have one config between them whatever the lock
  files are called, and the units of a second copy land in a directory the user
  manager does not read. That is written down for the user now, in
  `docs/COMPATIBILITY.md` and in both READMEs, which is what was missing.
  Appending the unit name to three files would have left the config as the real
  obstacle and moved the failure somewhere harder to find.
- The prose in the shared log is now the fallback rather than the source of truth.
  Every run ends with one machine-readable line (`ONEDRIVE_RESULT v=1 state=…
  tag=… when=HH:MM msg=…`), and both the tray and the doctor read that first. The
  English scan stays for two things it is the only answer to: a log written by an
  older version of the wrapper, and a run killed after rclone wrote but before the
  wrapper could. The doctor also keeps its own copy of the pattern table for the
  same reason, and `tests/docs.sh` holds the two copies equal. What is left of the
  original entry is the doctor's classification of a marker-less log, which the
  table it owns is what lets it do.
- `onedrive-check`'s name-length branch cannot fire on a local filesystem: the
  limit is the documented 255, and a filesystem refuses a name longer than 255
  bytes, so nothing on disk can reach it. It was found by mutating the limit to
  99999 and watching every suite stay green. The branch is kept for filesystems
  that allow longer names and is deliberately untested, because there is nothing to
  test it with; the mutation row that keeps the limit honest is the coverage it has.
- `onedrive-doctor` reads the tray's pid from `/proc/locks`, which is Linux only.
  Where that file is absent or unreadable the line says `pid unknown`, and the
  verdict itself comes from `flock` on the tray's own lock file, which is portable.
  The pid is a nicety on top of a correct answer, so the lookup stays and its limit
  is written down here rather than left as an open item.
- `NOTIFY_ON_SUCCESS` covers a sync you start from the tray, not the scheduled
  runs. The window says so ("Tell me when a sync I start succeeds"), and the
  reason is that a five-minute timer announcing every success would train people
  to ignore the notifications that matter. A failure always notifies. Whether a
  scheduled run that recovers from an earlier failure deserves one is a fair
  question and is not implemented.
- `rclone bisync` is experimental upstream. See the "Known limitations" section of
  the README.
- The panel icon needs an AppIndicator-compatible shell, which on stock GNOME
  means an extension. See the README.
- No per-file status in the file manager, no version history, no recycle bin.
  Each needs a Nautilus or Dolphin extension or a Microsoft service API, and
  [FEATURE-PARITY](FEATURE-PARITY.md) explains why they are out of scope.
- `SHOW_ICON` is read as one of the truthy spellings, so a hand-edited value that
  is none of them hides the icon rather than being guessed at. The settings window
  writes `1` or `0`, and `onedrive-tray --settings` still opens the window without
  an icon to click, so an unrecognised value is treated as off and the user can
  get back in from a terminal.
- `BISYNC_ARGS` is split on whitespace, not read by a shell, so a pattern with a
  space in it cannot be written there: `--exclude "/My Docs/**"` arrives as three
  words and one of them is a stray argument rclone refuses. A token that begins or
  ends with a quote is refused at the start of a run with this key named, and
  `config.example` says where such a pattern belongs instead. A shell-like split
  (shlex) is the alternative and is not implemented, because the value is a list of
  rclone flags rather than a shell command.
- The yes/no keys (`WATCH`, `CHECK_ACCESS`, `SHOW_ICON`, `NOTIFY_ON_SUCCESS`) accept
  `1`, `true`, `yes`, `on` or `enabled` for on, and anything else for off, in the
  wrapper, the doctor, the tray and `install.sh`. Only `1` and `0` are documented,
  and `enabled` was invented by the wrapper alone, which is how it came to read a
  config as on while the tray read the same value as off and a Save wrote `0` over
  it. The readers were brought onto one list rather than the spelling being
  removed, because a user who has it in their config would otherwise lose the
  access check without being told. Each reader has a case for the spelling it
  gained, so a drift shows up as a failing case rather than as a lost setting.
