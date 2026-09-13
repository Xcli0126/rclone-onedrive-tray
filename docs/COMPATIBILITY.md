# Compatibility

What has actually been run, on which machine, and what has not been run at all.
`docs/DEPENDENCIES.md` lists what the project needs. This file says how much of
that list has been exercised, because "it should work on any Linux" is a guess
and a guess is not something you can plan an install around.

## The test suites

Four scripts, none of which needs an rclone remote and all safe on a working setup:

```bash
tests/dependency-matrix.sh      # 31 cases: one missing dependency at a time, plus the tray
tests/install-flow.sh           # 63 cases: the documented install path, end to end
tests/filters.sh                # 27 cases: the default filters still filter, plus the checker
tests/docs.sh                   # 27 cases: the links and rules the docs depend on
```

Add `--verbose` to any of them to see each command and its output.

`dependency-matrix.sh` hides a single dependency and checks that what happens
matches what the documentation promises: the tray must name the apt package it
needs, the wrapper must refuse to run rather than quietly skip, the installer
must warn about an rclone that is too old. Missing typelibs are simulated by a
`sitecustomize.py` on `PYTHONPATH`, missing commands by a `PATH` built from
symlinks that deliberately leaves them out.

`filters.sh` runs rclone over a fixture tree containing one file per default
rule and checks that each one is really excluded and that the look-alike
legitimate files survive. It also carries the regression cases for
`onedrive-check`: a `LOCAL` with a trailing slash, a `--max` that is not a
positive integer, a newline inside a name, an unreadable directory, the reserved
name stems, and the rename classes rclone applies that Microsoft does not
document. It exists because every rule in the shipped filter file
was inert for a while: the patterns were quoted, which rclone reads as part of
the pattern. `dependency-matrix.sh` also carries the tray's display-free regression cases: every
string the tray passes to its translator is English prose rather than a bare key,
every one has a Chinese entry, no dialog uses locale-dependent stock buttons, a
disabled or unreadable timer unit is not reported as a pause, and a quoted
`OPEN_APP_CMD` is split rather than passed through with its quotes.
`docs.sh` checks what the documentation claims about itself: every
relative link between the markdown files resolves, no page has picked up an em
dash, the scripts and unit templates the READMEs name are still in the tree, and
every script in `bin/` is both installed and uninstalled.

`install-flow.sh` runs `setup.sh --yes` and `uninstall.sh` for real, with `HOME`
and every XDG directory pointed into a temporary tree. It checks the files
README says appear, that `systemd-analyze verify` accepts the generated units,
that the installed wrapper hands rclone the documented argument list, that two
overlapping runs serialise on the lock, and that the watcher asks systemd to
start a sync after a local edit.

None of them touch a live installation. They point `HOME` and the XDG
directories at a temporary tree, use a probe unit name instead of
`onedrive-sync`, stub rclone, systemctl and sudo, and remove that tree on exit.
The machine-wide NetworkManager hook in `/etc` is deliberately out of reach: the
tests assert that `sudo` was never called.

## Verified on this machine

The setup these scripts were developed against, and where every measurement in
README comes from:

| Component | Version |
|---|---|
| Ubuntu | 26.04.1 LTS, x86_64 |
| Kernel | 7.0.0-31-generic |
| Desktop | GNOME Shell 50.1, Wayland session |
| systemd | 259 |
| bash | 5.3.9 |
| python3 | 3.14.4 |
| rclone | 1.75.1, a current build in `/usr/local/bin` |
| PyGObject | python3-gi 3.56.2 |
| GTK 3 typelib | 3.24.52 |
| AppIndicator typelib | gir1.2-ayatanaappindicator3-0.1 0.5.94 |
| pycairo | python3-cairo 1.27.0 |
| inotify-tools | 4.25.9 |

Measured against a real OneDrive account, roughly 700 files:

| Behaviour | Result |
|---|---|
| Local edit reaching the cloud | 18 to 26 seconds |
| SIGKILL during a sync | next run recovers in 15 to 18 seconds, no `--resync` |
| Sync after the network comes back | starts within 1 second of the dispatcher hook |
| Files reconciled at the time of writing | 708, no differences reported by `rclone check` |
| Timer interval | 5 minutes, and a run cannot overlap the next |

The limits `onedrive-check` enforces were measured the same way, against a
throwaway folder on a real personal account: a 364-character cloud path
uploaded, a 383-character one failed with `pathIsTooLong`, a file named `CON`
was refused, a file named `.lock` uploaded and then disappeared from listings,
and `~$draft.docx` uploaded normally. The measurements are in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) next to the checker that uses them.

