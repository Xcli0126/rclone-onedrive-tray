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

Nothing. What follows is decisions rather than work: each one was found by a review,
measured, and settled one way or the other, and the reason is written down so it does
not have to be rediscovered.

## Accepted, with the reason

- The tray and the two shells disagree about one environment none of the shipped ways of
  starting them produces: `HOME` unset with the `XDG_*` variables also unset. Measured
  with `HOME` unset: `bin/onedrive-sync` stops at line 32 with `HOME: unbound variable`
  and exit 1, and with `XDG_CONFIG_HOME` given it stops at line 34 with the same message,
  so it needs `XDG_CONFIG_HOME` and `XDG_CACHE_HOME` to run at all; `bin/onedrive-doctor`
  needs a third, stopping at line 36 until `XDG_STATE_HOME` is set as well; the tray's
  three directory constants use `XDG_CONFIG_HOME`, `XDG_CACHE_HOME` and `XDG_DATA_HOME`,
  and its `expanduser` answers the passwd home where a shell would stop. With all four
  variables set, all three run and agree, and `HOME` empty has them agreeing on
  `/.cache/rclone-onedrive-tray`. It is recorded rather than guarded because a guard would
  have to refuse a tray that works: with the four set, no shipped script expands `HOME`
  unless a config value spells a `~`; autostart, a systemd unit and a login session all
  set `HOME` anyway.

- A line that assigns and then runs a command is read as the assignment. `KEY=a true`
  leaves `KEY` unset in the shell that sources the file - the assignment is a prefix of
  the command, not a setting - while the tray reads `a`, which is what it does with any
  other line. Modelling it would mean the reader deciding for every line whether it is a
  command, and the shape is not a config value in any useful sense; it is written down
  rather than guessed at. The value half of the same line is fixed: an unquoted value
  ends at its first space, quotes and backslashes are removed the way bash removes them,
  and a tilde is expanded before them, where the shell expands one - `~`, `~/...`, a
  `~user` that exists, and any of those after a `:`. A tilde the reader leaves alone
  (`~+`, `~-`, `~~`) is refused by `local_path_problem()` wherever it stands in a `LOCAL`,
  rather than resolved into a directory the wrapper would never sync.
- A parameter form this reader does not implement is left exactly as the file wrote
  it. `shell_value()` answers `$VAR`, `${VAR}`, `${VAR:-word}`, `${VAR-word}`,
  `${VAR:+word}`, `${VAR:=word}`, a nested expansion inside the word, and the quoting
  of that word; `${VAR:?message}`, `${VAR:offset}` and `${VAR:offset:length}` are
  printed back as written, and so are the forms this reader has no answer for at all:
  `${A#prefix}`, `${A%suffix}`, `${#A}`, a backtick and an unterminated `${`. Tests
  pin all five, and pin the reason it is safe: the tray parses a config rather than
  running one, so a `$(command)` or a backtick in a value stays text as far as the tray
  is concerned. The shell that sources the same file does run it, as it did before the
  tray read the value at all, and the wizard carries such a line as the file has it. A value nested more than twenty expansions deep is also left as written,
  which is a limit rather than an answer: without it a file holding thousands of
  `${A:-` recursed until Python raised. Answering those forms would mean a shell, and a shell for a
  config value the tray only ever reads as a path or a command line is a bigger thing
  than the three forms are worth. Three smaller differences sit beside it. A line that
  assigns and then runs a command leaves the key unset in the shell while the tray
  reads the assignment. An ANSI-C word (`KEY=$'a\tb'`) is read as the dollar sign
  followed by a single-quoted string, so the tray answers `$a\tb` where the shell
  answers a tab: the form is C escapes, which this reader does not implement, and it is
  measured rather than assumed. A value quoted across two lines (`KEY="one<newline>two"`)
  is read as its first line, because the parser is line-based; bash reads both, and a
  wizard re-run repairs the line to what this reader sees, which the changelog's carry
  entry describes. A variable's own value is inserted as it stands, as bash inserts it.

- `Tray` stays one class. The audit that suggested splitting it into a menu class
  and a status class was right that it is 900 lines, and wrong that the size is the
  problem: what the class holds is one widget tree whose parts are wired to each
  other (the menu items call the tray's actions, the poll reads and writes the same
  rows, the settings hand-off replaces them), and the suite reaches those parts by
  name in ninety cases. A split would either move the names and change ninety cases
  or add properties that forward to the new object, which is indirection without a
  user on the other end. The decision the ledger entry asked for is this: a test may
  touch the tray's own attributes, and the class stays one until a change makes the
  seam obvious rather than theoretical.
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
