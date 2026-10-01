# Known issues

What this project knows is wrong, unproven, or deliberately left alone. It is not
the same page as [TROUBLESHOOTING](TROUBLESHOOTING.md): that one is for a user
whose sync has stopped, this one is for the code itself.

Everything found and fixed goes in `CHANGELOG.md`. What stays here is the work
that was reported and not done, with the reason, so it does not have to be
rediscovered. Most of this page comes from a full audit of the tree at the 1.2.0
release: 22 ranked findings, 19 of them fixed in the two rounds that followed,
and the three below left open. The same audit also listed a handful of
suspicions it did not act on; what survived review is folded into the entries
here.

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

### The delete cap walks the whole local tree on every run

To turn `MAX_DELETE` from a file count into the percentage rclone actually
compares against, `bin/onedrive-sync` counts the files under `LOCAL` with
`find "$LOCAL" -type f | wc -l`. On a large tree that is a full walk before every
sync, including the runs where the count only feeds that conversion.

The suite pins the current arithmetic (100 over 200 files becomes
`--max-delete 50`), so a cheaper bound has to keep it. Caching the count beside
the bisync listings, or deriving it from the listing the wrapper already reads,
are the two obvious routes.

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

## Accepted, with the reason

- `onedrive-tray --version` and `--help` need PyGObject, because the import guards
  run before the argument handling. On a machine where the tray is broken for the
  usual reason, the message it prints (which package is missing) is more useful
  than the version number. `tests/dependency-matrix.sh` pins that behaviour on
  purpose. Moving the imports behind `main()` would mean re-pointing that case at
  `tests/lib/load_module.py`, and nothing has needed the version badly enough to
  justify it yet.
- `rclone bisync` is experimental upstream. See the "Known limitations" section of
  the README.
- The panel icon needs an AppIndicator-compatible shell, which on stock GNOME
  means an extension. See the README.
- No per-file status in the file manager, no version history, no recycle bin.
  Each needs a Nautilus or Dolphin extension or a Microsoft service API, and
  [FEATURE-PARITY](FEATURE-PARITY.md) explains why they are out of scope.