## Verified in CI

Every push runs all four suites on a GitHub runner. That runner is a second
environment rather than a repeat of the first:

| Component | Version |
|---|---|
| Ubuntu | 24.04.5 LTS, x86_64 |
| Kernel | 6.17.0-1022-azure |
| systemd | 255 |
| bash | 5.2.21 |
| python3 | 3.12.3 |
| rclone | 1.60.1, the distribution build |

systemd 255 is four major versions behind the development machine, python3 is
3.12 rather than 3.14, and bash is 5.2 rather than 5.3, so a green run there
does say something the local run cannot.

The runner's rclone being 1.60.1 helps in one direction only. `install.sh`
warns about that version, which is one of the cases the matrix checks. The sync
itself is stubbed in the two suites that stub rclone, so nothing here proves that 1.60.1 syncs. It
does not, and `docs/DEPENDENCIES.md` explains what fails and why.

## An independent acceptance run

The documented path has also been walked end to end by someone with no prior
knowledge of the project, working only from the README and the pages it links,
against a fresh clone of an earlier commit. They built their own sandbox with a
redirected `HOME`, every `XDG_*` variable and `TMPDIR`, used a remote of type
`alias` pointing at a local directory because no Microsoft account was available,
and ran the install, the sync in both directions, deletions, a conflict, the
filters, the folder selection, the name checker, the tray as far as a headless
session allows, uninstall, and these suites.

That run is why the changelog above has entries about `install.sh` enabling a
unit it does not own, `uninstall.sh` reaching into `/etc`, `setup.sh --yes`
blocking on a browser sign-in, and the tray aborting without a display. Each of
those now has a regression case in `tests/`, and the two places where they did
not match the documentation were corrected rather than explained away.

## Not verified

Everything below is untested. It may well work. Nobody has watched it work, so
treat it as unknown rather than supported.

- Distributions other than Ubuntu, and Ubuntu releases other than 24.04 and
  26.04. Debian, Fedora, Arch and openSUSE ship the same pieces under different
  package names, and the installer's apt line will not help you find them.
- Desktop shells other than GNOME, and GNOME versions other than 50. CI has no
  desktop session, so there the tray is only exercised as far as importing its
  bindings; that it draws a working panel icon has been seen on one machine.
- X11. Only a Wayland session has been used, and the tray draws its own icons
  through cairo, which is where a difference would show up first.
- macOS, Windows and WSL. The scripts assume systemd user units and POSIX
  `flock`.
- systemd older than 250. The units use `OnUnitInactiveSec` and a transient
  `systemd-run` timer for the timed pause, both long-standing features, but the
  versions in older long-term releases have not been tried.
- Non-systemd init systems. Without a user session there is no timer, and the
  scripts will say so rather than pretend.
- rclone below 1.65. Only the warning path is tested; a sync with such a build
  fails on the unknown flags, and the wrapper now names the version problem
  instead of pointing at an empty log.
- The first full sync of a large remote. It is a single long download, and how
  it behaves on a slow link or over a metered connection is not something this
  machine could show.
- Suspend and resume. The dispatcher hook covers the reconnect, but hibernate
  with a sync in flight has not been reproduced.
- More than one account or more than one config at a time.
- The tray's panel icon itself, and its notifications. A one-off test on a
  private Broadway display constructed the real menu and activated every handler
  with stubs, which found the ten defects listed in the changelog, and the
  display-free cases above now guard the ones that can be checked without a
  display. What no test here can show is the icon appearing in a panel: this
  machine has no StatusNotifier host, so the indicator falls back and the shell
  is what would render and click it.
- Activating the systemd units inside a sandbox. A sandbox has no user manager of
  its own, so the suites write the units and run `systemd-analyze verify`; whether
  systemd loads and schedules them was measured on the development machine, where
  the timer has been running at a five minute interval.
- Installing the NetworkManager hook into `/etc`, which needs root. The generated
  hook text is checked; the install itself and the hook firing were exercised by
  hand on one machine.
- Work and school accounts, and installing on a machine with no browser. Only a
  personal account on a desktop has been authorised here. The other routes in
  [SIGNING-IN.md](SIGNING-IN.md) are rclone's documented ones, not ones this
  project has watched work.

## If your machine is not in the table

Run all four suites. They do not need your OneDrive account, they take under a
minute, and a failure prints the assertion that disagreed with the
documentation. That output is the useful thing to send, along with the versions
from the first table.
