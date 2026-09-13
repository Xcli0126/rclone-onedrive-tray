# Dependencies

Everything this project needs, why it needs it, and what actually happens when
something is missing. The short version for Debian and Ubuntu:

```bash
sudo apt install rclone python3-gi python3-cairo gir1.2-gtk-3.0 \
     gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7 inotify-tools
```

Then check that `rclone version` reports 1.65 or newer, because the version in
some distributions is too old to sync safely.

## Required

| Dependency | Package | Used by | If it is missing |
|---|---|---|---|
| rclone 1.65 or newer | `rclone`, or a current build in `/usr/local/bin` | every sync | Nothing syncs. Below 1.65 `--recover`, `--resilient`, `--max-lock` and `--conflict-resolve` do not exist, so an interrupted run needs a manual `--resync` |
| `flock` | `util-linux` (essential) | `onedrive-sync` | The wrapper refuses to start, because running without the lock lets a manual sync and the timer corrupt each other's listings |
| `bash` 4.4+ | `bash` (essential) | all shell scripts | Arrays used under `set -u` misbehave |
| systemd, user session | `systemd` | timer, watcher, timed pause | No scheduled sync at all |
| `python3` | `python3` | `onedrive-tray` | No tray icon |
| PyGObject | `python3-gi` | `onedrive-tray` | The tray exits with a message naming the packages to install |
| GTK 3 typelib | `gir1.2-gtk-3.0` | `onedrive-tray` | Same |
| AppIndicator typelib | `gir1.2-ayatanaappindicator3-0.1`, or `gir1.2-appindicator3-0.1` | tray icon | Same. The runtime library `libayatana-appindicator3-1` is not enough: the `gir1.2-*` package is what Python imports |
| pycairo | `python3-cairo` | draws the five status icons | Same. The icons are drawn at startup, so without it there would be an invisible tray entry with no explanation |
| xdg-utils | `xdg-utils` | "Open sync folder", "View sync log" | Those two menu items do nothing |
| An AppIndicator-capable shell | `gnome-shell-extension-appindicator` on stock GNOME | icon visibility | The tray runs and logs normally, but nothing appears in the panel |

## Optional

| Dependency | Package | Adds | Without it |
|---|---|---|---|
| inotify-tools | `inotify-tools` | Realtime sync. Local edits reach the cloud in seconds | The timer still syncs, just on its own schedule. `install.sh` warns and carries on |
| Notification bindings | `gir1.2-notify-0.7` | Desktop notifications, including the reason a sync failed | The tray prints one line at startup and runs without notifications |
| NetworkManager | `network-manager` | The optional dispatcher hook, so waking from suspend catches up immediately | The next timer tick handles it instead |
| `sudo` | `sudo` | `install.sh --with-nm-dispatcher`, and `uninstall.sh` removing the hook | Everything else installs and runs without root |
| `curl` | `curl` | `extras/watch-issues.sh`, the maintainer issue poller | That tool reports that it cannot run. Sync is unaffected |
| `notify-send` | `libnotify-bin` | The issue poller's notification | It still logs what it found, just silently |

## Not a package

An authorised rclone remote. Run `rclone config` once and confirm with
`rclone lsd yourremote:`. Without it there is nothing to sync, and the log says
so in plain terms.

## Checking your machine

```bash
# the scripts name what is missing rather than printing a traceback
onedrive-tray            # exits with the apt line if bindings are absent
onedrive-sync            # exits with a message if rclone or flock is absent

# manual equivalent
rclone version | head -1
python3 -c 'import gi; gi.require_version("Gtk","3.0"); gi.require_version("AyatanaAppIndicator3","0.1")'
python3 -c 'import cairo'
command -v inotifywait flock xdg-open
systemctl --user is-system-running
```

## Why rclone is called out separately

It is the one dependency that is often present but too old. A distribution that
ships 1.60 gives you a working program that breaks the first time a laptop
suspends mid-sync, and the failure looks like a bug in this project rather than
a version problem. `install.sh` warns when it sees a version below 1.65, and
`docs/TROUBLESHOOTING.md` explains the recovery.
