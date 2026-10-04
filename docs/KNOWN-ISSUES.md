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
### A failing run costs more than it should, three ways

Round eleven's third reviewer ran the tray and the timer as a long-lived pair and
measured what accumulates. Three things did, all reproduced, none fixed yet.

- The tray announces the same failure again on every run. The guard compares
  `(when, tag, raw)` against the last one it announced, and `when` is the failing
  run's own clock, so two runs of the same failure five minutes apart never match
  and the branch whose own comment says the same failure is not announced twice
  never fires. Measured against a real notification service on a private session:
  30 failing runs, 30 toasts; the same 30 with a constant `when`, one toast. A
  five minute timer makes that 288 a day of the identical message.
- The watcher unit is the project's only `Restart=always`, and the watcher exits 1
  on purpose after three permanent `inotifywait` failures. With the documented
  `WATCH_EXCLUDE="["` the cycle is 3 restarts in 4.0 seconds plus `RestartSec=5`,
  so roughly 9,600 restarts and 24 MB of journal a day, and systemd's own start
  limiter (burst 5 in a 10 second window by default) never trips.
- A failing sync writes about 413 bytes of journal per run and a healthy one
  writes none, and no file in the project names any journal bound.


### Four parsers for one file format

`install.sh` and `uninstall.sh` read the config with `sed`, the tray parses it in
Python, and `onedrive-sync` sources it with `.`. They agree about the escaping now:
the tray writes `\`, `"`, `$` and the backtick escaped, and both sed readers undo
exactly that, so a value the tray wrote is read back whole instead of being cut at
the first inner quote. What is left is the count: a new key has to be taught to all
four, and `EXCLUDE_FOLDERS_FILE` is read by two of them in different ways.

Cost: a key added to one reader and forgotten in another is invisible until a user
hits it. The fix worth doing is one reader, which is a new runtime file and pulls
the installers and the documentation along with it; that is larger than the cost of
the remaining duplication, so the four stay and the escaping is what had to agree.

### Non-GNU userlands are a guess

`stat -c%s` in the wrapper's log rotation, `getent passwd` in the installer,
`find -mindepth` in the checker, `sed -i` in a test fixture, `install -o root -g
root`, `nl -w2`, and two `mktemp` calls without a template.

On BusyBox the log rotation stops happening, because `stat -c%s` fails and the
`|| echo 0` beside it turns the failure into a zero-size log, so the 5 MiB cap
stops being a cap. The checker's walk returns nothing and reports an incomplete
walk, which reads as a permissions problem rather than an unsupported option.

The supported target is Ubuntu, and [COMPATIBILITY](COMPATIBILITY.md) says so.
Changing this is a support-matrix decision rather than a cleanup.

### `Tray` is one 900-line class

Menu construction, the three-second poll, the six actions, the folder submenu and
the settings hand-off all live in one class in `bin/onedrive-tray`. The audit's
suggestion is a `TrayMenu` holding the widgets and the `_build_*` methods, which
would roughly halve it.

It moves attributes the test suite reaches into directly (`tray.menu`,
`tray.item_status`, `tray.pause`, `tray.ind`), so it needs a decision about what a
test is allowed to touch before anyone starts.


## Accepted, with the reason

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
