# Troubleshooting

Everything below is a failure mode that was actually hit and diagnosed while building this.
Symptoms first, then cause, then fix.

Signing in for the first time is not a failure mode, so it has its own page:
[SIGNING-IN.md](SIGNING-IN.md).

---

## 1. Authorisation

### "This is not the correct page. Please close this app or window and try again." (`/common/wrongplace`)

**Symptom:** You complete a Microsoft sign-in for a Linux OneDrive client and the browser lands
on an error page. The URL contains `/common/wrongplace`.

**Cause:** Many Linux OneDrive tools (including `abraunegg/onedrive`) authorise against the
redirect URI `https://login.microsoftonline.com/common/oauth2/nativeclient`. Microsoft has
deprecated that endpoint; the redirect is judged invalid and bounced to `/common/wrongplace`.
Nothing is wrong with your account or your browser.

**Fix:** Don't use the redirect flow. Two options:

- Use `rclone` (what this project does). rclone ships its own Azure app registration with a
  `http://localhost:53682/` redirect, which is still supported: the browser hands the code to a
  local listener automatically, so there is no URL to copy.
- If you must use `abraunegg/onedrive`, enable the OAuth2 **device** flow in
  `~/.config/onedrive/config`:

  ```
  use_device_auth = "true"
  ```

  Then it prints a short code and asks you to type it at `https://login.microsoft.com/device`.

### Device code rejected as "expired" even though it just appeared

**Symptom:** The client prints a fresh 9-character code; you enter it on the Microsoft page
within a minute and the page says the code has expired. Meanwhile the token endpoint keeps
answering `AADSTS70016: ... The user must input their code`, i.e. Microsoft never saw the code.

**Cause:** Almost always the characters that actually reached the input box. A CJK input method
in full-width mode turns `NUME6FDG3` into `ＮＵＭＥ６ＦＤＧ３`, which Microsoft reports with the
same "expired" wording it uses for genuinely stale codes. Copy-pasting the code avoids it
entirely.

**Diagnosis:** Poll the token endpoint yourself and compare:

```bash
curl -s -X POST https://login.microsoftonline.com/common/oauth2/v2.0/devicecode \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'client_id=<the app client id>' \
  --data-urlencode 'scope=Files.ReadWrite Files.ReadWrite.All Sites.ReadWrite.All offline_access'
```

If it answers `authorization_pending`, the code is alive and the problem is on the input side,
not the code, not the clock. (Verify the clock anyway:

```bash
date -u; curl -sI https://login.microsoftonline.com/ | grep -i '^date:'
```

A large skew really does make device codes fail instantly.)

### GitHub release downloads hang (China)

**Symptom:** `https://github.com/.../releases/download/...` returns `HTTP 000`, or a "mirror"
crawls at ~900 B/s for a 100 MB file.

**Fixes that were verified working:**

- **Snap Store** for applications that publish there. `snap find <app>` and check that the
  publisher is the upstream vendor, not a third party.
- **Vendor's own CDN** where one exists. rclone serves current builds from
  `https://downloads.rclone.org/` (slow) and it is mirrored by several universities, e.g.
  `https://mirror.nju.edu.cn/rclone/rclone-current-linux-amd64.zip`, which measured ~16 MB/s.
- When you must use a third-party GitHub proxy, verify the download against the **sha256 digest
  in the GitHub API** (`assets[].digest`) before installing anything.

---

## 2. rclone + OneDrive

### `ObjectHandle is Invalid` / `invalidRequest` when rclone touches the remote

**Symptom:**

```
Failed to query root for drive "b!EXAMPLE0BUSINESSDRIVEID": HTTP error 400
{"error":{"code":"invalidRequest","message":"ObjectHandle is Invalid"}}
```

and then every command fails with `unable to get drive_id and drive_type`.

**Cause:** `/me/drives` can return several entries. On some accounts the first one is not a
usable drive, and older rclone picks it. (Here the account returned four `b!...` entries plus the
real one.)

**Diagnosis:**

