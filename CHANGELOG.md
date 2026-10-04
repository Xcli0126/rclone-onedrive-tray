# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Every run now ends with one machine-readable line of its own:
  `ONEDRIVE_RESULT v=1 state=<synced|error|stopped> tag=<tag|none> when=HH:MM
  msg=<sentence>`. The tray reads it for the icon, the time and the reason it
  gives, and `onedrive-doctor` reads it to classify the log, instead of both of
  them matching English fragments in a file rclone also writes. `state=stopped` is
  a failure class a rerun cannot clear, `state=error` is a run that used up its
  attempts, and `tag=` carries the same class the `[tag]` hints use. The English
  scan is still there and is what answers for a log written by an older version, or
  by a run killed after rclone wrote and before the wrapper could, and
  `tests/docs.sh` now holds the field names in the three files together so a rename
  in one cannot leave the others silently on the fallback.
- The suites run on two GitHub runners, `ubuntu-latest` and `ubuntu-22.04`, with
  `fail-fast` off. It found a real portability defect on its first run: a test
  imported `GioUnix`, which only exists from GLib 2.80, so it died on 22.04's
  GLib 2.72 before checking anything.
- `tests/lib/mutate.sh` and `tests/lib/mutations.txt`: deliberate changes to the
  shipped scripts, applied one at a time against the suite that covers them, to
  find behaviour no test would notice. The run prints the tally; the one row that
  survives is a branch in `onedrive-check` that a local filesystem cannot reach,
  which is written down in `docs/KNOWN-ISSUES.md` rather than assumed tested.
- `Diagnostics…` in the tray menu runs `onedrive-doctor` and shows its report in
  the dialog the name check already uses. The README's first instruction when
  something looks wrong was reachable only from a terminal until now, which is the
  opposite of what the tray is for.
- `tests/lib/mutate.sh --lint` checks the mutation table itself, in a second
  rather than in a sweep: every row names a file that exists and a suite that
  exists, `sed` accepts its expression, the expression still changes that file, and
  no range is addressed by an empty line. CI runs it beside `--self-test`. A row
  whose expression quietly stopped matching mutates nothing, so the sweep can only
  report it as skipped hours later. Three rows were in that state: the one for the
  invalidation inside `_set_units()` stopped matching when a docstring gained a
  blank line, because a sed range ending on `^$` stops at the first blank line of the
  block it aims at; `setup-access-check-carry` named a `setup.sh` line that this
  release rewrote, and was re-pointed in the same commit that rewrote it; and
  `docs-duplicate-heading` had been dropped with a reason that was false, "SURVIVED,
  so the suite must read a different copy", when the harness had been reporting
  SKIPPED for it - the heading it renamed had been deleted a few hours earlier, in a
  repository whose first commit is a day old. All three point at lines that exist now,
  and the restored one is caught. The lint cannot see
  a row that mutates the wrong occurrence of the line it names, or one pointed at a
  suite that does not cover the behaviour; `docs/COMPATIBILITY.md` says so rather
  than leaving the check looking stronger than it is.

### Fixed

- The wizard no longer carries a line it cannot carry whole. Writing the old file's
  own line fixed the frozen `$` above, and the first version took any line that
  started with the key: a value written over two lines is valid shell, so
  `OPEN_APP_CMD="one` went into the new config on its own, the file stopped being
  shell, and the wizard still printed "Wrote" and exited 0. A line is carried when it
  is the whole assignment - it ends outside both kinds of quote and is not continued
  onto the next line - and otherwise the writer falls back to the value the reader can
  see, which closes the quote or drops the continuation. Everything a whole line says
  is carried as it stands, including forms this writer would have quoted differently:
  the second version accepted only `KEY=word` and `KEY="one string"` and sent the rest
  through the quoting path, which froze an unquoted `${XDG_CACHE_HOME:-...}` path, lost
  the expansion in a value holding both a quote and a `$VAR`, and truncated a
  single-quoted value at its first space.
- The config the wizard writes is checked with `bash -n` in a side file before it
  replaces the one on disk, and the two values it writes unquoted are validated rather
  than carried blind: `WATCH` has to be a 0 or a 1 and `INTERVAL_MIN` a whole number
  of minutes, or the wizard writes the default and says so. A hand-written `WATCH='a"b'`
  used to be assembled into a file that no longer sourced, and an `INTERVAL_MIN`
  holding shell syntax was assembled into a file `bash -n` calls valid: that is a
  command in a file the wrapper runs with `.`, so the check is on the value rather than
  on the file. Measured over both shapes: the wizard finishes, the file is shell, the
  key holds the default, and sourcing it runs nothing the old value contained. When the
  gate does refuse, the message says what is and is not left alone: the config is
  untouched, and the folder list this run wrote is already in place.
- A `LOCAL` with a tilde in it, or with a space at either end, is refused instead of
  expanded. `. config` in bash does not expand a tilde inside a value, so
  `LOCAL="~/OneDrive"` gives `onedrive-sync` an eleven-character relative path and it
  refuses the run; expanding it made the tray describe a directory nothing syncs. The
  delete guard is where that mattered: with `LOCAL="~/.."` and the process in `/` it
  read `~` as an ordinary directory name, landed on the filesystem root, and handed
  back `/etc` for the folder `etc`, one confirmation dialog away from `shutil.rmtree`
  - measured on the version before this change, with the tray's own module and cwd `/`:
  `local_path_problem("~/..") == ""` and `_local_delete_path("etc") == "/etc"`. The
  first attempt at this expanded the tilde in the guard instead, which closed `/etc`
  and opened `$HOME`: a folder named like the user came back as the home directory.
  The value is refused at the source now, so every reader of it - the guard, the
  settings dialog, the wrapper - is looking at the same path, and the root check inside
  the guard is back as the net for the next time two resolutions drift apart.
- The tray expands a variable inside the fallback of `${VAR:-fallback}`, and follows
  the braces of one expansion inside another. The shipped
  `LOG="${XDG_CACHE_HOME:-$HOME/.cache}/..."` read as a path with a literal `$HOME` in
  it whenever `XDG_CACHE_HOME` was unset, which is the default on a stock desktop, so
  the tray named a log file the wrapper never wrote. `${VAR-word}` and `${VAR:+word}`
  are answered too; `${VAR:?message}`, `${VAR:offset}` and `${VAR:offset:length}` are
  left exactly as the file wrote them, which is visible rather than silently wrong and
  is recorded in `docs/KNOWN-ISSUES.md` with the reason.
- The NetworkManager hook's cases run the hook. They read its lines before - the
  `is-enabled --quiet` gate, the unit name, and that the gate comes before the start -
  and neutering the gate while keeping its text and position left all of them green, so
  a hook that asked nothing and started the service anyway passed every case. The new
  fixture executes the installed hook under `unshare -rm` with a tmpfs on `/run` and
  `id`, `getent`, `runuser` and `systemctl` stubbed to answer for one user: with the
  timer enabled the gate asks and then starts the service, with it disabled the hook
  asks and starts nothing, and a user with no unit file gets no call at all. CI asserts
  that a user namespace can be created, so the fixture cannot turn into a silent skip.
- Two tray cases and one static check stopped pinning source identifiers. The refused
  -name case asked the module's translation table by name for the sentence it expected,
  and the check that every `t()` key has a Chinese entry looked the table up by
  identifier; renaming that table turned three cases red for a refactor. The first two
  ask the tray's own translator now and the third finds the table by its shape.
- The tray suite's reload case compares the status row on a settled state on both
  sides. The row is written by the poll, so a poll landing between the two captures
  failed the case for a reason that had nothing to do with the key under test: it was
  the one intermittent failure left in the suite, about one run in four under load,
  and it recurred once more with two suites running at the same time.
- A stamp holding a NUL byte is the pause the shells read. Bash's command
  substitution drops NUL bytes with a warning and reads the rest, so
  `9999999999\0` is `9999999999` to `onedrive-sync` and `onedrive-doctor` - a pause
  they honour - and "not a time" to the tray, which showed automatic sync as on. The
  bytes go before the decoder now.
- The tray expands a variable inside the fallback of `${VAR:-fallback}`. The shipped
  `LOG="${XDG_CACHE_HOME:-$HOME/.cache}/..."` therefore read as a path with a literal
  `$HOME` in it whenever `XDG_CACHE_HOME` was unset, which is the default on a stock
  desktop: the tray named a log file the wrapper never writes. `$VAR`, `${VAR}` and a
  nested fallback are one function now, applied to the fallback as well.

