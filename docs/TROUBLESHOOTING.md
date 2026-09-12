# Troubleshooting

Everything below is a failure mode that was actually hit and diagnosed while building this.
Symptoms first, then cause, then fix.

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
`0123456789ABCDEF`, and *not* like `b!...`).

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
exec 9>/tmp/onedrive-sync.lock
flock -n 9 || { echo "already running"; exit 0; }
```

### Changing filters requires a resync

Adding an `--exclude` changes the baseline. Run `onedrive-sync --resync` once afterwards.
Excluded files are *left alone on both sides*; they are not deleted.

---

## 4. systemd

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

## 5. Tray icon

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

## 6. General diagnosis recipes

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