```bash
rclone backend drives onedrive:          # may itself fail
# ask Graph directly with the stored token:
TOKEN=$(python3 -c "import configparser,json; \
  c=configparser.ConfigParser(); c.read('$HOME/.config/rclone/rclone.conf'); \
  print(json.loads(c['onedrive']['token'])['access_token'])")
curl -s -H "Authorization: Bearer $TOKEN" https://graph.microsoft.com/v1.0/me/drives
curl -s -H "Authorization: Bearer $TOKEN" https://graph.microsoft.com/v1.0/me/drive
```

`/me/drive` returns the default drive with the correct id (for a personal account it looks like
sixteen hex characters, `0123456789ABCDEF`, and *not* like `b!...`).

**Fix:** Pin it explicitly:

```bash
rclone config update onedrive drive_id 0123456789ABCDEF drive_type personal
```

### Business vs personal accounts

`drive_type` is `personal`, `business` or `documentLibrary`. For a personal account it is
`personal`. Check which account you actually authorised by asking `/me`.

---

## 3. `rclone bisync`

### After a suspend / power loss / crash, bisync refuses to run forever

**Symptom:**

```
ERROR : Bisync critical error: path1 and path2 are out of sync, run --resync to recover
ERROR : Bisync aborted. Must run --resync to recover.
```

or

```
ERROR : Bisync critical error: cannot read prior listing: open ...path2.lst: no such file
```

**Cause:** On **rclone < 1.65** an interrupted run invalidates the baseline and the only way out
is a manual `--resync`. On a laptop this is not an edge case: closing the lid mid-sync is
enough.

**Fix:** Upgrade rclone to 1.65 or newer and run with:

```sh
--resilient    # retry after less-serious errors instead of demanding --resync
--recover      # automatically recover from an interrupted run
```

Then a suspend is followed by an ordinary successful sync. (Verified: kill -9 mid-transfer,
next run recovered on its own and `rclone check` reported 0 differences.)

### `prior lock file found`: the lock outlives the process

**Symptom:**

```
NOTICE: Failed to bisync: prior lock file found: <cache>/bisync/<pair>.lck
```

and it keeps happening for as long as `--max-lock` allows.

**Cause:** The lock file records the owner PID and an expiry. After a crash the owner is gone but
the file remains, and rclone honours it until it expires.

**Fix (either).**

- Use a short `--max-lock` (`2m` is the minimum) so a crash costs at most two minutes.
  rclone renews the lock while a run is genuinely in progress, so long syncs are safe.
- Or have the wrapper clear locks whose PID is no longer alive, which is what `onedrive-sync`
  does, so recovery is immediate rather than two minutes:

```bash
pid=$(grep -o '"PID"[[:space:]]*:[[:space:]]*"[0-9]\+"' "$lck" | grep -o '[0-9]\+' | head -1)
[ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && rm -f "$lck"
```

> Do **not** pair a long `--max-lock` with the assumption that it only affects running syncs.
> Setting `--max-lock 45m` turns every crash into a 45-minute outage. That mistake was made
> while building this and cost a debugging round.

### "Too many deletes" aborts the run, and then it never succeeds again

**Symptom:** `--max-delete N` trips, the run aborts, and every later run aborts the same way
because the deletion is still pending.

**Cause:** This is the guard working: it exists so a wiped local folder can't erase the cloud.
But there is no automatic way out.

**Fix:** If the deletion is intentional, rebuild the baseline so both sides agree:

```bash
onedrive-sync --resync
```

If it is *not* intentional, restore the files locally and let the next run push them back.

`onedrive-sync` greps its own log for this case and records a hint telling you exactly this, and
the tray has a **Rebuild sync baseline (resync)…** menu entry for it.

### Conflict files appear: `foo.md.conflict1` / `.conflict2`

**Cause:** The file changed on both sides between two runs, so there is no safe automatic
answer. With `--conflict-resolve none` (the default) and `--conflict-loser num`, rclone keeps
*both* versions rather than dropping one.

**Fix:** Merge by hand, then delete the loser. To reduce how often this happens, exclude volatile
state: editor layout files, indexes, caches. See `config/filters.example`.

If you would rather have "newest wins" automatically, set
`--conflict-resolve newer --conflict-loser delete`, but that discards the other version
silently, which is a bad default for documents.

### Two runs at once corrupt everything

**Symptom:** Errors like `cannot remove lockfile ... no such file or directory` and
`cannot read prior listing`, with two rclone processes in `ps`.