- The tray read the pause stamp as text where the wrapper and the doctor read it as
  bytes. Two shapes got through: a stamp ending in `\r` or `\r\n` was translated into
  a newline by universal-newline mode and read as a pause, while `$(cat ...)` keeps
  the carriage return and both shells call the same file "does not hold a time"; and
  one byte that is not UTF-8 raised `UnicodeDecodeError` out of `_pause_due()`, which
  every caller reaches from a GTK idle callback, on every poll, so the pause row never
  painted. The file is opened in binary, decoded with `errors="replace"` - a
  replacement character is not a digit, so such a stamp fails the same rule the shells
  apply - and only a trailing newline is stripped, which is what `$(cat ...)` does.
- A re-run of the wizard broke the log path of an install that was working. Every
  key it carries over was read out of the old config and written back through the
  quoting the template uses, which escapes a `$`;
  `LOG="${XDG_CACHE_HOME:-$HOME/.cache}/sync.log"` came back as
  `LOG="\${XDG_CACHE_HOME:-$HOME/.cache}/sync.log"`, and `onedrive-sync` appends to
  that text as a path rather than expanding it, so the log moved under a directory
  named `${XDG_CACHE_HOME:-$HOME/.cache}` and the old log stopped growing. Carried
  keys are written as the old file's own lines now, so a value the user wrote
  survives a re-run exactly as it was written, whether or not the wizard could have
  produced it.

- Resuming a pause turned realtime sync back on for a user who had switched it off.
  The pause never touches the units, so resuming only has to clear the stamp; when
  the timer itself is off, "Resume now" is the only way back from the menu and
  enabling that is right, but the watcher went with it because the two were always
  touched together. `WATCH` decides the watcher now.
- The pause stamp had three readers with three grammars. The tray's `_pause_due()`
  was given digits and a length rule; `_paused_until()`, which the menu label reads,
  kept the old `int()` and `time.localtime()`, so a nineteen digit stamp raised
  `OverflowError` out of a GTK idle callback (seventeen and eighteen raised
  `OSError`, eleven raised nothing, and the raise reached the menu in one poll of
  four, because `auto_seen` is assigned before the menu is refreshed); the tray's
  rule stopped at nineteen digits where the shells' stops
  at ten, so a twenty digit stamp had the wrapper and the doctor reporting a pause
  the tray reported as automatic sync on; and the tray stripped whitespace the shells
  do not, so `" 1791117608 "` was a pause in the menu and a delete-and-sync for the
  wrapper. All three read the file the way `$(cat ...)` does now - only a trailing
  newline goes - and a value longer than a clock can hold is answered by length so
  that no reader can overflow on it.
- `resume_now()` and the pause recovery indexed `systemctl is-enabled`'s first output
  line, which is empty when there is no user bus: the stamp was removed, the thread
  died with `IndexError` and the click said nothing at all. The empty answer is
  classified where `unit_states()` already classified it, and the doctor no longer
  warns that reading the log would block when the log is a character device, which is
  the one non-regular file `onedrive-sync` handles.
- The tray's state lived only in pixels. The panel shows a 22-pixel icon with a
  badge, the indicator is not a `Gtk.Widget` and so has no accessible object of its
  own, its title was null in every state, and its icon description was the constant
  "OneDrive" whether the icon was syncing, failed or paused; the one row that spells
  the state out is insensitive, which is also what keeps GTK's arrow keys off it. The
  same sentence goes to the indicator's title, the icon's accessible description and
  the menu's own accessible name now. The settings dialog's labels name their
  controls and record the label-for relation, both spin buttons and both combo boxes
  had no accessible name at all (a combo was named after whatever was selected), the
  dialog has a default action so Return saves, and the three message dialogs are
  named after their question instead of after their message type, with the safe
  answer as the default.
- `onedrive-doctor` had no idea a pause existed, so a paused install read exactly
  like a healthy one: every run is turned away by the wrapper, the log is quiet, the
  timer is active, and the summary said nothing failed. It reports the pause and the
  time it ends, warns about a stamp that holds no time and about one that has run out
  but is still there, and does it where the tray and the wrapper already did.
- The stamp had two grammars. The tray's `int()` accepted a sign, an underscore and
  non-ASCII digits, all of which the wrapper rejects, so a stamp the tray showed as
  a pause was one the wrapper deleted and synced through; and a value long enough to
  overflow the shell's comparison made the wrapper print bash's error, read the
  stamp as expired, delete it and sync. Both readers take digits only now, and a
  value longer than a clock can hold is a pause rather than an expiry, decided by
  length so that no value can overflow the test.
- "Sync now" during a pause was a silent no-op: the service started, the wrapper
  turned the run away and wrote no result line, and the menu said nothing. It now
  answers with the pause and the time it ends, and queues nothing.
- The stamp was written with a truncating `open(..., "w")` while `write_atomic()`
  sits two hundred lines above it in the same file, so a wrapper reading the file
  mid-write saw an empty stamp, which is "not a time": it deleted the pause and
  synced. And the wrapper's pause check ran before the log rotation, so an install
  that spends its life paused never rotated its log.
- The migration that repairs a pause left by the older design did not repair the
  state it exists for. When that pause's time had passed, the stamp was dropped with
  the units still disabled and nothing else was done, so the machine was left
  exactly as the redesign was meant to prevent: nothing syncing, and a disabled
  timer that looks like a deliberate off. An expired pause now puts the units back,
  and the test for it drives that shape rather than the one where they were already
  on. "Resume now" had the same shape of problem in the other direction: it cleared
  the stamp and announced "Automatic sync resumed" without enabling a timer the user
  had switched off, so the menu went back to "Automatic sync is off" a moment later.
  It enables what is off and, if the stamp cannot be removed, says that instead of
  announcing a resume that did not happen.
- `INTERVAL_MIN="00"` slid past the validation written for `"0"`: the guard tested
  the string, and systemd reads `0min`, `00min` and `000min` as the same zero, so the
  unit shipped a timer counting down from nothing, which is the sync loop the
  validation exists to close. Every all-zero spelling is refused now.
- The write side of the config-path guard stopped where the read side did not:
  `write_atomic()` opened the target for writing with no `O_NONBLOCK`, and a fifo
  there blocks that open until a reader appears. Every caller is on the GTK main
  loop, so an `EXCLUDE_FOLDERS_FILE` fifo froze the icon with no error, which is the
  freeze the same series of fixes guarded the reads against.
- A character device is not a regular file either, and the rule added for the log
  did not tell them apart: `LOG=/dev/null` is a working install, because the wrapper
  appends to its log and its only other use of the path is a rotation guard that
  skips what it cannot size, and the row called it a failure. A directory and a fifo
  still fail it, which is what the wrapper does with them.
- A pause could outlive the tray and leave a machine doing nothing, and the shape of
  the feature is what made that possible: a pause was "the units are stopped and
  disabled" plus a transient `systemd-run` timer that turned them back on, and a
  transient timer does not survive a reboot or a logout. A reboot during a pause
  therefore left both units disabled with nothing to end it, and the only repair was
  a function the tray runs at startup, so no tray meant nothing synced again and a
  disabled timer looked exactly like a deliberate off. A pause is now the stamp the
  tray already wrote: `onedrive-sync` reads `paused-until`, exits without syncing
  while the time in it is in the future, and deletes it when it has passed. Nothing
  touches the units, so the pause survives a reboot, ends by itself, needs no tray to
  end it, and is visible to anything that can read the file; `install.sh` no longer
  silently ends one by re-enabling the units; and the transient timer, the
  `is-enabled` probe, the `Running timer` stderr match and the pause/resume watcher
  question are gone rather than patched. A pause written by the old version (units
  disabled, stamp in the future) is repaired at startup by re-enabling them while
  keeping the pause, which is the one thing `recover_pause()` does now.
- The guard that keeps a fifo or a directory out of the log reads stopped one file
  short. `onedrive-doctor` read `EXCLUDE_FOLDERS_FILE` with a bare `grep` and the tray
  with a bare `open()` on the GTK main loop, so a fifo there hung the whole check
  with no output and froze the icon, which is the freeze the same guard was written
  for on `LOG`. Both treat it as a failure with the reason, and `onedrive-sync`
  already skipped a non-regular exclude list, so no folder is excluded either way.
- The doctor's `logfile` row called a directory writable: it passes `-e` and `-w`,
  `stat` answers 4096 bytes for it, and the summary said nothing had failed, while
  `onedrive-sync` refused the same path with "cannot write the log ...: Is a
  directory". One path, one verdict: what the wrapper will do is what the row says.
- `setup.sh` was a fourth reader of the config format with both faults the shared
  reader had already lost: a carried value was cut at the first inner quote (`LOG`
  holding an escaped quote came back as everything before it) and at any `#`
  (`BW_LIMIT=abc#def` came back as `abc`), so a wizard re-run wrote a truncated path
  where the running install used the whole one. It reads through `lib/config.sh` now,
  and the pages that counted the readers say four.
