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

### Four parsers for one file format

`install.sh` reads the config with one `sed` expression, `uninstall.sh` with a
second, the tray parses it in Python (`load_config`, `KEY_RE`,
`shell_quote_value`), and `onedrive-sync` sources it with `.`. They do not agree:
the tray escapes a quote as `\"`, and neither `sed` expression can express that,
so a value the tray wrote reads back truncated in the installer.

Cost: a config that one program writes can be misread by another, and the failure
surfaces later in whichever program read it wrong.

A fix means one reader, or one writer plus readers that understand its escaping.
That is a new runtime file, which pulls `install.sh`, `uninstall.sh` and the
documentation along with it.

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

### Smaller, and real

- `SettingsDialog._worker` writes its failures into `self.failures` instead of
  returning them, which is the last method in the file that both computes and
  stores.
- The first-run wizard never offers the access check, so a fresh install ships
  with only the delete cap guarding it. The reason the key defaults to off is
  about upgrades, not new installs.
- A sync that fails inside one three-second poll raises no notification at all:
  the failure notification fires on the falling edge of the running state, and a
  run that starts and ends between two polls is never seen as running. The icon
  still shows the error.
- `tests/filters.sh` builds its 400-character name with
  `printf 'r%.0s' $(seq 1 400)`, which relies on word splitting of the `seq`
  output. It works, and it is the suite's own fixture.
- The duplication figures quoted in the 1.2.0 audit came from a hand-written
  six-line window script, not a clone detector, and `extras/` was never measured
  at all.
- `onedrive-check`'s name-length branch cannot fire on a local filesystem: the
  limit is the documented 255, and a filesystem refuses a name longer than 255
  bytes, so nothing on disk can reach it. It was found by mutating the limit to
  99999 and watching every suite stay green. The branch is kept for filesystems
  that allow longer names, and it is not tested because there is nothing to test
  it with.
- A folder listing or quota refresh that is already in flight when `REMOTE` moves
  can still store the answer for the remote before it. The re-ask a moved remote
  triggers is skipped while the worker is busy, and the worker does not check which
  remote it asked, so the stale answer lands and the menu shows the old account's
  folders until the answer after it arrives. It needs a generation counter or an
  answer tagged with the remote it belongs to, which is a larger change than the
  reload path.
- The settings window rewrites a line it changes without its `export ` prefix:
  `KEY_RE` matches `export REMOTE=`, and `update_config_file` writes the line back
  as `REMOTE=`. The value and the meaning are the same either way, so this is a
  hand-written file losing its style rather than a setting changing; it is written
  down because the reader now accepts the prefix and the writer does not produce
  it.
- A `RCLONE` that moves is re-resolved and the menu is rebuilt, but the folder list
  and the quota row are not cleared the way they are when `REMOTE` moves: they were
  fetched from the binary being left behind, so they can describe the wrong build
  until the next refresh. It needs the same clear-and-re-ask the remote gets.

### The tray's state is read out of English prose in a shared log

`onedrive-sync` writes its own messages and rclone's `--log-file` output into one
file, and the tray decides what happened by matching fragments of English in the
newest lines of it (`read_last_result`). What keeps that correct today is
ordering: rclone writes "Bisync successful" after its own failures, so the last
match wins. A wrapper message added after that line, or an rclone reword, flips a
green icon to red with no test between them. The wrapper already tags its own
hints as `[tag]` precisely so that consumers do not match English, and the doctor
matches English anyway.

The fix worth doing is one machine-readable line per run, a single `key=value` or
JSON line at the end of the log, with the current prose reader kept for one
release as a fallback. It would also retire the duplicated pattern table that the
documentation check now merely guards.

Reading the wrapper's `[tag]` instead of matching English is not that fix on its
own, which is why the doctor has not been switched to it: the doctor is what a
user runs when a run misbehaved, so it has to classify a log written by an older
version of the wrapper, or by rclone alone, and a table it owns is what lets it do
that. The two tables are held equal by `tests/docs.sh`.

### Two sync pairs cannot coexist, in three places

`UNIT_NAME` is a config knob and `install.sh --prefix` exists, but a second pair
would collide: the wrapper's lock is one file per cache directory, the tray's
pause stamp is one file per cache directory, and the tray's single-instance lock
is one fixed name, so only one pair can have a tray. None of that is written
down anywhere except here.

Either the three names get the unit name appended, which is a few lines, or the
single-pair limit is a decision. This entry exists so the next person does not
have to derive it from three file names.

## Accepted, with the reason

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