**Cause:** Two `bisync` processes on the same pair delete each other's `.lst` listing files.

**Fix:** Serialise them. `onedrive-sync` holds a `flock` for the whole run, so a manual "sync
now" during a timer run waits (up to 120 s) instead of racing. If you drive rclone yourself, do
the same:

```bash
# Not /tmp: a fixed name there is world-writable, so any local user can hold it
# and stall your sync, and two people's jobs would collide.
LOCK="${XDG_CACHE_HOME:-$HOME/.cache}/rclone/bisync/manual.lck"
mkdir -p "$(dirname "$LOCK")"
exec 9>"$LOCK"
if ! flock -w 120 9; then
    echo "another sync is already running" >&2
    exit 1
fi
```

### The sync aborts with "too many deletes"

**Symptom:** the run stops with `Safety abort: too many deletes (>13%, 104 of 750)`, the log says the
rule that tripped, and the wrapper reports `[maxdelete]`.

**Cause:** rclone bisync reads `--max-delete` as a percentage of the file pair, and aborts when more
than that share would be deleted. Its own default is 50%, described upstream as a guard against
losing everything after a network failure or a mistake. This project's `MAX_DELETE` is a count, so
the wrapper converts it: `MAX_DELETE=100` over a 750-file folder becomes `--max-delete 13%`. The log
records the conversion on every run.

The conversion has two edges, both recorded in the log:

- `MAX_DELETE=0` refuses every deletion.
- A `MAX_DELETE` at least as large as the folder means no cap at all. The log says
  `no delete cap is in effect`, because passing 100 would otherwise switch off rclone's 50% default
  silently.

A value that is not a number is ignored with a warning, which leaves rclone's own 50% in place.

**One documented trap:** renaming a directory that holds more than half the files looks to bisync
like a mass deletion followed by a mass upload, and it trips this check. Upstream suggests
`--max-delete 75` or `--force` for that case.

**Fix:** if the deletions are intended, run it once with the check bypassed:

```bash
onedrive-sync --force
```

`--force` is passed straight to rclone and the log records that it was given. Raising `MAX_DELETE`
in the config also works and keeps the cap for later runs.

### The run aborts with an access check failure, and nothing was changed

**Symptom:** the run stops with

```
ERROR : Access test failed: Path1 count 1, Path2 count 0 - RCLONE_TEST
ERROR : -          Access test failed: Path1 file not found in Path2 - RCLONE_TEST
ERROR : Bisync critical error: check file check failed
```

and rclone exits 7. The wrapper reports it with the `[access]` tag. No file is copied or deleted.

**Cause:** this is rclone's own `--check-access`, switched on with `CHECK_ACCESS="1"`. It looks for
a marker file in the same places on both sides before it changes anything. The failure it catches is
the one this project cares most about: a network, authorisation or mount problem leaves one side
looking empty, and bisync reads that as "everything over there was deleted". Measured on rclone
1.75.1, the same state without the flag deletes the missing side's files from the readable side. It
is the second safety net beside `MAX_DELETE`: the cap limits how much one run may remove, the access
check refuses to run against a tree it cannot read at all.

**Turn it on:**

```bash
onedrive-check-access                # creates the marker file on both sides
# then set CHECK_ACCESS="1" in ~/.config/rclone-onedrive-tray/config
onedrive-sync --resync               # once, because the flag set changed
```

`onedrive-check-access` is the file creation step: rclone never creates the marker itself. It writes
`RCLONE_TEST` at the root of the local folder and copies it to the root of the remote with
`rclone copyto`, so running it a second time transfers nothing. `--dry-run` says what it would do.

The check is on `--resync` runs too, so `--resync` is not a way to set the files up. Set the key off,
create them, and turn it back on.

**A marker you already have:** `CHECK_FILENAME=".sync-id"` makes the check look for that name instead
of `RCLONE_TEST`. Upstream recommends a file your tree already uses in many places: the check compares
the count and the directories on both sides, so one marker at the root only proves the root is
readable, while a name that is everywhere catches a half-readable tree. The tradeoff is that the
script cannot create a file you already own, so keeping it present on both sides is yours.

