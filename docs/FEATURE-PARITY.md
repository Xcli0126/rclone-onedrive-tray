# What the Windows and macOS clients do, and what matters here

OneDrive ships a sync client on two desktop platforms and this project replaces
neither. This page exists because "make it behave like OneDrive" is not a
specification, and because most of what those clients do is Microsoft-ecosystem
work that has no meaning on Linux.

The inventory is drawn from Microsoft's own documentation, not from memory or
from reviews. Where Microsoft documents nothing, that is said rather than
guessed. The last section lists the sources and the two gaps in them.

Status words used below: yes means it exists here and has been used, partial
means something narrower exists, no means it does not.

## Must have

These are the features a desktop user notices within a day. Nothing here is
decoration, and everything in this table is what the project spends its
complexity budget on.

| Feature | On Windows and macOS | Here |
|---|---|---|
| Tray or menu bar icon with a clear state | Overlay states for online-only, available, shared, blocked, error, paused, syncing, signed out | yes: five states, drawn with cairo (synced, syncing, error, paused, unknown) |
| Failure notification with a plain-language reason | Activity center plus toasts | yes: one line per failure, tagged `[lock]`, `[maxdelete]`, `[network]`, `[resync]`, `[auth]`, `[oldrclone]` or `[other]` |
| Pause and resume, with the paused state visible | 2, 8 or 24 hours | yes: 30 minutes, 2 hours or 8 hours, and the icon changes |
| A pause that survives closing the UI | Resume when the timer expires | yes: a transient `systemd-run --user --on-active` timer, not the tray process |
| Storage quota on screen | Warning icon near the limit, dashboard in the account | yes: `rclone about`, refreshed every 30 minutes |
| Conflicts keep both files | Microsoft documents no winner rule, only advice to rename | yes: `--conflict-resolve none --conflict-loser num`, and the log says which copy was renamed |
| A deletion cap | Notification above 200 deleted files, admin policy for confirmation | yes: `MAX_DELETE` aborts the run and reports `[maxdelete]` |
| Selective sync of top-level folders | "Choose folders" checkbox tree in settings | yes: `exclude-folders.txt` plus a tray submenu; measured to leave both sides untouched |
| Realtime detection of local edits | Built into the client | yes: inotify watcher, debounced |
| Recovery after suspend or a crash | Built into the client | yes: `--resilient --recover` plus stale-lock clearing, measured at 15 to 18 seconds |
| Runs that cannot overlap | One process | yes: a `flock` beside the cached state, and a second run waits |
| Sync as soon as the network returns | Built into the client | yes: NetworkManager dispatcher hook, measured under a second |
| Not syncing files the service rejects | A fixed internal list | partial: `.tmp`, `.partial`, `.DS_Store`, `Thumbs.db`, `desktop.ini` and editor swap files are in the default filters; `~$` Office lock files, `.lock` and the reserved names are not |
| Warning about names and paths the service will refuse | "Shorten path" and a rename action per item | no: an over-long path fails at upload and bisync retries it |
| Start at login | Built into the client | yes: an autostart entry |

## Worth having

Real value, in rough order of usefulness, but each one has a reason it is not
already here.

| Feature | On Windows and macOS | Here |
|---|---|---|
| Per-file status in the file manager | Explorer and Finder overlay icons | no: needs a Nautilus or Dolphin extension, so the tray tooltip carries the state instead |
| Copy a share link | "Share a OneDrive link" in the context menu | no: `rclone link` would make this a few lines |
| Version history | Right-click in Explorer, or the web | no |
| Recycle bin and restore | The web, and Explorer | no |
| Bandwidth limiting | Fixed rates per direction, or automatic | no: `--bwlimit` can be added to `BISYNC_ARGS` by hand, but nothing surfaces it |
| Pause on a metered network | Automatic, with a policy to override | no |
| Pause on battery saver | Automatic, with a policy to override | no |
| Mass-delete notification naming the files | Yes | partial: the run reports the cap it hit, not the files involved |
| Free up space | Dehydrate files to online-only | partial: unticking a folder offers to delete the local copy, which is the disk space people are actually after. Per-file dehydration needs FUSE placeholders and fights bisync's two-way model |
| Offer to adopt Documents and Pictures on first run | "Manage backup" toggles | no |
| Work or school account surfacing | Blocked file type icon, throttling notice | partial: quota yes, blocked file types and admin throttling no |

## Skip

Each of these is either Microsoft-service behaviour or something that would
conflict with how bisync works.

Personal Vault is documented for the web, mobile and Windows only, so macOS is
outside it too. It depends on Microsoft holding the keys and on a second factor,
and a Linux user who needs that is better served by gocryptfs or a VeraCrypt
volume.

Known Folder Move has no Linux equivalent to move. There are no known folders to
redirect, and unconditionally adopting `~/Documents` would break other
applications. The first-run offer above is the useful part.

Office co-authoring, AutoSave and differential sync for Office formats have no
Linux client to participate. rclone already transfers only files that changed,
and chunked upload is its concern rather than the tray's.

LAN sync is not a documented OneDrive feature, so there is nothing to match.
Storage Sense dehydrating files on a timer conflicts with two-way sync. Thumbnail
generation for hundreds of file types needs placeholders that cannot exist here.
OneNote notebook stubs open a web notebook. Camera roll and Bedtime Backup belong
to the phone apps. "Shared with me" is not a real folder in the API and Microsoft
does not sync that grouping for work accounts either.

Group Policy, Intune, per-machine installs, Windows Information Protection and
VDI support are administration surfaces for a platform this does not run on.

## Limits worth knowing

These are Microsoft's numbers. They explain failures that otherwise look like
bugs in this project.

