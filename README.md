# rclone-onedrive-tray

**English** | [简体中文](README.zh-CN.md)

[![lint](https://github.com/Xcli0126/rclone-onedrive-tray/actions/workflows/lint.yml/badge.svg)](https://github.com/Xcli0126/rclone-onedrive-tray/actions/workflows/lint.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A OneDrive-style tray icon and a self-healing sync loop for Linux desktops, built on `rclone bisync`.

Linux has no official OneDrive client. `rclone bisync` handles the syncing, but rclone labels it
experimental, it ships without a user interface, and on versions older than 1.65 one interrupted
run is enough to break it. Close the laptop lid mid-sync and the next run stops with "Must run
--resync to recover", then keeps stopping until you run that command by hand.

This wraps it into something closer to what Windows users get: an icon in the tray, a desktop
notification when a sync fails, and a loop that recovers on its own.

```
   tray icon  ──────┐
                    ├──> onedrive-sync ──> rclone bisync ──> your cloud
 systemd timer ─────┘         │
                              └── retries · stale-lock recovery · log rotation
```

---

## Status icons

| Icon | State | Meaning |
|---|---|---|
| ![synced](assets/icons/synced.png) | `synced` | Last run finished successfully |
| ![syncing](assets/icons/syncing.png) | `syncing` | A sync is running right now |
| ![error](assets/icons/error.png) | `error` | Last run failed. The tooltip says why |
| ![paused](assets/icons/paused.png) | `paused` | Automatic sync is switched off |
| ![unknown](assets/icons/unknown.png) | `unknown` | Nothing has run yet |

---

## What you get

The tray icon carries one of those five states and opens a menu: sync now, open the synced
folder, open the log, pause automatic syncing, start at login, or rebuild the baseline. A failed
sync raises a notification with a plain-language reason, such as "network or DNS temporarily
unavailable" or "more than 100 files would be deleted".

The menu also reports how much of the account is in use, read from `rclone about` and refreshed
every 30 minutes on a background thread so it never stalls the UI. While a run is in flight the
status line carries live progress: percentage, throughput, and the name of the file moving.

Local edits sync in seconds rather than at the next timer tick. A watcher on the sync folder
starts a run as soon as the changes stop arriving; a new file measured 26 seconds from write to
cloud confirmation, most of which is the debounce plus one full bisync pass. Changes made on
another machine still wait for the timer, because rclone has no server-side push and nothing
local can notice them.

The sync wrapper covers what `rclone bisync` leaves to you.

An interrupted run heals by itself. The wrapper passes `--recover` and `--resilient`, so a
suspend or a crash is followed by an ordinary sync instead of a demand for manual work. Killing
a sync mid-transfer and re-running it recovers in about 18 seconds.

Stale locks clear themselves too. bisync writes a lock file naming the process that holds it.
After a suspend that process is gone but the file stays, and bisync refuses to run until the lock
expires. The wrapper checks whether the PID still exists and drops the lock if it does not, which
matters because a generous `--max-lock` turns one crash into an hour of downtime.

Overlapping runs are impossible. The wrapper holds a `flock` for the duration of a run, so
clicking "Sync now" while the timer fires waits instead of racing. Two bisync processes on the
same file pair delete each other's listing files, and the recovery costs a full `--resync`.

Deletions are capped at `MAX_DELETE` files per run. A wiped local folder aborts the sync rather
than propagating to the cloud, though it does mean a deliberate bulk delete needs
`onedrive-sync --resync` afterwards.

Conflicts keep both copies. When a file changed on both sides, rclone renames both versions
instead of picking a winner, so nothing is lost. The cost is that you merge them by hand.

The log rotates at 5 MB, and the tray reads only the last 64 KB of it. A sync every five minutes
writes roughly 240 KB a day, which is harmless for the disk but not for a `readlines()` call
running every three seconds for a year.

The process model stays small: one long-lived watcher, a systemd user timer, and a `oneshot` sync
service. Nothing holds your files open or talks to the network while idle, and one shell-style
config file drives all of it, so no paths are hard-coded.

---

## Requirements

| Component | Needed for | If it is missing |
|---|---|---|
| Linux with systemd (user session) | Timer, watcher, timed pause | Nothing syncs on a schedule |
| [rclone](https://rclone.org/downloads/) 1.65 or newer | Every sync | Nothing syncs. Below 1.65 an interrupted run needs a manual `--resync` |
| `python3-gi`, `python3-cairo`, `gir1.2-gtk-3.0` | Tray app and its icons | The tray exits and names the packages |
| `gir1.2-ayatanaappindicator3-0.1` | Tray icon | Same. The `libayatana-appindicator3-1` runtime library is not enough on its own |
| `gir1.2-notify-0.7` | Desktop notifications | The tray runs and says so, without notifications |
| `util-linux` (`flock`) | Serialising sync runs | The wrapper refuses to start rather than risk corrupting bisync state |
| `xdg-utils` | "Open sync folder", "View sync log" | Those two menu items do nothing |
| `inotify-tools` | Realtime sync | The timer still syncs, on its own schedule |

On Debian or Ubuntu:

```bash
sudo apt install rclone python3-gi python3-cairo gir1.2-gtk-3.0 \
     gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7 inotify-tools
```

> The rclone version matters more than any other line here. The one in the Ubuntu archive can be
> years behind, so check `rclone version` first. Below 1.65, download a current build and put the
> binary in `/usr/local/bin`, which takes precedence over `/usr/bin`.

Every dependency, including the optional ones and the exact failure each absence causes, is
listed in [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md). Both the tray and the sync wrapper exit
with the install command rather than a traceback when something they need is absent. What has
actually been tested, and what has not, is in [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

---

## Install

```bash
git clone https://github.com/Xcli0126/rclone-onedrive-tray.git
cd rclone-onedrive-tray
./setup.sh
```

`setup.sh` walks through the four choices that matter: which remote, which remote folder, where
to keep it locally, and what to exclude. It writes the config, installs the units, and offers to
build the baseline. If you would rather not answer prompts:

```bash
./setup.sh --remote onedrive:Notes --local ~/OneDrive --filters obsidian --yes
```

`--yes` deliberately stops short of the first sync. That one downloads everything and must not be
interrupted, so it stays a decision you make rather than a side effect of answering "yes".

Everything lands in your home directory, and neither script calls `sudo`.

```
~/.local/bin/onedrive-sync, onedrive-tray, onedrive-watch, onedrive-check
~/.config/rclone-onedrive-tray/config, filters.txt, exclude-folders.txt
~/.config/systemd/user/onedrive-sync.{service,timer}
~/.config/systemd/user/onedrive-sync-watch.service
~/.config/autostart/rclone-onedrive-tray.desktop
~/.local/share/rclone-onedrive-tray/icons/          drawn at first start
```

To configure by hand instead, run `./install.sh` and edit the config yourself:

```bash
rclone config            # create/authorise a remote named e.g. "onedrive"
rclone lsd onedrive:     # should list your files
./install.sh
onedrive-sync --resync   # build the baseline; downloads everything
```

Signing in is the one step this project does not wrap, because rclone owns it and
rclone has to own it. [docs/SIGNING-IN.md](docs/SIGNING-IN.md) walks through what
the browser flow asks, what a work account needs, and what to do on a machine
with no browser. It also has the way to try the whole loop before signing in, with
a remote that points at a plain directory and needs no account at all.

### Trying it alongside an existing install

Installing over a working setup is how you end up debugging two of them at once,
so point everything at a scratch tree and give the units their own name. This
route needs no account: it syncs one directory to another.

```bash
export HOME=/tmp/trial/home
export XDG_CONFIG_HOME=/tmp/trial/config XDG_CACHE_HOME=/tmp/trial/cache
export XDG_DATA_HOME=/tmp/trial/data XDG_STATE_HOME=/tmp/trial/state
export XDG_RUNTIME_DIR=/tmp/trial/run          # systemd looks for its socket here
export TMPDIR=/tmp/trial/tmp
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" \
         "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$TMPDIR"
chmod 700 "$XDG_RUNTIME_DIR"

mkdir -p "$XDG_CONFIG_HOME/rclone" /tmp/trial/cloud /tmp/trial/local
export RCLONE_CONFIG="$XDG_CONFIG_HOME/rclone/rclone.conf"
rclone config create trial alias remote /tmp/trial/cloud

./setup.sh --remote trial: --local /tmp/trial/local --unit-name trial-sync --yes
```

Run `setup.sh` rather than `install.sh`. The wizard calls the installer itself,
and running the installer first writes the config that `setup.sh` then refuses to
overwrite.

Three things make the difference. `--unit-name` keeps the trial units away from
the real ones, because systemd unit names are global to your session and two
installs cannot both own `onedrive-sync.timer`. `RCLONE_CONFIG` has to point at
the trial's own file, because rclone keeps its accounts under `XDG_CONFIG_HOME`,
so the remote you just made is invisible to `setup.sh` without it. And
`XDG_RUNTIME_DIR` has to exist and be yours, or `systemctl --user` either reaches
your real session or fails outright. A scratch runtime directory holds no systemd
socket, so `install.sh` writes the units, reports that the manager cannot see
them, and enables nothing.

`uninstall.sh` leaves the NetworkManager hook in `/etc` alone unless it belongs
to the install being removed, so a trial cannot pull the hook out from under the
install you already have.

---

## Configuration

`~/.config/rclone-onedrive-tray/config`, with the annotated list in
[`config/config.example`](config/config.example).

```sh
REMOTE="onedrive:"            # rclone remote, optionally with a sub-path: "onedrive:Notes"
LOCAL="$HOME/OneDrive"        # local directory to keep in sync
INTERVAL_MIN="5"              # minutes between automatic syncs
MAX_DELETE="100"              # abort if a run would delete more than this
BISYNC_ARGS="--resilient --recover --max-lock 2m --conflict-resolve none --conflict-loser num"
FILTERS_FILE="$HOME/.config/rclone-onedrive-tray/filters.txt"
OPEN_APP_CMD=""               # optional: an app the tray can launch, e.g. "obsidian"
UI_LANG=""                    # tray language: en / zh (empty = follow $LANG)
```

`~/.config/rclone-onedrive-tray/exclude-folders.txt` lists top-level folders to leave off this
machine, one name per line. The tray's "Folders to sync" menu edits it, and `setup.sh` writes it
from `--skip-folders "Archive,Scratch"`. An empty file syncs everything. Each name becomes
`--exclude "/<name>/**"`, and a folder listed there keeps its copies on both sides until you
delete the local one yourself (or answer yes to the tray's prompt).

`~/.config/rclone-onedrive-tray/filters.txt` holds [rclone filter
rules](https://rclone.org/filtering/), one per line. Caches that every machine regenerates, and
per-machine UI state, are the usual things worth excluding. A starting point ships in
[`config/filters.example`](config/filters.example):

```
- /.rag/**                          # machine-local vector index (can be hundreds of MB)
- /.obsidian/workspace.json         # editor layout; flip-flops between machines
- .DS_Store
- **/__pycache__/**
```

> Changing `REMOTE`, `LOCAL`, `FILTERS_FILE` or `BISYNC_ARGS` invalidates the baseline. Run
> `onedrive-sync --resync` once afterwards.

---

## Usage

Mostly you don't. Click the tray icon when you want to:

```
Last sync 14:32
426.0 GiB of 1.0 TiB used (40%)
────────────────────────────────
Sync now
Open sync folder
View sync log
Folders to sync ▸        01-投资     ☑
                         02-工作     ☑
                         …
                         ────────
                         .rag        ☐
────────────────────────────────
Pause automatic sync ▸   30 minutes
                         2 hours
                         8 hours
                         ────────
                         Resume now
☑ Start tray at login
────────────────────────────────
Check file names
Rebuild sync baseline (resync)…
Quit
```

A ticked folder is kept on this machine. Unticking one stops syncing it and leaves both sides
alone, so nothing is lost; because a folder that is present locally but no longer synced is a
trap (edits in it go nowhere), the tray then offers to delete the local copy. Ticking it again
downloads it back. Dot-directories sit below the separator, since `.rag` and friends are worth
excluding too.

A timed pause stops both the timer and the watcher, then hands the restart to a transient
systemd timer, so the pause ends on its own whether or not the tray is still running. The menu
label shows when it comes back.

From a terminal:

```bash
onedrive-sync                 # one incremental sync (3 attempts)
onedrive-sync --resync        # rebuild the baseline
onedrive-check                # names and paths OneDrive will refuse
systemctl --user list-timers onedrive-sync.timer
systemctl --user start onedrive-sync.service     # sync now
journalctl --user -u onedrive-sync.service -f
tail -f ~/.cache/rclone-onedrive-tray/sync.log
```

### Names OneDrive will not take

OneDrive refuses some names outright and quietly renames others, and bisync finds that out the
expensive way: it uploads everything else, fails on the one item, and retries it on every run
from then on. `onedrive-check` walks the local tree and says what is wrong before that happens,
grouped into what will be refused, what rclone will rename on the way up, and what is too long:

```
onedrive-check: /home/you/OneDrive/Vault against onedrive:Vault

  OneDrive will refuse these (1)
    reserved name: Notes/CON
  OneDrive will rename these (1)
    Notes/plan:a.md -- '"*:<>?\|' in 'plan:a.md'
  These paths are too long (1)
    cloud path 412 chars: Notes/very/deep/...
```

It exits 0 when the tree is fine, 1 when something will actually fail, and 2 on a usage error, so
a script can tell "bad names" from "I called it wrong". `onedrive-sync --resync` runs it first and
logs the report, because that is the run that uploads everything. The tray has it as a menu item. The limits and how they were measured are in
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

### Syncing sooner after the network comes back

The watcher covers local edits and the timer covers periodic catch-up, but neither notices a
connection reappearing. Waking a laptop from suspend therefore waits for the next timer tick.

```bash
./install.sh --with-nm-dispatcher
```

That installs one script into `/etc/NetworkManager/dispatcher.d/`, which asks for the sync to run
as soon as an interface comes up. It is the only part of this project that needs root, and it is
opt-in. `./uninstall.sh` removes it.

### Syncing while logged out

User services start at login, so a machine sitting at the login screen syncs nothing. To change
that:

```bash
sudo loginctl enable-linger "$USER"
```

---

## Design notes

These decisions are deliberate. Each one closes a failure mode that is easy to hit and annoying
to diagnose.

The timer uses `OnUnitInactiveSec`, not `OnUnitActiveSec`. It schedules the next run a fixed
interval after the previous one finishes. Measuring from the start instead lets a slow sync
overlap the next one, and overlapping runs corrupt bisync's state files.

`TimeoutStartSec=1800` is there because systemd's default for `Type=oneshot` is 90 seconds. A
first sync of a large folder runs far longer, and would be killed part way through.

The `flock` exists because "Sync now" during a scheduled run is not a theoretical race. It
happens the first time you get impatient, and the pair ends up needing `--resync`.

Short `--max-lock` values are a trade-off. Two minutes means a crash costs two minutes of
downtime, while a long value means the same crash blocks syncing for most of an hour. rclone
renews the lock while a run is genuinely running, so a short value does not endanger long syncs.

`systemctl is-active` returns `activating` for a `oneshot` service, never `active`. A tray that
tests for `"active"` never sees a running sync and never sends a failure notification, which is
the one moment the notification matters.

---

## Known limitations

- `rclone bisync` is labelled experimental by rclone. Keep cloud-side version history or a
  separate backup for anything irreplaceable.
- Conflicts keep both files (`foo.txt` becomes `foo.txt.conflict1` and `.conflict2`). Nothing is
  lost, but you have to merge them by hand.
- Syncing a folder an application is actively writing to can produce conflicts. Excluding
  volatile state files, as the example filters do, avoids most of it.
- The tray icon needs an AppIndicator-compatible shell. Stock GNOME needs the AppIndicator
  extension; KDE, Xfce and Cinnamon work out of the box.
- Linux only.
- No Files On-Demand. Every synced file is a real file on disk, so the folder
  takes its full size. Unticking a folder in the tray and deleting the local copy
  is the way to reclaim space.
- No per-file status in the file manager, no share links, no version history
  browser, no metered-network or battery-saver pause. `onedrive-check` reports
  what OneDrive will refuse, but nothing stops you creating such a file. What the Windows and macOS
  clients do, which parts of it are worth having, and which are deliberately
  skipped are all written up in
  [docs/FEATURE-PARITY.md](docs/FEATURE-PARITY.md).

---

## Troubleshooting

Microsoft's deprecated `nativeclient` redirect, the `ObjectHandle is Invalid` drive-ID trap,
bisync's lock and resync behaviour, and why an interrupted sync used to demand manual
intervention are all written up in
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

---

## Uninstall

```bash
./uninstall.sh            # keeps your config
./uninstall.sh --purge    # removes config too
```

Your synced folder and the rclone remote are never touched.

---

## For maintainers

`extras/watch-issues.sh` asks the GitHub API for open issues, compares them with the ones it has
already reported, and raises a desktop notification for anything new. To have it run twice a day:

```bash
extras/install-issue-watch.sh
```

It writes what it found to `~/.cache/rclone-onedrive-tray/issues.log` and skips pull requests, so
only actual reports reach you. It needs `curl` and `notify-send`; the latter comes from
`libnotify-bin`, which the tray itself does not need.

```bash
watch-issues.sh --list      # print the open issues
watch-issues.sh --forget    # report everything again next time
```

### Tests

Four suites, none of which needs an rclone remote:

```bash
tests/dependency-matrix.sh      # hides one dependency at a time
tests/install-flow.sh           # the documented install path, in a sandbox
tests/filters.sh                # the default filters still filter
tests/docs.sh                   # internal links, writing rules, promised files
```

The first two point `HOME` and the XDG directories at a temporary tree, replace rclone, systemctl
and sudo with stubs, and use a probe unit name. `filters.sh` runs the real rclone over a fixture
directory, and `docs.sh` only reads the repository. None of them can disturb a working install.
`--verbose` shows every command and its output. CI runs all four on `ubuntu-latest`, which is a
different distribution, systemd and rclone from the machine they were written on.
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) records what they cover, the versions they have
been run against, and what nobody has tried yet.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE)