**An empty marker file counts as present.** Measured: rclone compares names and locations, never
contents, so a zero-byte `RCLONE_TEST` passes and the run proceeds. The abort above means the file is
missing entirely on one side.

**Fix:** work out which side is unreadable instead of disarming the check.

```bash
rclone lsf --files-only --max-depth 1 onedrive:Vault | grep RCLONE_TEST   # does the remote see it?
ls ~/OneDrive/Vault/RCLONE_TEST                                           # does the mount see it?
onedrive-check-access                                                     # put it back on both sides
```

Do not answer this with `--resync` or `--force`. Both make the run proceed, the first uploads the
readable side over the other and the second does the same for the deletion path, which is exactly the
loss the check just prevented. With `--resilient`, which this project sets by default, the abort does
not lock anything out: the next scheduled run retries on its own once the marker is readable again.

### Changing filters requires a resync

Adding an `--exclude` to the filter file changes the baseline. Run `onedrive-sync --resync` once
afterwards.

The tray's folder selection is different: entries in `exclude-folders.txt` are passed as
`--exclude` on the command line and do not change the baseline, so ticking and unticking a folder
needs no resync and touches neither side.
Excluded files are *left alone on both sides*; they are not deleted.

---

## 4. Realtime sync

### Syncs fire back to back, forever

**Symptom:** the log shows a successful run, then another one a few seconds later, then another.

**Cause:** a sync writes into the very tree the watcher is watching. bisync rewrites directory
modification times on the local side ("Set directory modification time"), and that raises
`IN_ATTRIB` events.

**Fix:** `onedrive-watch` deliberately does not subscribe to `attrib`, and drains the event queue
for `WATCH_SETTLE` seconds after each run. If you still see repeats, raise `WATCH_SETTLE`.
Subscribing to `attrib` would make the loop unavoidable.

### `inotifywait: failed to watch ...: No space left on device`

**Cause:** the kernel caps inotify watches per user, often at 8192, and one watch is consumed per
directory.

```bash
cat /proc/sys/fs/inotify/max_user_watches
sudo sysctl -w fs.inotify.max_user_watches=524288
echo 'fs.inotify.max_user_watches=524288' | sudo tee /etc/sysctl.d/60-inotify.conf
```

A 700-file folder needs about 60 watches, so this only bites if you sync something like a
`node_modules` tree.

### Changes take minutes again

```bash
systemctl --user status onedrive-sync-watch.service
journalctl --user -u onedrive-sync-watch.service -f
```

If `inotify-tools` was installed after this project, the unit was never enabled. Re-run
`./install.sh`, or enable it directly:

```bash
systemctl --user enable --now onedrive-sync-watch.service
```

### Does the watcher see changes made on another machine?

No, and it cannot. rclone has no server-side push or notification channel, so a change made
elsewhere is only found when the timer runs. Lower `INTERVAL_MIN` if that matters more than the
extra polling.

### The sync does not start when the network comes back

```bash
ls -l /etc/NetworkManager/dispatcher.d/90-rclone-onedrive-tray
```

Missing means the hook was never installed: `./install.sh --with-nm-dispatcher`.

Present but doing nothing is usually a permission or overrun problem. NetworkManager runs
dispatcher scripts as root with a minimal environment and kills anything that overruns, which is
why the hook starts the unit with `--no-block` and exits straight away. Watch it run:

```bash
journalctl -u NetworkManager -f
# then toggle wifi off and on
```

The hook only pokes accounts that actually have the unit file in `~/.config/systemd/user/`, so a
second user on the same machine is left alone.

## 5. Selecting which folders sync

### I unticked a folder but it is still on disk

That is intended, and it is the safe half of the trade-off. `--exclude` makes bisync ignore the
folder on both sides; it deletes nothing. The tray asks separately whether to remove the local
copy, and that prompt is the only thing that removes it.

### The log says `File was deleted` but nothing was deleted

bisync prints that during its diff phase, comparing the current listing against its previous one.
A newly excluded folder looks deleted on both sides at once, which is not a conflict and triggers
no action. File counts on both sides stay the same.

### Unticking a folder deleted it from the cloud

It should not, and a controlled run with before/after counts on both sides showed it does not. If
you see it, the likelier cause is that something else deleted the folder locally and bisync
propagated that, which is ordinary two-way behaviour rather than the folder list. Find the run:

