#!/usr/bin/env bash
#
# docs.sh: check what the documentation claims about itself.
#
# The prose in this project points at files, and files move. It also follows one
# writing rule that is easy to break by pasting in a paragraph from somewhere
# else. Both are cheap to check and expensive to notice by hand.
#
#   tests/docs.sh              run everything
#   tests/docs.sh --verbose    also print each file as it is checked
#
# No network, no rclone, nothing written outside a temporary directory.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SRC_DIR/tests/lib/harness.sh" "$@"

cd "$SRC_DIR" || exit 1

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # --others too, so a page that has not been committed yet is still checked.
    mapfile -t FILES < <(git ls-files --cached --others --exclude-standard '*.md')
else
    mapfile -t FILES < <(find . -name '*.md' -not -path './.git/*' | sed 's|^\./||')
fi

echo "documentation check, ${#FILES[@]} markdown files"

# ---------------------------------------------------------------- links
title "internal links"
broken=0
checked=0
for f in "${FILES[@]}"; do
    [ "$VERBOSE" = 1 ] && printf '        %s\n' "$f"
    while IFS= read -r target; do
        checked=$((checked + 1))
        if [ ! -e "$target" ]; then
            bad "$f -> $target does not exist"
            broken=1
        fi
    done < <(
        # Only relative targets: an absolute URL or a bare anchor is somebody
        # else's problem.
        grep -oE '\]\([^)]+\)' "$f" |
            sed -e 's/^](//' -e 's/)$//' |
            grep -vE '^(https?://|mailto:|#)' |
            sed -e 's/#.*$//' -e '/^$/d' |
            while IFS= read -r link; do
                case "$link" in
                    /*) printf '%s\n' "${link#/}" ;;
                    *)  printf '%s\n' "$(dirname "$f")/$link" | sed 's|^\./||' ;;
                esac
            done | sort -u
    )
done
if [ "$broken" -eq 0 ]; then
    ok "$checked relative links, all resolve"
fi

# ---------------------------------------------------------------- the writing rule
# Every paragraph in this repository was written without em dashes. They are the
# clearest tell that a page was generated rather than written, and they reappear
# as soon as someone pastes in a paragraph from elsewhere.
title "writing rules"
dashed=0
for f in "${FILES[@]}"; do
    hits="$(grep -n '—' "$f" || true)"
    if [ -n "$hits" ]; then
        bad "$f contains an em dash"
        printf '%s\n' "$hits" | head -3 | cut -c1-100 | sed 's/^/        /'
        dashed=1
    fi
done
[ "$dashed" -eq 0 ] && ok "no em dashes in ${#FILES[@]} files"

# ---------------------------------------------------------------- promised files
# The READMEs name the scripts and units that install.sh produces. If one is
# renamed, the install instructions quietly stop matching reality.
title "files the READMEs name"
for f in bin/onedrive-sync bin/onedrive-tray bin/onedrive-watch \
         systemd/onedrive-sync.service.in \
         systemd/onedrive-sync.timer.in systemd/onedrive-watch.service.in \
         autostart/rclone-onedrive-tray.desktop.in \
         config/config.example config/filters.example \
         setup.sh install.sh uninstall.sh; do
    check "$f exists" test -e "$f"
done

summary