- `INTERVAL_MIN` reached the unit template unvalidated, and systemd's answer to a
  value it cannot parse is a warning in the journal and a dropped directive:
  dropping `OnUnitInactiveSec` leaves `OnActiveSec=2min` as the timer's only
  trigger, which fires once per activation and stays disabled, so a config holding
  `INTERVAL_MIN="abc"` synced once per login while the timer still reported active;
  `0` is parsed and means "as soon as the last run finished", which is a sync loop.
  `install.sh` refuses anything that is not a whole number of minutes, or is zero,
  and says what it used instead.
- `install.sh` compared the timer drop-in against one spelling of the value, so
  `OnUnitInactiveSec=30` (thirty seconds to systemd) matched nothing and stayed
  there, outranking `INTERVAL_MIN` in silence. It reads the whole value now, prints
  it as it was written, and brings it back in line with the config.
- The NetworkManager hook started the sync service on any interface coming up
  without asking the timer, and the timer is the switch for automatic syncing: a
  pause is the tray having stopped and disabled it on purpose, so every pause and
  every install with automatic sync off ran a sync on the next wifi, dock or VPN
  event. The hook asks `is-enabled` first and does nothing when the answer is no.
- The sync service inherited the manager's 90 second stop timeout, which a bisync of
  a large tree can exceed: a logout with lingering off or a shutdown stopped it with
  SIGTERM and killed it outright 90 seconds later. `TimeoutStopSec=300` gives rclone
  the time it needs to end the run and write its listings, and says so where the
  number is. The comment above `TimeoutStartSec` had the manager's default backwards
  (a oneshot has no start timeout of its own, so the directive adds a cap rather
  than raising one) in the unit and in the wrapper's header.
- The doctor's log check could not read a log with a byte that is not text in it.
  GNU grep calls such a file binary and prints nothing, so one stray byte turned
  every check below into "nothing has ever run through the wrapper" with exit 0,
  while the tray read the same file and painted the icon red; rclone logs file names
  raw, so such a byte is reachable from a real run. `grep -a` throughout, a log or a
  `FILTERS_FILE` that is not a regular file is a warning rather than a read that
  waits for a writer, and a `FILTERS_FILE` that is a directory is named as one.
- The doctor certified a permanently refusing install as healthy. Every refusal in
  the wrapper ends `state=stopped tag=other`, and the report's `case` had no branch
  for the tag, so it printed "no failure hint in it" and exited 0 while the tray
  showed the wrapper's own sentence. `state=stopped` fails now, `state=error`
  warns, and the sentence points at the log for the reason.
- One file name could forge a run's verdict in both readers. rclone logs names raw,
  so a line can quote text shaped like the marker; the tray matched it anywhere in
  the line and the doctor grepped it unanchored, so a failure two lines above was
  painted green. Both anchor it to the line, require all four fields, and therefore
  also ignore a marker cut off mid-write. Nine of the tray suite's marker fixtures
  carried a `NOTICE: ` prefix the writer never writes, which is what kept the
  unanchored match covered; they carry the real shape now.
- The tray read its log tail through a fifo, which blocks `open()` on the GTK main
  loop and freezes the icon with no error, and it cached a read that had failed as
  its answer, so a log that became readable again still said "No sync recorded yet".
  Only a regular file is read, and only a read that answered is remembered.
- The tray read the config file differently from the shell that sources it. A value
  the writer had escaped came back with the backslashes still in it, a
  single-quoted `${HOME}` was expanded although bash leaves it alone, and an escaped
  `\$VAR` was expanded too, so the tray could name a different file than the one the
  wrapper syncs (`CHECK_FILENAME`, and `LOCAL`, which is what the folder menu's
  delete guard checks). `shell_value()` reads each shape the way bash does, and
  `tests/dependency-matrix.sh` now reads one file three ways and compares the
  answers.
- `install.sh` and `uninstall.sh` carried a copy each of the `sed` reader for the
  config file's format, and a copy is how the two drifted apart the last time. They
  source `lib/config.sh` now. That reader also stopped treating a `#` in an unquoted
  value as a comment wherever it stands: `KEY=abc#def` came back as `abc` where bash
  says `abc#def`.
- Re-authorise claimed the sign-in was done the moment the terminal opened. The
  wait was for the remote to answer again, and the credentials rclone was still
  using answered the first probe, so "Signed in. Syncing now." appeared about a
  second after the window opened, the guard that keeps a second
  `rclone config reconnect` from starting over the same credentials came down, and
  a sync was started over a sign-in that was still on screen. The script the
  terminal runs writes the reconnect's exit status where the tray can read it, so
  the flow waits for that file, checks the status in it, and only then asks the
  remote; when it fails, the sentence carries rclone's own last line instead of a
  question mark.
- `UI_LANG` written the way a locale is spelled was ignored. `zh_CN`, `zh-CN`,
  `zh-Hans`, `zh_CN.UTF-8` and `ZH` are the values a person reaching for a locale
  writes, and `resolve_lang()` knew only the literal `zh`, so the menu stayed
  English. The settings window's Language row matched the raw string against its
  three ids as well, so those values left the row empty and a Save wrote `""` over
  a setting that was in use. One normalizer answers both: `_` and `-` are one
  separator, the territory and the encoding are dropped, and a value naming no
  language is the "follow the system" row.
- A Chinese reader got three pieces of English: the `[oldrclone]` hint named
  rclone 1.65 while the wrapper and every page say 1.66, so upgrading to 1.65 left
  the failure; the desktop entry the tray writes had no `Name[zh]`, so GNOME's
  startup list showed `OneDrive status icon` beside a checkbox reading
  开机自动启动托盘; and the pause-failure notification glued an ASCII `:` and
  systemd's own English onto a translated clause. The hint, the entry and the
  sentence are fixed where they are written.
- A config file with one non-UTF-8 byte crashed `--show-icon`/`--hide-icon` with a
  traceback, and in the settings window it killed the save worker before it could
  report anything: `busy` stayed true, the Save button stayed insensitive and the
  window said nothing at all. `update_config_file()` raises the same fault
  `load_config()` answers that file with, and both callers print it.
- `update_config_file()` rewrote only the first line of a key that appears twice,
  and every reader of the format lets the last assignment win, so `--hide-icon`
  printed `SHOW_ICON=0 written` and the icon stayed. Every line carrying the key is
  rewritten now, and the key is not appended as well.
- The log cap stopped being a cap on a userland without GNU `stat`: the wrapper
  read the log's size with `stat -c%s` and the `|| echo 0` beside it turned the
  failure into a zero byte log, so the rotation silently stopped happening. The
  size comes from `wc -c`, which every userland has, and a size that cannot be
  read (a log the user may write but not read, say) is a warning in the log.
- A sync that keeps failing was announced on every run. The guard whose comment
  says the same failure is not announced twice compared the run's own clock along
  with the tag and the log line, and a run's clock is different every time, so a
  five minute timer produced one desktop notification per failing run carrying the
  same sentence: 288 a day for as long as the condition lasted. The identity is
  the tag and the raw line now, measured against a real notification service, 30
  failing runs give one notification, and a failure the tray has not seen before
  is still news.
- The watcher unit is the project's only `Restart=always`, and the watcher exits 1
  on purpose after three permanent `inotifywait` failures: with `RestartSec=5`
  that is a restart every nine seconds, roughly 9,600 a day and 24 MB of journal
  for one unparseable exclude pattern, and systemd's default start limit (five
  starts in ten seconds) never tripped. The unit bounds its own restarts now, five
  starts in five minutes, so a transient failure still gets five tries while a
  permanent one leaves the unit failed. `onedrive-doctor`'s watcher row tells that
  state from a plain inactive unit and names the reset, instead of suggesting
  `enable --now` for a unit systemd has given up on.
- Seven failures that left no trace are reported now, each in the place its file
  can write to. `install.sh` printed `watcher disabled: WATCH is off in ...` over
  a `disable --now` that systemd had refused, and sent a refused `try-restart` to
  `/dev/null`, so an update could leave a watcher loop running the code it
  replaced while the run said nothing; `uninstall.sh` swallowed both of its
  disables the same way and still ended on "Done" with the units enabled and their
  scripts already deleted; and `setup.sh` read `rclone listremotes` with stderr
  dropped, so an rclone that could not read its own config was reported as a
  machine with no remotes, with a repair that could not fix it.
- `load_config()` in the tray answered the defaults for a config it could not
  open, so a config that was there and mode 000 arrived in `main()` as a config
  with no `REMOTE`: the tray told the reader to add the key that was in the file.
  It raises the same kind of fault as a bad byte does now, with the file and the
  reason, the settings process checks it before opening a window on empty fields,
  and a running tray says the file was not applied instead of blaming a key.