```bash
grep -n 'Queue delete' ~/.cache/rclone-onedrive-tray/sync.log
```

OneDrive keeps a recycle bin for 30 days.

### Can I list the folders to include instead?

No. The list is an exclusion list, so ticking the folders you want has the same effect. There is
no include-list mode.

## 6. systemd

### The service is killed half way through

**Cause:** `Type=oneshot` services default to `TimeoutStartSec=90s`. A first full sync of a big
folder easily takes longer.

**Fix:**

```ini
[Service]
Type=oneshot
TimeoutStartSec=1800
```

### `systemctl is-active` never returns `active`

**Cause:** For `Type=oneshot` it returns **`activating`** while the process runs, and `inactive`
afterwards. A UI that tests `== "active"` will never see a running sync.

**Fix:** Accept both:

```bash
systemctl --user show -p ActiveState --value <unit>   # active|activating|inactive
# or
case "$(systemctl --user is-active <unit>)" in active|activating) running=1 ;; esac
```

### The timer never fires again, and `list-timers` shows `NEXT -`

**Cause:** `OnUnitActiveSec=` is measured against a monotonic clock, and `list-timers` only shows
realtime-based elapses. The timer may be perfectly scheduled while displaying `-`.

**Check it properly:**

```bash
systemctl --user show <unit>.timer -p NextElapseUSecMonotonic -p LastTriggerUSec
```

`NextElapseUSecMonotonic` holding a value means it will fire. Also consider switching to
`OnUnitInactiveSec=`, which is the idiomatic choice for a `oneshot` service and cannot overlap.

### Nothing syncs before you log in

**Cause:** User services start with the graphical session.

**Fix:**

```bash
sudo loginctl enable-linger "$USER"
```

### `After=network-online.target` does nothing in a user unit

**Cause:** The user manager has no `network*` units; the dependency is silently a no-op
(`systemctl --user list-unit-files | grep network` returns nothing).

**Fix:** Don't rely on it. Retry instead: a sync that fails on a cold network succeeds on the
next attempt.

---

## 7. Tray icon

### No icon in the GNOME top bar

```bash
gnome-extensions info ubuntu-appindicators@ubuntu.com   # must be ACTIVE
gdbus call --session --dest org.kde.StatusNotifierWatcher \
  --object-path /StatusNotifierWatcher \
  --method org.freedesktop.DBus.Properties.Get \
  org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems
```

Your app should appear in the returned list. If the extension is missing install
`gnome-shell-extension-appindicator`; if the item is absent, the GIR bindings are missing:

```bash
sudo apt install gir1.2-ayatanaappindicator3-0.1
```

Note that `libayatana-appindicator3-1` (the runtime library) being installed is *not* enough:
the `gir1.2-*` package is what Python imports.

### The menu freezes for ~20 seconds

**Cause:** Launcher code like

```python
subprocess.run(f'xdg-open "{path}" &', shell=True, capture_output=True, timeout=20)
```

The `&` backgrounds the shell, but the child inherits the capture pipes, so `run()` blocks until
every descendant closes them, i.e. until the timeout. Called from the GTK main loop, that
freezes the menu.

**Fix:** Launch fully detached:

```python
subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                 stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
```

### A long-running tray gets slower and slower

**Cause:** Reading the whole log every few seconds (`f.readlines()[-600:]` still reads the entire
file) while the log grows unbounded; a sync every 5 minutes is ~240 KB/day, ~85 MB/year.

**Fix:** Seek to the end and read a fixed window, and rotate the log:

```python
size = os.path.getsize(path)
with open(path, "rb") as fh:
    if size > 64 * 1024:
        fh.seek(size - 64 * 1024)
        fh.readline()          # drop the truncated line
    text = fh.read().decode("utf-8", "replace")
```

### Two icons appear

Use a single-instance lock:

```python
handle = open("/tmp/rclone-onedrive-tray.lock", "w")
fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)   # raises if already held
```

### Editing a running shell script corrupts it

**Symptom:** A running `bash` script starts emitting `command not found` (`exit code 127`) or
nonsense after you save over it.

**Cause:** bash reads scripts lazily in chunks. Overwriting the file in place while it runs means
later chunks come from the new (or half-written) content. Python is unaffected: it compiles the
whole file at start.

