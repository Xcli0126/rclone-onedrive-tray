# Known issues

What this project knows is wrong, unproven, or deliberately left alone. It is not
the same page as [TROUBLESHOOTING](TROUBLESHOOTING.md): that one is for a user
whose sync has stopped, this one is for the code itself.

Everything found and fixed goes in `CHANGELOG.md`. What stays here is the work
that was reported and not done, with the reason, so it does not have to be
rediscovered. Two rounds of review feed it: an audit of the tree at the 1.2.0
release, which produced 22 ranked findings and fixed 19 of them, and a second
pass by a different model at 1.3.0, which found twelve more and fixed all of
them. What neither acted on is below, next to the limits that are deliberate.

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

### `NOTIFY_ON_SUCCESS=1` is silent for a scheduled run

The success notification only fires when the run was asked for from the tray. A
scheduled run that succeeds says nothing, which is not what the key's name
promises. The suite asserts today's behaviour in both directions, so changing it
has to be a deliberate decision rather than a tidy.

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
- `tests/filters.sh` builds its 400-character name with
  `printf 'r%.0s' $(seq 1 400)`, which relies on word splitting of the `seq`
  output. It works, and it is the suite's own fixture.
- The duplication figures quoted in the 1.2.0 audit came from a hand-written
  six-line window script, not a clone detector, and `extras/` was never measured
  at all.
- `uninstall.sh --purge` removes the configuration and the icon directory but not
  the cache directory, which holds the sync log, the lock and the pause stamp. A
  reinstalled copy therefore starts with the old log and, if a pause was in
  progress, its stamp. Nothing breaks, and the argument for deleting a log on
  uninstall is not obvious, so it stays until somebody wants it gone.
- `install.sh` quotes the `Exec=` line of the autostart entry but not `ExecStart=`
  in the systemd unit, so a prefix containing a space would still produce a unit
  whose `ExecStart` is two arguments. The default prefix has no space, so this is
  only reachable with `--prefix` pointing somewhere unusual.

## Accepted, with the reason

- `rclone bisync` is experimental upstream. See the "Known limitations" section of
  the README.
- The panel icon needs an AppIndicator-compatible shell, which on stock GNOME
  means an extension. See the README.
- No per-file status in the file manager, no version history, no recycle bin.
  Each needs a Nautilus or Dolphin extension or a Microsoft service API, and
  [FEATURE-PARITY](FEATURE-PARITY.md) explains why they are out of scope.
