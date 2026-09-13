# Signing in to OneDrive

The tray and the sync loop never talk to Microsoft themselves. They run `rclone`,
and rclone holds the account. So signing in is one step, done once, before
`setup.sh` has anything to work with. This page is that step.

If you already have a working remote, check it and skip to the end:

```bash
rclone listremotes
rclone lsd onedrive:
```

## The short version

On a desktop with a browser, for a personal account:

```bash
rclone config create onedrive onedrive
rclone lsd onedrive:            # must list your top-level folders
rclone about onedrive:          # must print your quota
```

`config create` skips the menus and uses the defaults, which is what `setup.sh`
runs for you when it finds no remotes. Those defaults are right for one personal
account on the machine you are sitting at. Anything else, meaning a work
account, a national cloud, your own app registration or a machine without a
browser, needs the full `rclone config` menu.

## What the browser flow asks

The prompts below are rclone's, not this project's. Names are stable across
recent versions; numbering is not, so answer by name.

`client_id` and `client_secret` are left blank. That means every rclone user
shares one Microsoft app registration. It is the normal setup and it works. You
only fill these in if you registered your own Azure app, usually to get around
throttling or a tenant that blocks the shared one.

`Edit advanced config?` is no.

`Use web browser to automatically authenticate rclone with remote?` is yes on a
desktop. rclone then starts a small web server on port 53682 and waits.

```
NOTICE: Make sure your Redirect URL is set to "http://localhost:53682/" in your custom config.
NOTICE: If your browser doesn't open automatically go to the following link: http://127.0.0.1:53682/auth?state=...
NOTICE: Log in and authorize rclone for access
NOTICE: Waiting for code...
```

If the browser does not open by itself, open the printed link. A host firewall
can block that port, and the token only arrives while rclone is waiting.

Sign in with the account that owns the OneDrive, then back in the terminal pick
what to attach:

```
 1 / OneDrive Personal or Business
 2 / Sharepoint site
 3 / Type in driveID
 4 / Type in SiteID
 5 / Search a Sharepoint site
```

Option 1 is what almost everyone wants. rclone then lists the drives it can see
and asks which one to use. Read that list rather than pressing enter: an account
that has both a personal OneDrive and a work one shows several, and the first
entry is not always the one you meant. Confirm the summary line, which prints the
drive type and the URL.

`region` stays `global` unless your account lives in one of the national clouds,
where it is `cn` for 21Vianet in China or `us` for the US Government cloud.

## Verify before you trust it

Both of these have to work before `setup.sh` is worth running:

```bash
rclone lsd onedrive:             # top-level folders
rclone about onedrive: --json    # quota: total, used, trashed, free
rclone config redacted onedrive  # drive_type and drive_id, token masked
```

The third one is also the safe thing to paste when you ask for help somewhere:
it prints the remote with the token replaced by `XXX`.

If they work but a sync then fails with `ObjectHandle is Invalid` or
`invalidRequest`, rclone picked a drive that the Graph API will not let it use.
That is a known trap with accounts that have more than one drive. The symptom,
the diagnosis with a direct Graph call, and the fix are in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) under "`ObjectHandle is Invalid`". The
short version is to name the drive explicitly:

```bash
rclone config update onedrive drive_id YOUR_DRIVE_ID drive_type personal
```

## No browser on this machine

A server, a NAS or an SSH session has no browser to open, so rclone has to be
handed a token that was minted somewhere else. rclone documents three ways to do
it, in [Remote Setup](https://rclone.org/remote_setup/). The one that avoids
copying credentials around is `rclone authorize`:

On the machine with a browser:

```bash
rclone authorize "onedrive"
```

It prints a block of text between `Paste the following into your remote
machine` and `End paste`. On the headless machine, run the full `rclone config`,
answer n to the browser question, and paste that block at `config_token>`.

None of this has been tested here, because this project has only ever been set
up on desktops.

## Work and school accounts

Option 1 above works for OneDrive for Business when your organisation allows the
shared rclone app registration. When it does not, the usual errors are
`access_denied (AADSTS65005)` and a publisher-verification complaint, and the
answer is your own app registration plus a tenant-specific `auth_url` and
`token_url`. rclone's [OneDrive page](https://rclone.org/onedrive/) walks through
that, including the non-admin route that reads a drive token out of the
SharePoint web client.

Only a personal account has been used with this project. Everything in this
section comes from rclone's documentation and the error strings themselves.

## When the token dies

An rclone remote that goes unused for 90 days loses its refresh token, and every
sync then fails with an authorisation error the wrapper reports as `[auth]`.
Re-authorising keeps the remote and its settings:

```bash
rclone config reconnect onedrive:
```

The default timer runs every five minutes, so this only bites a machine that has
been off for a season.

## Where the account lives

`~/.config/rclone/rclone.conf`, owned by you, mode 0600. It holds a refresh
token that grants access to the whole drive, so it is worth as much as your
password and belongs in no repository and no chat window. This project reads it
and never writes to it. `uninstall.sh` does not touch it either, so removing the
tray leaves your account connected.

Multiple accounts are multiple remotes, for example `onedrive-work:` and
`onedrive-personal:`. Each one becomes its own config in this project, with its
own local folder, its own units and its own log.