| Limit | Value | What it means here |
|---|---|---|
| Cloud path | Under 400 characters including the file name | Longer paths fail at upload. Nothing warns first |
| Total sync path | 520 characters, of which the local root may be 120 | Microsoft's own client errors and pauses. Here bisync retries |
| File name | 255 characters | Same |
| Largest file | 250 GB | Larger files cannot be uploaded at all |
| Recommended item count | 300,000 per account | Above it, performance degrades even for items that are not synced |
| Invalid characters | `"` `*` `:` `<` `>` `?` `/` `\` `\|`, plus leading or trailing spaces | Microsoft's client renames them. rclone maps them to look-alike Unicode, so names change on the way up |
| Reserved names | `.lock`, `CON`, `PRN`, `AUX`, `NUL`, `COM0` to `COM9`, `LPT0` to `LPT9`, `_vti_`, `desktop.ini`, anything starting with `~$` | Rejected by the service |
| Files the Microsoft client never syncs | `.tmp` and `.ini` | This project syncs `.ini` on purpose, since on Linux those are usually real settings a user wants on both machines |
| Name case | The service is case insensitive | `Hello.doc` and `hello.doc` cannot coexist |
| Versions | OneDrive Personal creates a version on every change, and rclone cannot delete versions on Personal | Disk usage on the service can exceed the size of the folder. `no_versions` and `cleanup` are for work accounts only |
| Deletions | rclone deletes to the OneDrive recycle bin and cannot empty it | Emptying it needs the web interface |

## Where the gaps are, in order

If the next round of work is about parity, this is the order the gaps are worth
closing. It is a list, not a schedule.

1. `~$*` in the default filters. Office lock files are pure junk and they are the
   most likely cause of a first-run retry loop on a folder that has ever held a
   Word document.
2. A pre-flight path and name check, reported in the tray before an upload is
   attempted rather than after it fails.
3. Copy link, since `rclone link` already exists and it removes the main reason
   to open the OneDrive website.
4. Pausing on a metered connection, read from NetworkManager, behind a setting.
5. Bandwidth presets, written into `BISYNC_ARGS`.
6. Naming the files in a mass-delete report.

## Sources

Microsoft Support, the pages behind the tables above:

- [Save disk space with OneDrive Files On-Demand for Windows](https://support.microsoft.com/en-us/onedrive/save-disk-space-with-onedrive-files-on-demand-for-windows)
- [Save disk space with OneDrive Files On-Demand for Mac](https://support.microsoft.com/en-us/onedrive/save-disk-space-with-onedrive-files-on-demand-for-mac)
- [Choose which OneDrive folders to sync](https://support.microsoft.com/en-us/onedrive/choose-which-onedrive-folders-you-want-to-sync-on-windows-or-macos)
- [Back up your folders with OneDrive](https://support.microsoft.com/en-us/onedrive/back-up-your-folders-with-onedrive)
- [Protect your OneDrive files in Personal Vault](https://support.microsoft.com/en-us/onedrive/protect-your-onedrive-files-in-personal-vault)
- [How to pause and resume OneDrive sync](https://support.microsoft.com/en-us/onedrive/how-to-pause-and-resume-onedrive-sync)
- [What do the OneDrive icons mean](https://support.microsoft.com/en-us/onedrive/what-do-the-onedrive-icons-mean)
- [Restrictions and limitations in OneDrive and SharePoint](https://support.microsoft.com/en-us/onedrive/restrictions-and-limitations-in-onedrive-and-sharepoint)
- [What are the file path length limits](https://support.microsoft.com/en-us/onedrive/what-are-file-path-length-limits)
- [Why has my filename changed](https://support.microsoft.com/en-us/onedrive/why-has-my-filename-changed)
- [Restore a previous version of a file](https://support.microsoft.com/en-us/onedrive/restore-a-previous-version-of-a-file-stored-in-onedrive)
- [Restore deleted files or folders](https://support.microsoft.com/en-us/onedrive/restore-deleted-files-or-folders-in-onedrive)
- [Share files and folders in OneDrive](https://support.microsoft.com/en-us/onedrive/share-files-and-folders-in-microsoft-onedrive)
- [Add shortcuts to shared folders](https://support.microsoft.com/en-us/onedrive/add-shortcuts-to-shared-folders-in-onedrive)
- [Microsoft storage quotas](https://support.microsoft.com/en-us/onedrive/microsoft-storage-quotas)
- [Use OneDrive and Storage Sense in Windows](https://support.microsoft.com/en-us/onedrive/use-onedrive-and-storage-sense-in-windows-10-to-manage-disk-space)
- [Tips to improve OneDrive sync performance](https://support.microsoft.com/en-us/onedrive/tips-to-improve-onedrive-sync-performance)

Microsoft Learn:

- [Block file types](https://learn.microsoft.com/en-us/sharepoint/block-file-types)
- [Use Group Policy to control OneDrive sync settings](https://learn.microsoft.com/en-us/sharepoint/use-group-policy)
- [SharePoint Online limits](https://learn.microsoft.com/en-us/office365/servicedescriptions/sharepoint-online-service-description/sharepoint-online-limits)

Two gaps in those sources, recorded so nobody re-researches them:

- No Microsoft page was found documenting a conflict winner rule or the phrase
  "conflicted copy" for the desktop client. Keeping both copies is therefore the
  defensible choice rather than a deviation from a documented rule.
- No Microsoft page was found documenting a LAN or peer-to-peer sync feature for
  the desktop client.

The rclone side of the limits, the version behaviour and the recycle bin are from
[rclone's OneDrive page](https://rclone.org/onedrive/).
