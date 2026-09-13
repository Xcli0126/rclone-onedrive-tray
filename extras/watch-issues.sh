#!/usr/bin/env bash
#
# watch-issues.sh: tell me when somebody files an issue.
#
# A maintainer tool, not part of the syncing. It asks the GitHub API for the
# open issues, compares them with the ones it has already reported, and raises a
# desktop notification plus a log line for anything new. Install the companion
# timer to have it run twice a day:
#
#     extras/install-issue-watch.sh
#
#   REPO=owner/name watch-issues.sh     check a different repository
#   watch-issues.sh --list              print the open issues and stop
#   watch-issues.sh --forget            forget what has been reported so far
#
set -uo pipefail

REPO="${REPO:-Xcli0126/rclone-onedrive-tray}"
# Overridable so this can point at a GitHub Enterprise instance, and so the
# tests can serve synthetic payloads from a local server.
API_BASE="${API_BASE:-https://api.github.com}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/rclone-onedrive-tray"
STATE="$CACHE/issues-seen"
LOG="$CACHE/issues.log"
API="$API_BASE/repos/$REPO/issues?state=open&per_page=50"

mkdir -p "$CACHE"

case "${1:-}" in
    --forget) rm -f "$STATE"; echo "forgot the reported issues"; exit 0 ;;
    --help|-h) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

command -v curl >/dev/null 2>&1 || { echo "watch-issues: curl is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "watch-issues: python3 is required" >&2; exit 1; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if ! curl -fsS --max-time 30 -H 'Accept: application/vnd.github+json' \
        "$API" -o "$TMP"; then
    echo "watch-issues: could not reach the GitHub API for $REPO" >&2
    exit 1
fi

REPO="$REPO" STATE="$STATE" LOG="$LOG" LIST_ONLY="$([ "${1:-}" = "--list" ] && echo 1 || echo 0)" \
python3 - "$TMP" <<'PY'
import json, os, subprocess, sys, time

repo = os.environ["REPO"]
state = os.environ["STATE"]
log = os.environ["LOG"]
list_only = os.environ.get("LIST_ONLY") == "1"

try:
    payload = json.load(open(sys.argv[1]))
except (OSError, ValueError) as exc:
    print(f"watch-issues: could not parse the API response: {exc}", file=sys.stderr)
    raise SystemExit(1)

if isinstance(payload, dict):                       # rate limited, or an error
    print(f"watch-issues: GitHub said: {payload.get('message', payload)}", file=sys.stderr)
    raise SystemExit(1)

# Pull requests are issues in the API; this project cares about reports.
issues = [i for i in payload if "pull_request" not in i]
numbers = [str(i["number"]) for i in issues]

if list_only:
    for i in issues:
        print(f'#{i["number"]:<4} {i["title"]}  ({i["user"]["login"]})')
    print(f"{len(issues)} open issue(s) on {repo}")
    raise SystemExit(0)

seen = set()
if os.path.exists(state):
    with open(state, encoding="utf-8") as fh:
        seen = {line.strip() for line in fh if line.strip()}

fresh = [i for i in issues if str(i["number"]) not in seen]

# Record everything currently open, so a reopened issue is not reported forever
# and a closed one stops being tracked.
with open(state, "w", encoding="utf-8") as fh:
    fh.write("\n".join(sorted(numbers)) + "\n")

if not fresh:
    print(f"no new issues ({len(issues)} open on {repo})")
    raise SystemExit(0)

lines = []
for i in fresh:
    lines.append(f'#{i["number"]} {i["title"]}  ({i["user"]["login"]})')
    lines.append(f'    {i["html_url"]}')

with open(log, "a", encoding="utf-8") as fh:
    fh.write(f'\n=== {time.strftime("%Y-%m-%d %H:%M:%S")}  {len(fresh)} new on {repo} ===\n')
    fh.write("\n".join(lines) + "\n")

print("\n".join(lines))

summary = f'{len(fresh)} new issue(s) on {repo}'
body = "\n".join(f'#{i["number"]} {i["title"]}' for i in fresh)
try:
    subprocess.run(["notify-send", "-a", "rclone-onedrive-tray", "-u", "normal",
                    summary, body], check=False)
except FileNotFoundError:
    pass
PY