- `ensure_icons()` swallowed the `OSError` from a directory it could not write
  into and handed the indicator five paths to files nobody had written. The tray
  says the icon will be blank, the progress arc says so once rather than once per
  poll, and `onedrive-doctor`'s tray row tells a directory holding icons from one
  holding none. The `--resync` name check is no longer skipped in silence when
  `onedrive-check` is neither beside the wrapper nor on `PATH`: it says the names
  were not checked, instead of ending `state=synced` as if they had been.
- A run that refused before invoking rclone wrote nothing to the sync log. The
  refusal went to stderr, which systemd keeps in the journal, so the log stayed
  empty: `onedrive-doctor` reported that nothing had ever run through the wrapper
  and the tray showed an unknown state with no reason in it. The log is opened and
  `log_line` and `result_line` are defined before the first refusal now, and a
  refusal writes the `ERROR:` line the log is there for plus one
  `state=stopped tag=other` marker of its own: a `LOCAL` that does not exist, a
  missing rclone or `flock`, a numeric key that is not a number, a `BISYNC_ARGS`
  token that begins or ends with a quote, or a lock file that cannot be opened.
- `install.sh` warned about a unit pair left behind by an earlier `UNIT_NAME` by
  naming the timer alone, so a user who ran the command it printed left
  `<name>-watch.service` enabled and syncing on its own schedule, and the
  interval drop-in with it. The warning lists every file this installer writes
  under that name and turns off both halves of the pair, and it stays quiet about
  another program's timer sitting in the same directory. Both it and
  `uninstall.sh` also looked for such a pair by matching the prefix they were
  running from, so a pair left by an install under a different `--prefix` was
  reported by neither: the warning said nothing and the uninstaller left a timer
  firing at a script it had just deleted. They match the scripts by name now.
- `install.sh` wrote `ExecStart=` into the systemd unit without quoting, so a
  prefix containing a space produced a unit whose command systemd read as two
  arguments, and `systemd-analyze verify` rejected it outright. Both templates
  quote the path now, and the installer escapes what systemd treats specially
  inside a unit, including the `%` that starts a specifier. The desktop entry
  had the same bug one release earlier; this is the other half of it.
- `uninstall.sh --purge` removed the configuration and the icon directory but
  left the cache behind, so a reinstall started with the old log, the old lock
  and, if a pause had been in progress, its stamp.
- The tray suite's case for the delete guard's sibling-directory prefix check
  could not fail: the exclusion gate refused the name before the guard under test
  ran. It now puts the name on the exclusion list first, so only the prefix check
  can refuse it, and mutating that check turns the case red.
- A timed pause was cut short by about three seconds. The poll cached systemd's
  `is-enabled` answer, so once the pause had turned the units off the tray read
  them as on again, deleted the resume stamp and left the timer running. The cache
  is invalidated where the units are changed, which is the one place that knows
  they moved.
- A request whose start was still in flight was expired by the next poll, so a
  sync started from the menu could be reported as finished while it was running.
  The expiry is skipped while a request is in flight.
- A reload of a hand-edited config left the values the tray read at startup in
  place: the folder, log, app and remote rows and the delete guard's path check
  kept the old file's values while the settings window showed the new ones, and a
  moved `UNIT_NAME` could have the dialog write a drop-in for a unit nothing
  polls. The unit stays frozen, the other six follow the file, and a moved label
  or path rebuilds the menu that was built from them.
- A reload that moved `LOG` left the tray reading the cached tail of the file
  before it. The cache is keyed on size and mtime alone, so a new log copied with
  its times (`cp -p`) matched and the status line went on describing the old file
  for as long as the new one stayed still. The cache is dropped when the path
  moves.
- A bandwidth limit that was set by hand rather than picked from the list was
  dropped when the settings window saved, and the value the list showed was not
  the one in the file.
- A folder listing that failed replaced the list the menu already had, so one
  momentary `rclone lsf` failure emptied the folder submenu until the next poll.
- `uninstall.sh` turned off a stale pair's `.timer` but not its
  `-watch.service`, leaving a `Restart=always` unit restarting against a script
  that had just been deleted.
- `install.sh` left an existing autostart entry in place when the tray's packages
  were missing, so the desktop kept trying to start a tray that cannot run, once
  per login. It removes the entry and says that it did.
