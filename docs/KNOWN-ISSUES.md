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
### What the pause redesign left

The meta-review of the pause commit found, in its interim report, that the migration
did not repair what it was for (fixed, with a case that drives the shape where the
units are still disabled), that "Resume now" announced a resume it had not done
(fixed), and that the pause commit wrote four corrupted lines into
`tests/lib/mutations.txt` (removed). What is left:

- The dead `systemd-run` stubs and markers in `tests/tray.sh` are still there: no
  code reads them since the pause stopped arming a transient timer, and a fixture
  that nothing reads is a place the next reader looks for behaviour that is gone.
  `docs/DEPENDENCIES.md` also still lists the transient timer in its systemd row.
- The mutation row `tray-setunits-invalidate` survives now: `_auto_state` reads the
  stamp before it reads `timer_state`, so the `_units_changed()` inside `_set_units`
  is no longer load-bearing and nothing notices its removal. A full sweep is red for
  that reason, which the `KNOWN_SURVIVORS` mechanism can excuse only if the row is a
  decision rather than a line nobody needs. Measured: `s|        elif due is not
  None:|        elif False:|` is caught (288 passed, 3 failed), so the tray half of
  the pause can have a row after all, and the previous round's claim that sed could
  not express one was wrong.
- "Sync now" during a pause is a silent no-op: the wrapper exits 0 without invoking
  rclone and writes no result line, so the menu gives no sign that the request was
  refused. Under the old design the units were stopped, so the request started them
  and really synced. Either the item says it is paused, or the wrapper's refusal is
  what the tray reports.
- The stamp is written with a truncating `open(..., "w")` although `write_atomic()`
  exists two hundred lines above, and an empty read is "not a time", so a pause
  written while the file is being truncated is deleted and the run syncs.
- The pause check sits before the log rotation, so an install that spends its life
  paused never rotates its log, and the file the cap exists for grows without it.

### What the last meta-review found in the newest commits

Round nineteen's meta-review audited the two commits before it, and found eleven
things, three of them the newest work's own. Its patch covers most of them and is
not applied yet; they are listed here so the next round starts from the list rather
than from a re-reading.

- `install.sh` refuses `INTERVAL_MIN="0"` but not `"00"` or `"000"`: the unit then
  ships `OnUnitInactiveSec=00min`, which systemd reads as zero, which is the sync
  loop the validation was written to close. The changelog's "or is zero" is false.
- `write_atomic()` opens the config path with a blocking `O_WRONLY`, so the write
  side of the guard added for the read side stopped one file short: an
  `EXCLUDE_FOLDERS_FILE` fifo freezes the tray from a GTK `toggled` handler. The
  fix is `O_NONBLOCK` on that open, which raises `ENXIO` at once on a fifo.
- The new "`LOG` is not a regular file" failure hits `LOG=/dev/null`, which the
  wrapper handles perfectly well, so a working install is now called broken; the
  same program's older log row already treats a device as a warning.
- Three user-facing pages still carry the systemd premise that was corrected in the
  unit and in the wrapper's header this round.
- Two comments the same commit wrote are false: `lib/config.sh` says the shell
  scripts read no path key with a variable in it, and `setup.sh` now reads `LOG`
  through it; and "both treat it as a failure with the reason" is true of the
  doctor and not of the tray, which returns an empty list silently.
- One page still says three readers of the config, and the changelog claims the
  pages say four.
- The three NetworkManager hook cases pin the hook's text rather than its
  behaviour: commenting the gate out - its text and its position kept, which is
  exactly the old behaviour - leaves the whole of install-flow green. The hook is
  not executed by any suite, so it wants a fixture with a stub `systemctl`.
- `install-flow.sh` has a conjunct that can never match: `report()` pads its verdict
  with `%-4s`, so the line reads `ok   logfile` and `^ok logfile` never does.
- `KNOWN_SURVIVORS` excuses a row by id with nothing checking that the id exists or
  that its reason still holds.
- The drop-in's trailing-comment and trailing-whitespace strip has no case of its
  own; the only fixture is a bare value.

### What the loop's own fixes left behind

Round seventeen's meta-review looked for the harm a long series of local fixes does,
and found it. Most of it is fixed and in the changelog: the fifo and directory guards
that stopped one file short (`EXCLUDE_FOLDERS_FILE`), the doctor's `logfile` row that
called a directory writable while the wrapper refused it, `setup.sh` as a fourth
reader of the config with both faults the shared reader had lost, and a case the loop
had added that could not fail. Two things are still open, and one correction:

- Two guards for one thing: `_local_delete_path` re-checks the filesystem root after
  `local_path_problem` has already refused it, and the case that covers it
  monkeypatches the first guard away to reach the second. One of the two is dead, and
  the mutation row pins the dead one, so removing it means deciding which guard is
  the contract.
- Two tray cases pin source identifiers rather than behaviour: renaming the
  module-level `STRINGS` fails five cases, one of them unrelated to languages. A
  rename is a refactor, and a suite that fails on one is a suite that costs more to
  change than it is worth.
- The tray's guard for a non-regular `EXCLUDE_FOLDERS_FILE` has no case of its own:
  the doctor's is covered by a fixture that carries a twenty second clock, and the
  tray's would need the same clock inside the driver rather than a suite that hangs
  without it. The code is there for the reason `tail_text()` gives, and the doctor's
  case is what pins the rule.
- Correction to an earlier entry: the count of config readers was never three.
  `onedrive-doctor` sources the file as well, so with `lib/config.sh` shared by the
  three shell scripts that may not execute it, the readers are four: the tray's
  parser, the wrapper, the doctor, and the shared sed reader. The pages that said
  three were wrong when they were written.
- A wizard re-run still re-escapes a carried `${VAR}` value, so a config holding
  `LOG="${XDG_CACHE_HOME:-$HOME/.cache}/sync.log"` is written back with the variable
  frozen into a literal path. It is pre-existing, the reviewer proved it against the
  old reader as well, and the fix is a decision: write carried values raw, or expand
  them as the shell would.

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

- A lone CR is read differently by the two readers of the log, and the tray's answer
  is the one that stays. Python's `splitlines()` breaks on `\r` and grep does not, so
  one file holding CR-separated lines gives the tray a synced run and the doctor a
  failure. The tray also treats a marker whose `msg=` contains a failure's own prose
  as the newer verdict, which is deliberate and tested; changing either to agree
  would mean dropping one of those two rules for a shape no writer in this project
  produces, since `log_line` ends every line with `\n`. Round sixteen's log reviewer
  measured it, left it unfixed, and this is the reason.
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