**Fix:** Don't edit a script that may be running; stop it first. (During development here this
produced a confusing `rc=127` that looked like a `PATH` problem but wasn't.)

---

## 8. Names and paths OneDrive refuses

**Symptom:** the sync never reaches a clean state. The log repeats the same line on every run,
either `invalidRequest: pathIsTooLong: ... must be 400 characters or less` or a bare
`invalidRequest: Invalid request` with no explanation, while the rest of the folder is fine.

**Cause:** OneDrive rejected the item. bisync keeps the item on its retry list, so every later run
uploads it again, fails again, and leaves the rest of the sync looking healthy.

**What the service actually does.** Measured on rclone 1.75.1 against a personal account, one file
per case, in a throwaway folder that was deleted afterwards:

| Case | Result |
|---|---|
| 364-character cloud path | uploaded |
| 383-character cloud path | `pathIsTooLong` |
| a file named `CON` | `invalidRequest: Invalid request` |
| a file named `.lock` | uploaded, then absent from every listing |
| a file named `~$draft.docx` | uploaded normally |
| `a:b.md`, `trailing. ` | uploaded, stored under a look-alike name |

Two things follow from that table. The documented 400-character limit is not a working limit: the
failure showed up around 380, which is why the checker uses 380. And the reserved-name list is not
uniform. `CON` fails loudly, `.lock` uploads and then becomes invisible, and `~$` names upload
normally even though Microsoft documents them as reserved.

**Fix:** use the checker.

```bash
onedrive-check              # what will fail, what will be renamed, what is too long
onedrive-check --quiet      # exit status only, for a script
onedrive-check --max 5      # at most five entries per group
```

It groups what it finds into refused, renamed, and too long, and gives one entry per offending
subtree rather than one per file inside it. Renaming or moving the offending file locally is the
whole fix; the next run uploads it. Nothing in the cloud has to change, and a name that was already
uploaded under a look-alike stays where it is until you rename it there too.

What it counts as renamed is rclone's OneDrive encoding, not only the characters Microsoft lists:
the illegal set, a leading `~`, leading or trailing spaces, a trailing period, control characters,
`0x7f`, and bytes that are not valid UTF-8.

Reserved names are matched on the stem, so `CON.txt` and `aux.md` are refused as well as `CON` and
`AUX`, while `console.txt` is fine.

The exit status is part of the interface:

| Status | Meaning |
|---|---|
| 0 | the tree is fine, or the only findings are names that will be renamed |
| 1 | something will be refused or is too long, or the walk could not read part of the tree |
| 2 | a usage or configuration problem: a bad option, a `--max` that is not a positive integer, a missing config, or a `LOCAL` that does not exist |

That last row of status 1 matters: if a directory cannot be read, the report says the walk was
incomplete instead of claiming the tree is clean.

`onedrive-sync --resync` runs the checker first and writes the report to the log, because the
resync is the run that tries to upload everything. The tray has it under "Check file names".

The default filters in `config/filters.example` already skip the junk that most often causes this:
`~$*` for Office lock files, `.lock`, temp files, swap files and editor backups. If you edited that
file, compare it with the shipped one, and remember that changing it needs one resync.

---

## 9. General diagnosis recipes

```bash
# what is the sync actually doing?
tail -f ~/.cache/rclone-onedrive-tray/sync.log

# did systemd consider the last run a success?
systemctl --user status onedrive-sync.service
journalctl --user -u onedrive-sync.service -n 50 --no-pager

# when does the next run happen?
systemctl --user list-timers onedrive-sync.timer
systemctl --user show onedrive-sync.timer -p NextElapseUSecMonotonic

# are the two sides actually identical?  (ignores your filter rules)
rclone check "onedrive:" "$HOME/OneDrive" --exclude "/.rag/**"

# what does bisync think its own state is?
ls -la ~/.cache/rclone/bisync/

# is anything stuck holding a lock?
fuser -v /tmp/onedrive-sync.lock
```

**When in doubt, `--resync` is safe.** It re-establishes the baseline from whatever is currently
on both sides; it does not delete files that exist on only one side. It is not fast, and it should
not be interrupted, but it is the supported way out of an inconsistent state.
