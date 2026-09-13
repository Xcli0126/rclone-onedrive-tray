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
for f in bin/onedrive-sync bin/onedrive-tray bin/onedrive-watch bin/onedrive-check \
         systemd/onedrive-sync.service.in \
         systemd/onedrive-sync.timer.in systemd/onedrive-watch.service.in \
         autostart/rclone-onedrive-tray.desktop.in \
         config/config.example config/filters.example \
         setup.sh install.sh uninstall.sh; do
    check "$f exists" test -e "$f"
done

# ---------------------------------------------------------------- the suite count
# "Two scripts" survived three new test files, because nothing checked it and the
# commands underneath were right. The count is cheap to verify.
title "the number of suites the prose claims"
count=0
for path in tests/*.sh; do [ -f "$path" ] && count=$((count + 1)); done
case "$count" in
    2) want=Two ;; 3) want=Three ;; 4) want=Four ;; 5) want=Five ;; *) want="" ;;
esac
for f in README.md docs/COMPATIBILITY.md; do
    [ -f "$f" ] || continue
    claims="$(grep -oE '(Two|Three|Four|Five) (suites|scripts)' "$f" | awk '{print $1}' | sort -u)"
    if [ -z "$claims" ]; then
        skip "$f makes no claim about how many suites there are"
        continue
    fi
    while IFS= read -r stated; do
        if [ "$stated" = "$want" ]; then
            ok "$f says $stated, and there are $count"
        else
            bad "$f says $stated, but there are $count test suites"
        fi
    done <<<"$claims"
done

# ---------------------------------------------------------------- installer drift
# A script that install.sh ships and uninstall.sh forgets is invisible until
# somebody removes the package and finds a stray binary in ~/.local/bin.
title "install.sh and uninstall.sh agree about bin/"
for path in bin/*; do
    [ -f "$path" ] || continue
    name="$(basename "$path")"
    check "install.sh installs $name" grep -q "bin/$name\"" install.sh
    check "uninstall.sh removes $name" grep -q "BIN_DIR/$name" uninstall.sh
done

summary