- The wrapper recognised only the long `--verbose`, so `-v` or `-vv` in
  `BISYNC_ARGS` still produced a command line rclone refuses outright ("Can't set
  -v and --log-level"), which failed every attempt of every scheduled run. All
  the spellings of the flag now take the same branch.
- The tray's config reader kept an inline comment as part of the value, so
  `MAX_DELETE="100"   # abort above this` read as junk and fell back to the
  default while `bash` sourced the same line as `100` and the wrapper used it.
  A comment is now stripped where shell would start one and kept inside quotes.
- `onedrive-doctor` read only the newest failure hint, so a network blip that
  landed after a refused sign-in was reported as "the sign-in is not what
  failed" while the sign-in was the reason nothing was syncing. A hint the next
  run cannot clear is reported while nothing has synced past it, and one that a
  later run did sync past is no longer reported as a live fault.
- `docs/KNOWN-ISSUES.md` had two "Smaller, and real" sections with three bullets
  in both and two bullets describing things that had since been fixed, and
  `CHANGELOG.md` repeated `### Added` and `### Fixed` in two release sections.
  Both are merged, and `tests/docs.sh` now refuses a repeated heading or a
  repeated opening line in either file.
- `tests/lib/mutate.sh` decided a row's verdict by looking for the text "0 failed"
  in the suite's closing line, so a suite that reported "20 failed" was recorded
  as a survivor: the same row read caught at 18 failures and SURVIVED at 20. The
  count is read as a number now, and `tests/lib/mutate.sh --self-test` checks the
  classifier against six closing lines, including the two it used to misread.
- `onedrive-doctor` and `onedrive-sync` read rclone's one-line refusal of an
  expired sign-in ("... couldn't fetch token: invalid_grant: maybe token expired?
  ...") as a network problem, because that line matches both pattern tables and the
  network one was asked about first. The doctor then said the sign-in was not what
  failed and exited 0 while nothing could sync, and the wrapper spent its retries
  on a failure no retry can clear. The markers that can only come from Microsoft's
  own answer are asked about first now, in both files.
- Deleting or breaking the config of a running tray was read as "the config is
  empty": the defaults were applied over the running values, so the delete guard's
  root moved from the configured `LOCAL` to `~/OneDrive` and the folder menu
  offered to delete a directory there. A config that cannot be read no longer
  counts as a change, and a reload refuses a config with no REMOTE.
- A reload that moved `REMOTE` left the folder list and the quota of the remote
  before it in place for up to thirty minutes, and unticking a row in that stale
  list wrote the old remote's folder name into the exclusion file that now governs
  the new one.
- A value that begins with `#` (`KEY=#value`) was read as an empty value, and one
  written as `export KEY=value` was stored under the key `export KEY`, so the tray
  refused to start on a config the wrapper and the doctor read correctly.
- `BISYNC_ARGS` holding a quoted pattern, which is how a shell would group a
  pattern containing a space, made rclone refuse the whole command line on every
  run and left its usage text in the journal. A token that begins or ends with a
  quote is refused at the start of the run with the key named, and
  `config/config.example` says where such a pattern belongs.
- The wrapper's own `-v` and `-vv` were refused as unknown options while the same
  spelling inside `BISYNC_ARGS` was treated as verbose, which was two answers to
  one question.
- The doctor's tray probe matched any command line containing the name, including
  the `tail -f .../rclone-onedrive-tray/sync.log` the project's own documentation
  tells a user to run, so it reported a tray that was not there. It matches the
  interpreter and the script now.
- The doctor called a config healthy when `RETRIES`, `RETRY_DELAY` or
  `MAX_LOG_BYTES` held a value `onedrive-sync` refuses to run with, and a machine
  that had never synced hid the `MAX_LOG_BYTES` case entirely, because that check
  sat behind "does the log exist".
- Six things the documentation said that the code did not: both READMEs' menu
  diagrams omitted the tray's `Diagnostics…` row, both `BISYNC_ARGS` samples were
  missing `--stats 2s`, the flag that makes the live progress they promise work,
  `docs/UPDATING.md`'s "did the update take effect?" loop left out
  `onedrive-doctor`, `docs/SIGNING-IN.md` promised every account its own config and
  log where those paths are fixed names, `docs/DEPENDENCIES.md`'s manual check
  rejected a machine whose tray works, and the Chinese README did not say that a
  missing GTK stack still installs the sync half.
- The two mutation rows for the tray's failure-hint pattern applied a mangled
  regex, because sed eats one level of backslashes in a replacement, so they
  tested something other than what their comment described.
- `setup.sh` started the full, uninterruptible first sync on its own when stdin
  was not a terminal: `ask()` answers the (Y/n) prompt's default in that case, and
  the default is yes. `--yes` was already handled, and a run from a script, a pipe
  or cron is the same situation with nobody there to answer.
- `tests/filters.sh`'s check that the filters file holds no whitespace-only line
  could not fail: `grep -qvE '^[[:space:]]*$'` exits 0 as soon as any line is not
  blank, which is true of every file with a rule in it. It asks for a line made
  only of blanks now, and a second case proves the expression would notice one.
- Five of the six name groups `docs/TROUBLESHOOTING.md` promises OneDrive rewrites
  (a leading tilde, a leading or trailing space, a trailing period, DEL, a control
  character, bytes that are not valid UTF-8) had no case anywhere, so the checker's
  arm for each could be deleted with every suite still green. Each group has a name
  in the fixture now, and two of them have mutation rows.
- `bin/onedrive-doctor` carried a comment describing the failure-hint order the
  previous round removed, fifteen lines above the code and the comment that say the
  opposite.
- `docs/FEATURE-PARITY.md` listed bandwidth presets as work still to do while its
  own must-have table records them as present, and said they were written into
  `BISYNC_ARGS`, which is not how they are built.
- `install.sh` wrote an autostart entry that a desktop cannot parse for an install
  prefix containing `$`, a backtick or a quote: its `Exec=` escaping was one pass
  short of the key-file rule the tray's own writer implements, so the entry was
  refused outright and the tray never started at login while the "Start tray at
  login" checkbox still read as on. Both writers now run the same acceptance list
  through GLib.
- The machine-wide NetworkManager hook: the HOME-redirect guard printed "so it is
  not installed" and then installed anyway, so a run with a redirected HOME could
  write into `/etc`, and no suite ran `install.sh --with-nm-dispatcher` at all, so
  neither the installer's write path nor the uninstaller's unit-name guard was
  exercised. Both paths have cases now, driven through a dispatcher directory the
  suite redirects.
- `install.sh` gated the whole install on `command -v rclone` and took its version
  warning from the PATH binary, so a user who followed `config.example`'s advice to
  point `RCLONE` at a build outside PATH could not install. It reads that key the
  way it already reads `UNIT_NAME`.
- `setup.sh` probed and ran the bare `rclone` from PATH, the same blind spot one
  screen up, so the wizard refused a machine whose rclone is outside PATH while
  the wrapper it installs would have worked.
- `setup.sh` rewrote the config from its template on every run, so a re-run reset
  every value it had not prompted for (a bandwidth cap, an access check, the log
  size, the icon and notification settings) and deleted the keys its template did
  not know, `RCLONE` among them. Keys the flags do not own are carried over now,
  an explicitly empty value is kept as empty, and the template gained the four keys
  it was missing.
- `install.sh`'s `ExecStart=` did not escape `$`, which systemd reads as the start
  of a variable. Per the documented rule it is written `$$`, with a case that
  asserts it rather than a measurement, because proving the expansion needs a unit
  to run.
- `install.sh` accepted only `"1"` for `WATCH` while `onedrive-doctor` accepted
  five spellings, so a config the doctor called on was reported as off by the
  installer, which left the watcher unit disabled.
- The tray ignored the documented `RCLONE` key in all four of its rclone calls, so
  the quota row, the folder menu and Re-authorise could run a different binary from
  the one that syncs. The key is resolved once, followed by a reload, and every
  call is quoted the way the remote already was.
- A config file that is not valid UTF-8 killed the tray with a traceback while the
  shell half sourced the same file happily, so sync kept running and the icon never
  appeared, with the traceback going nowhere (the autostart entry is
  `Terminal=false`). It is reported as a config fault naming the file and the byte,
  and a reload keeps the values it already had.
- "Sync now" announced a start that had not happened when `systemctl --user start`
  failed: the return code and systemd's message were thrown away. It reports the
  refusal now and, on that path, runs the wrapper directly, because systemd is only
  the scheduler and the wrapper takes the same lock and the same delete cap.
- "Folders to sync" could sit on a disabled "Loading…" row for up to half an hour
  when the remote had never been listed, because a failed listing stored the same
  nothing as "not fetched yet". The row says the listing failed and offers a retry
  when there is no listing at all, and the mirror case is unchanged: a remote whose
  answers never land keeps none of the previous remote's folders.
- The yes/no keys are read as `1`, `true`, `yes`, `on` or `enabled` by every
  reader now: the tray's `truthy()` gains `enabled`, which the wrapper and the
  doctor already took, so a config one of them called on is no longer off in the
  settings window with a Save writing `0` over it. The window keeps the spelling
  the file already had unless the box is actually changed.
- The "Start tray at login" checkbox had a case that could not fail: its fixture
  never created the autostart file, so "reads the file" and "always unchecked" were
  the same answer, and the unguarded reader would have deleted the entry on the
  next Save. The entry exists in the fixture now, and the case reads it.
- The tray's refusal for a config with no REMOTE named `onedrive-doctor`, which is
  read-only by construction and cannot set one. It names `setup.sh` and the line to
  add, with the config path.
- `onedrive-sync --resync` overwrote local edits with the cloud copy and said
  nothing. rclone's `--resync` is `--resync-mode path1` and the wrapper passes the
  remote first, so for a file that changed on both sides the cloud version won:
  measured on a scratch pair, a local edit was replaced, `rc=0`, no conflict copy,
  and `docs/TROUBLESHOOTING.md` called that "safe". The wrapper now asks rclone for
  `--resync-mode newer` once before a resync and passes it when the flag exists, so
  the copy that changed last wins; on an rclone without it the run logs a warning
  saying the cloud copy will replace the local one before it starts. The README,
  the troubleshooting page and the tray's confirmation dialog say the same thing
  now instead of promising that nothing is lost.
- The doctor's tray check reported a tray whenever any command line on the machine
  contained the name, including its own `timeout` wrapper and another install's
  tray, so `ok tray running (pid N)` was printed with no tray of this install
  running, the pid named was often already dead, and the two "no tray process"
  answers below it were unreachable. It asks the tray's own lock file instead, with
  `flock -n`, which is the fact the tray publishes.
- A config or exclude list the tray could not finish writing was left truncated,
  because every writer opened the target with `"w"` first: a full disk or a kill
  mid-write destroyed the hand-edited config, and `onedrive-sync` then died on a
  file it could not source. The four writers now write beside the target, fsync and
  rename it into place, and a write to a read-only file still refuses rather than
  succeeding through the rename.
- A unit-state answer that arrived after a pause deleted the pause stamp, because
  the answer was not tagged with when it was asked: the row then read "Automatic
  sync is off" for the rest of the pause and nothing restored it after a restart.
  Answers carry a generation now and a stale one is dropped, in the state and in
  the cache.
- The stale-lock sweep ran once, before the retry loop, so when rclone died
  mid-run (a kill, the OOM killer) every remaining attempt failed on its
  dead-owner lock while the sweep that would have removed it had already run. It
  runs before each attempt now.
- "Re-authorise OneDrive…" had no in-flight guard, so two activations started two
  reconnect flows and two pollers, and the first to finish announced a sign-in
  while the other was still open. The row is insensitive while a flow runs.
- The single-instance lock could be taken twice: `release_lock()` unlinked the file
  and then closed the descriptor, so a process that opened it in between held an
  unlinked inode while the next created a fresh file. The lock is checked against
  its own inode and unlinked before the close.
- An empty remote side made every incremental run fail with advice to run
  `--resync`, which rebuilt an equally empty baseline and looped forever; the
  README's own no-account trial created exactly that pair, and now puts one file in
  the cloud directory. rclone's `Empty prior Path1 listing` has its own tag and
  hint in both the wrapper and the doctor.
- The delete cap is a percentage of the pair under the hood, and a count below one
  percent floors to one percent: `MAX_DELETE=1` over a 397-file folder allows about
  three deletions, not one. rclone takes whole percentages only (`--max-delete 0.5`
  is refused), so the log and the docs now say what the percentage really allows,
  by naming the number.
- `config/config.example` hardcoded `$HOME/.config` and `$HOME/.cache` while every
  script follows `XDG_CONFIG_HOME` and `XDG_CACHE_HOME`, so the config `install.sh`
  copies pointed at paths nothing had created on such a machine, and the filters
  were silently not applied. It uses the same expansion the scripts do, and the
  tray resolves the `${VAR:-fallback}` form bash writes, which its parser used to
  leave as literal text.
- `setup.sh --yes` reset the interval and turned realtime sync back on when those
  flags were not passed, while every other key it does not ask about was carried
  over. Both follow the same rule.
- A `LOCAL` that is not an absolute path had the delete guard working against the
  tray process's working directory rather than the synced tree, so a same-named
  directory elsewhere could be offered for deletion; the confirmation named only
  the folder. A relative `LOCAL` is refused with the key named, and the dialog says
  which path it will delete.
- `install.sh` wrote the config's `UNIT_NAME` into the NetworkManager hook, which
  runs as root, without the escaping its three neighbouring substitutions use and
  without validating the value: a name holding `$(...)` was executed when the hook
  next fired, one holding `&` installed a hook that could never match while the
  installer reported success, and one holding `|` aborted the install with a raw
  `sed` error after half the files were written. The value goes through the same
  escaping and is validated against the rule `setup.sh` already applies to its own
  input, with a sentence naming the key.
- `extras/install-issue-watch.sh` wrote an unquoted, unescaped `ExecStart=`, so a
  prefix holding a space (including a home directory with one) produced a unit
  systemd split in two, and the issue-watch timer could never start. Nothing in
  `tests/` ran `extras/` at all, which is how it survived eight rounds; the unit it
  generates now goes through the same escaping as the installer's units, and a case
  verifies it with `systemd-analyze`.
- `onedrive-doctor` certified a config the wrapper refuses to run: its key scan and
  its filters guard did not accept the `export ` prefix that the tray, the wrapper
  and the doctor's own `source` accept, so `export RETRIES="three"` printed `ok
  config` and "nothing failed" with exit 0 while every run died, and
  `export FILTERS_FILE=/missing` was never checked. Both scans take the prefix now,
  and `MAX_LOG_BYTES` has one verdict instead of a `fail` in one check and a `warn`
  in another.
- `onedrive-watch` threw inotifywait's output away and retried forever, so a
  permanent failure (an invalid `WATCH_EXCLUDE`, the watch limit) left the unit
  reporting `active` with an empty journal while realtime sync was dead and the
  doctor called it healthy. It now writes the tool's own message, distinguishes a
  permanent failure from a vanished directory, and exits non-zero after repeated
  permanent failures so `Restart=always` carries it.
- The project's rclone floor was documented as 1.65, but the four flags its default
  set always passes arrived in 1.66: on a 1.65 build every run failed with
  `unknown flag: --recover` and the advice named the version the user already had,
  while the installer said nothing. Measured against the real 1.64, 1.65 and 1.66
  releases. The wrapper now asks the binary which of the flags it lists, drops the
  ones it does not have with a NOTICE naming them and the version that has them, and
  names the refused flag in its version hint; the installer probes the same way; and
  the floor is 1.66 everywhere it is written down.
- The log's timestamp was written with the machine's calendar: under a locale with
  a non-Gregorian year the doctor reported the log as two hundred thousand days old
  and the tray's live progress never appeared. The writer pins `LC_ALL=C`, so the
  numbers mean the same thing to every reader.
- `onedrive-check` measured path lengths with bash's `${#var}`, which counts
  characters under a UTF-8 locale and bytes under `C`, so the same tree was clean
  from a desktop terminal and over-long from systemd or cron. It now counts bytes
  whatever the caller's locale, and says so in the unit it prints.
- The tray decoded its subprocesses with the desktop locale while every file it read
  was pinned to UTF-8: under a GB18030 locale the folder menu was built from
  mis-decoded names, and unticking one wrote that name into the exclusion list, so
  the folder kept syncing while the menu said it was left out. Both call sites are
  pinned to UTF-8.
- A pause whose resume timer could not be armed left automatic sync switched off
  with a sentence and no repair, while the recovery path repaired the same fault.
  It runs the same repair now.
- `LOCAL="/"` was accepted, and the delete guard's "strictly inside the sync root"
  test is vacuous at the filesystem root: the menu offered to delete `/etc` and
  `/usr/bin`, and the confirmation named the path. A sync root that resolves to the
  filesystem root is refused.
- `setup.sh` wrote folder names it cannot express into the exclusion list, so a name
  beginning with `#` became a comment line that both readers skip: the folder kept
  syncing while the menu showed it as left out. It applies the tray's own checks and
  warns instead of writing a name that cannot work.
- "View sync log" and "Open sync folder" did nothing and said nothing when
  `xdg-open` was missing, although the installer treats it as optional. They report
  it now, naming the package.
- `setup.sh` reported a missing option value with a localized bash internal that
  names no flag, and exited 1 for an unknown option where `install.sh` exits 2. All
  four flags name themselves, and a usage error is 2 from either script.
- `install.sh` replaced a failed `systemctl enable` with a guess about the cause and
  then printed the success summary; it now shows what systemd said and the command
  that fixes it.
- The wrapper and the tray announced any non-zero from `onedrive-check` as bad file
  names, including the configuration faults the checker reports separately. The
  wrapper passes the checker's own sentence through for a configuration fault.
- The installers read the config with `sed` and stopped at the first inner quote,
  so a value the tray wrote with an escaped quote came back truncated with nothing
  said: the concrete half of the "four readers for one file format" entry. They
  read the whole quoted value now and undo the escaping the writer applies, which
  is the same reading bash and the tray give the file, and they accept the `export `
  prefix as well.
- A sync that started and finished between two polls raised no notification: the
  failure was announced from the falling edge of the running state, and a run that
  never appeared as running had no edge. The failure is announced from the parsed
  log line now, once per distinct failure, and a line older than the tray is not
  announced at all.
- A folder listing or quota answer that was in flight when `REMOTE` or `RCLONE`
  moved was stored anyway, because the worker did not record what it had asked
  about, and the menu then offered the old account's folders: unticking one wrote
  that name into the exclusion file that governs the new remote. Each request
  carries what it is about now, a stale answer is dropped and asked again, and a
  moved `RCLONE` clears the answers the way a moved `REMOTE` does.
- `SettingsDialog._worker` wrote its failures into `self.failures` instead of
  returning them, which was the last method in the file that both computed and
  stored; it returns them and the dialog's reporting is unchanged.
- The settings window rewrote a line it changed without the `export ` prefix a
  hand edit had given it. The line keeps its own prefix; a key that is appended
  gets none.
- A reload of a config whose `LOCAL` is relative was refused by the delete guard
  but applied anyway, so the tray ran on it. The reload applies the same validation
  as startup now, and both of its refusals say why through a notification instead
  of one of them being silent.
- The untagged failure hint showed the wrapper's raw line in English and a fixed
  sentence in Chinese. The raw line is what a reader needs (it carries the log
  path), so both languages show it and the now-unused translation is gone.
- The first-run wizard never offered the access check, so a fresh install shipped
  with only the delete cap guarding it; the key defaulted to off for upgrade
  reasons, not for new installs. On a config it creates, the wizard offers the
  check, runs the shipped access-check helper and writes `CHECK_ACCESS="1"`, and
  under `--yes` or with no terminal it names the command instead. A re-run keeps
  the value the file already has.
- The wrapper created `LOCAL` when it was missing, which turned a typo or an
  unmounted tree into a fresh sync root that then synced the whole remote into it.
  It refuses with the `mkdir -p` to run; the wizard creates the directory when it
  creates the config, and the log and cache directories are still made as before.
- `install-flow` had four conditional skips while the floor budgeted one, so a
  machine missing two of them failed CI for a reason unrelated to the change.
  Three of the four are now created in the sandbox (a stub for a missing
  `systemd-analyze`, a path the mode bits cannot make writable, a pid that is
  already gone); only the machine-wide hook needs root and still skips.
- The ledger's entry about the filters fixture was already fixed in the code; the
  two remaining fixtures built names by word-splitting `seq` output, and no case
  checked any fixture's length. All three use brace expansion and two cases assert
  the length they need.

### Changed

- `_local_delete_path()`'s second look at the sync root is gone. It refused a LOCAL
  with no parent, which is the filesystem root, and `local_path_problem()` refuses
  every spelling of that value first: the method reads `self.local`, which comes
  from `main()` or `_reload_config()`, and both ask that function before they use
  the value. The only way to reach the check was a case that monkeypatched the
  first guard away, so it was a guard over a value no caller can hold. The case now
  asks the guard about a top-level folder under `/` through the refusal that really
  fires.

- Eleven things the pages said that the code does not do, found by walking the
  documentation as a reader with no knowledge of the tree. `config.example` said a
  missing `LOCAL` is created while the wrapper refuses one; the troubleshooting
  page still prescribed the fixed lock file in `/tmp` that 1.4.0 replaced with a
  lock in `$XDG_RUNTIME_DIR`; two pages disagreed about what an rclone older than
  1.66 costs; the CI section named one runner where the workflow uses two; the
  trial route warned that `setup.sh` refuses to overwrite a config, which is true
  without `--yes` and false with it; the Chinese README stated the delete cap as a
  flat count where the code passes a percentage; the result line's list of
  exceptions was missing the run that cannot open its log; `exclude-folders.txt`
  was listed as installed by `./install.sh`, which does not write it; the tray's
  own `Diagnostics…` item was only in the menu diagram; and `--resilient`'s
  arrival version was wrong in one place. All of them are corrected, and the
  Chinese README gained the result-line paragraph the English one has.
- `docs/TROUBLESHOOTING.md` says what the journal costs. A sync that succeeds
  writes nothing and one that fails writes about four lines and 413 bytes per run,
  which a five minute timer turns into roughly 120 kB a day for as long as the
  failure lasts; the project bounds no journald setting, because that is a choice
  about the whole machine, so the page shows both the vacuum command and the
  drop-in that caps it system-wide. It also explains what a watcher unit reading
  `failed` means now that the unit bounds its own restarts.
- The notification setting reads "Tell me when a sync I start succeeds", which
  is what it does: scheduled runs stay quiet, because a five-minute timer
  announcing every success would train people to ignore the notifications that
  matter. A failure always notifies. The wording was the only thing wrong.
- `tests/docs.sh` compares three more rules that live in two files each: the
  listing slug the doctor uses to find the wrapper's baseline, the
  positive-integer key list the doctor judges, and the set of keys the doctor
  claims to know against `config.example`. The README config sample is matched at
  any indentation now, and a README that shows a config with no `BISYNC_ARGS` line
  fails instead of skipping, which is how that gate could be defeated by a space.
- `install.sh` prints its "Installed" summary from the same list the install loop
  iterates, instead of a second hand-kept list of the scripts it ships.
- The single-pair limit is written down where a user meets it. `onedrive-doctor`,
  the wrapper and the tray each read the one `REMOTE` and `LOCAL` in the one
  config file, so the three app-wide names it used to be blamed on (the wrapper's
  `sync.lck`, the tray's `paused-until`, the tray's single-instance lock) are not
  what makes it one. `docs/COMPATIBILITY.md` now says which files those are and
  what a second account should do, and both READMEs carry the limit in their
  list; it was filed under "not verified", where it read as something nobody had
  tried rather than something the design does not do.
- `tests/docs.sh` gained gates for the README menu diagram against the labels the
  tray itself builds, the README `BISYNC_ARGS` sample against the wrapper's
  default, the script list in `docs/UPDATING.md` against what `install.sh`
  installs, and the two ledger files against saying the same thing twice.

## [1.4.0] - 2026-10-01

### Added

- `tests/floors.txt` records the fewest passing assertions each suite may report, and CI runs each
  suite once and fails when the count comes in under its floor. A suite that skips everything still
  exits 0, so without this a runner missing broadwayd could report "0 passed, 12 skipped" and leave
  CI green with the tray suite gone.
- `tests/lib/coverage.sh` measures which lines of the shipped scripts the suites execute, so the
  figures quoted in the docs can be reproduced with one command. It is not part of CI.

### Fixed

- The tray's offer to delete the local copy of a deselected folder could delete cloud data. A folder
  named `#notes` was written to `exclude-folders.txt` where both readers treat a leading `#` as a
  comment, so the folder stayed in sync while the dialog promised "the folder stays in OneDrive",
  and the deletion then propagated. Names the file cannot round-trip are now refused with the reason
  shown, and the delete offer is refused whenever the exclusion did not take effect.
- A timed pause did not survive a reboot: the resume timer was a transient unit, so it disappeared
  with the session while both sync units stayed disabled and the menu went on promising a resume
  time. The tray now checks at its next start whether that timer exists, re-arms it when it does
  not, and ends the pause with a notification when it cannot.
- The tray's single-instance lock lived in `$TMPDIR` with a fixed name and was opened for writing,
  so any local user could point it at a file the tray can write and truncate it, or hold the lock
  and keep every subsequent tray from starting. It lives in `$XDG_RUNTIME_DIR` now, opened with
  `O_NOFOLLOW`, with the old path as a fallback.
- `--version` and `--help` needed PyGObject, on the machine most likely to be asked for its version.
  They are answered before the bindings are loaded; a bare run still names the missing package.
- A typo in `RETRIES`, `RETRY_DELAY` or `MAX_LOG_BYTES` stopped syncing altogether: the retry loop
  never ran, rclone was never invoked, and the wrapper reported "all 0 attempts failed". Those keys
  are read the way `MAX_DELETE` is and refused with one line naming the key, the value and the file.
- The retry loop retried failures it had already classified as permanent (an expired sign-in, a
  missing access marker, a tripped delete cap, an rclone too old for a flag), spending two extra
  minutes and two extra rclone invocations on each. It stops after the first attempt for those and
  says why in the log.
- `onedrive-check` missed three of the names it is documented to catch: `.lock` and `desktop.ini`
  reduce to a stem that never matches, and `_vti_` was not in the list at all. It also called a name
  of exactly 255 characters too long, which is the documented maximum.
- `onedrive-doctor`'s remote probe reported an unreachable remote and a timeout as failures while
  its own contract calls a retryable network problem a warning, so an offline laptop exited 1 as if
  rclone were missing.
- The delete cap counted the files under `LOCAL` with a full walk on every run, even though the
  bisync listing the wrapper has already read is the number rclone compares against. The listing is
  used when there is one and the walk only remains as the fallback.
- Both writers of the autostart entry wrote `Exec=` with no quoting, so a home directory containing
  a space produced an entry the desktop reads as two arguments and the tray never started at login.
  The value is quoted and escaped the way the specification requires.
- `uninstall.sh` left the settings window's interval drop-in behind, so a later install of the same
  unit name silently inherited the old interval.
- `setup.sh --yes` could not rewrite an existing config: the overwrite prompt returned its `n`
  default without asking, so the only scripted way to re-run the wizard was to delete the file by
  hand. It also advertised `(Y/n)` and then treated a capital `Y` as no.

### Changed

- Three pages still said "all four suites" for a tree with five, and the check written to catch that
  matched only a capitalised numeral, so lowercase phrasing was invisible to it. It matches both now
  and covers two pages rather than one, and it deliberately skips the changelog, which is a
  historical record.
- The lock recipe in the troubleshooting page named `/tmp/onedrive-sync.lock`, a path nothing has
  created since the wrapper moved its lock beside its state.
- The advice for a tripped delete cap was given three ways, and the version in the docs undid the
  deletion the user meant to make: `--resync` brings every locally deleted file back down. The docs
  now say `--force`, which is what the wrapper's own hint said all along.
- The README no longer promises that a timed pause ends "whether or not the tray is still running",
  which was only true within one session.

## [1.3.0] - 2026-10-01

### Added

- `onedrive-doctor`, a read-only diagnostic that answers "is this install healthy, and if not
  which part is wrong" in one command: rclone and its version, `flock`, whether the config sources
  cleanly, that `LOCAL` is writable, how old the bisync baseline is, whether the wrapper's lock and
  rclone's own locks are held, what the log ends with and whether it is a network or a sign-in
  problem, the timer and service state, the watcher, the tray, the log's size against the rotation
  cap, and a read-only probe of the remote. Exit 0 when nothing failed, 1 when something did, 2 on
  a usage error. `--quiet` prints only what needs attention, `--offline` skips the remote. It never
  writes the config, never starts or stops a unit, never takes the lock and never runs a sync.
- A table of sixteen rows in the test suite that pins the wrapper's whole command line, one
  assertion per row, instead of one case per bug that reached rclone.
- [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md): what an audit of the tree found and left alone,
  with the reason for each, next to the limitations that are deliberate.

### Fixed

- Deleting the local copy of a deselected folder went through three hand-rolled path checks and
  then `shutil.rmtree`. A two-component name such as `a/b` passed them and deleted a nested
  directory. A name resolving outside the sync root was only stopped by `rmtree` refusing
  symlinks, after a confirmation had already been shown. One rule now decides: a single path
  component, neither `.` nor `..`, resolving to a real directory strictly inside the resolved
  root, and never the root itself.
- `onedrive-check`'s closing line counted distinct paths while the headings above it counted
  problems, so the numbers did not add up for a name that is both renamed and too long. It gives
  both numbers now, in the singular when they are 1.
- The doctor's own log line names how old the newest failure hint is, so a failure that a later run
  already recovered from no longer reads as something happening now.

## [1.2.0] - 2026-10-01

### Added

- A settings window in the tray, reached from `Settings…`. It writes the config file the wrapper
  reads, replacing only the lines whose values changed and appending a key it cannot find, so your
  own comments survive. Language and the panel icon apply to the running tray at once; the interval
  is stored as a systemd drop-in (`<unit>.timer.d/interval.conf`) so a later `./install.sh` cannot
  undo it; the watcher is switched on and off with `systemctl --user enable --now`. Anything that
  fails is named in the window, which stays open so the change can be corrected.
- Language selection in that window (`UI_LANG`): follow the system locale, English or Chinese. The
  menu is rebuilt in place, with no restart.
- `SHOW_ICON`, plus `--show-icon` and `--hide-icon`, for hiding the panel icon while the tray keeps
  running and syncing. `--settings` opens the window on its own, starting the tray when none is
  running. `--version` and `--help` answer without a display.
- An `About` item, and a header line carrying the version at the top of the menu.
- `BW_LIMIT`, a bandwidth cap for a run in rclone size syntax (`1M`, `500k`, `1.5M`). The settings
  window offers Unlimited, 1M, 5M, 10M and 20M. A value rclone could not parse is refused with a
  warning in the sync log, instead of turning every scheduled run into a failure.
- `NOTIFY_ON_SUCCESS`: switch the success notification off and keep the failure ones.
- Redrawn status icons. The cloud is one outlined path, the syncing badge is a pair of arrows,
  `unknown` has a question mark of its own, and a run that reports a percentage draws the syncing
  badge as a progress arc. `assets/icons/` holds the current set.

### Fixed

- A missing icon directory is created. `ensure_icons()` used to write nothing, in silence, when the
  directory was not there.
- `BISYNC_ARGS=""` now means no extra flags. It used to be indistinguishable from a config that
  never had the key, so emptying it restored the built-in defaults. An absent key still gets those
  defaults, and the log says which of the two happened.
- Lines in `exclude-folders.txt` are trimmed, so a line holding only spaces is ignored rather than
  becoming `--exclude "/   /**"`. A name containing `/` or `..` is refused with a warning.
- An unwritable log is reported before the run starts, with the path and the reason. The failure
  used to be silent: the directory creation hid its own error and the run could report success
  having recorded nothing.
- Config values are quoted before they reach a shell. The tray ran `systemctl` through
  `subprocess.run(..., shell=True)` with the unit name from the config pasted in unquoted, so a
  name with a space broke every menu action and a name with a `;` was command injection. Every
  argument goes through `shlex.quote` now.
- `onedrive-sync --resync` passed `--resync` to rclone twice.
- `onedrive-sync --force --resync` skipped the name check and wrote no `NOTICE` line, because the
  flag was only recognised in the first position. The order no longer matters.
- Every script takes its help from its own header comment, up to the first line that is not a
  comment. `install.sh --help` and `setup.sh --help` used a fixed line range and ended with a line
  of shell code; `onedrive-check-access --help` stopped one line short of saying where the config
  is.
- `install.sh --prefix` with no value after it failed inside bash, naming a variable rather than
  the missing directory.
- `setup.sh` wrote config values without escaping, so a remote or a path containing a quote, a `$`
  or a backtick produced a file that sourced to something else. It escapes them the way the tray's
  settings dialog does, and it runs the first sync from the same prefix `install.sh` defaults to
  instead of from a variable it never set.
- `onedrive-tray --show-icon --hide-icon` wrote `1` whichever order the two were given in. The last
  flag now wins, and `--help` says so.
- `docs/COMPATIBILITY.md` listed the case counts of two suites as they were several versions ago.

## [1.1.0] - 2026-09-30

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
- `tests/tray.sh`: the tray is a GUI, so this is the first suite that can see it. It starts GTK
  3's Broadway backend on a private runtime directory, builds the real menu, and activates every
  handler against stubs that record their arguments, covering both languages, the quota row, the
  three pause durations, a disabled or unreadable timer, the folder checkboxes, the single-instance
  lock and a quoted `OPEN_APP_CMD`. Against the tray from before the previous round it fails 11
  cases. It skips with a message when `broadwayd` is missing, and CI installs `libgtk-3-bin` for it.
- Five test suites, runnable with no OneDrive account and no risk to a working setup.
  `tests/dependency-matrix.sh` hides one dependency at a time and checks that the behaviour matches
  what `docs/DEPENDENCIES.md` promises. `tests/install-flow.sh` runs the documented install path,
  uninstall included, inside a sandbox and checks the files and the rclone command line it
  produces. `tests/filters.sh` runs rclone over a fixture tree to prove each default rule really
  filters. `tests/docs.sh` checks that the internal links resolve, that no page has picked up an em
  dash, that the files the READMEs name still exist, and that the prose does not contradict the
  number of suites. All five are wired into CI.
- `docs/COMPATIBILITY.md`: the versions this was developed against, the behaviour measured on a
  real account, and an explicit list of what has never been tried.
- A **Re-authorise OneDrive…** item in the tray, for when the sign-in really has expired. It
  confirms, opens a terminal running `rclone config reconnect <remote>:` so the sign-in URL and any
  error stay visible, polls the remote until it answers, and then starts a sync. Before this the
  tray could only say that authorisation had expired, leaving the user to find the command in the
  documentation.
- An opt-in access check, `CHECK_ACCESS` and `CHECK_FILENAME`, which is rclone's own second safety
  net beside `MAX_DELETE`: bisync looks for a marker file in the same places on both sides and
  aborts before changing anything when one is missing, which is what a network, authorisation or
  mount problem looks like from the other side. rclone never creates the file, so
  `onedrive-check-access` does, at the root of both sides, safely twice. Verified with real rclone
  1.75.1: with both markers present the run succeeds, with one missing it aborts and changes
  nothing, and with the check off the same state silently deletes the local marker, which is the
  loss the check prevents. Measured, and contrary to the obvious assumption, an empty marker file
  passes: rclone compares names and locations, never contents. A missing marker gets its own
  `[access]` hint rather than being reported as a resync problem, since `--resync` cannot fix it.
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
- `extras/watch-issues.sh` and its timer installer, for maintainers: polls the GitHub API twice a
  day, ignores pull requests, notifies on anything not seen before, and appends to
  `~/.cache/rclone-onedrive-tray/issues.log`. It is not part of the syncing and needs `curl` and
  `notify-send`.

### Fixed

- The failure hint classified by whichever pattern matched first in the last sixty log lines, so a
  network failure an hour old could label a fresh refusal as a network problem and send the user to
  the wrong action. Each class now has one pattern shared by the classifier and the message, and the
  newest matching line decides.
- A network failure was reported as an expired sign-in. rclone says
  `couldn't fetch token: Post ".../oauth2/v2.0/token": EOF` when it cannot reach Microsoft, the
  wrapper matched the word `token`, and the tray told the user to re-authorise a remote whose
  credentials were fine. On 2026-09-30 a dead proxy produced exactly that for 90 minutes. Failures
  that happen before Microsoft answers are now `[network]`; `[auth]` means a real refusal
  (`invalid_grant`, 401, 403, `AADSTS`), and its message names the tray item and the command.
- The quota row appeared up to three seconds after the query returned, because only the three-second
  poll applied it. `tests/tray.sh` caught it as a flaky assertion before anyone saw it as a
  slow menu.
- `--force` in `BISYNC_ARGS` bypassed the delete cap and said nothing, while the same flag typed on
  the command line was logged. It is now reported either way, and the config example warns against
  putting it there.
- The delete cap's denominator could belong to a different pair. When two bisync pairs name the same
  local directory, the wrapper picked the largest listing it found, which in testing made a
  legitimate 100-file deletion on a 300-file pair compare against 3000 files and abort. More than
  one candidate is now treated as an unknown size, with a warning, and the conservative 5% cap
  applies instead of a number that is confidently wrong.
- A timer unit that systemd reports as `disabled` was shown as `Automatic sync state unknown`,
  because the exit status was consulted before the answer. `systemctl is-enabled` exits non-zero for
  a unit that exists and is disabled, so the answer now decides the state and an empty answer means
  unknown.
- The delete cap had two edges that switched off rclone's own safety net. rclone reads
  `--max-delete` as a percentage and defaults to 50%, but the flag is only left at its default when
  it is absent, so a `MAX_DELETE` that was not a number, or one at least as large as the folder,
  passed `--max-delete 100` and turned the net off. An unusable value now passes no flag at all, and
  a count the size of the folder is logged as `no delete cap is in effect` rather than being applied
  silently. `config/config.example` and `docs/TROUBLESHOOTING.md` now explain the translation, both
  edges, and the trap upstream documents where renaming a directory that holds more than half the
  files looks like a mass deletion. Five regression cases cover the matrix.
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

[Unreleased]: https://github.com/Xcli0126/rclone-onedrive-tray/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/Xcli0126/rclone-onedrive-tray/releases/tag/v1.4.0
[1.3.0]: https://github.com/Xcli0126/rclone-onedrive-tray/releases/tag/v1.3.0
[1.2.0]: https://github.com/Xcli0126/rclone-onedrive-tray/releases/tag/v1.2.0
[1.1.0]: https://github.com/Xcli0126/rclone-onedrive-tray/releases/tag/v1.1.0
[1.0.0]: https://github.com/Xcli0126/rclone-onedrive-tray/releases/tag/v1.0.0
