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
# The Chinese README is checked below, with characters.
for f in README.md docs/COMPATIBILITY.md CHANGELOG.md; do
    [ -f "$f" ] || continue
    claims="$(grep -oE '(Two|Three|Four|Five)( test)? (suites|scripts)|both (suites|scripts)' "$f" |
        sed -e 's/^both/Both/' | awk '{print $1}' | sort -u)"
    if [ -z "$claims" ]; then
        skip "$f makes no claim about how many suites there are"
        continue
    fi
    while IFS= read -r stated; do
        if [ "$stated" = "$want" ] || { [ "$stated" = "Both" ] && [ "$count" -eq 2 ]; }; then
            ok "$f says $stated, and there are $count"
        else
            bad "$f says $stated, but there are $count test suites"
        fi
    done <<<"$claims"
done

# The check above only matches a capitalised numeral at the start of a claim, so
# "all four suites" sat in three pages long after the fourth suite arrived. This
# second pass looks for that phrasing specifically, and deliberately not in
# CHANGELOG.md, which is a historical record and quotes counts from the past.
for f in README.md docs/COMPATIBILITY.md; do
    [ -f "$f" ] || continue
    while IFS= read -r stated; do
        [ -n "$stated" ] || continue
        word="$(printf '%s' "${stated:0:1}" | tr '[:lower:]' '[:upper:]')${stated:1:3}"
        if [ "$word" = "$want" ]; then
            ok "$f says \"$stated\", and there are $count"
        else
            bad "$f says \"$stated\", but there are $count test suites"
        fi
    done < <(grep -oiE 'all (two|three|four|five|six) (test )?(suites|scripts)' "$f" |
        sed -E 's/^all //' | sort -u)
done

# The Chinese README says it with characters, which no English grep above catches.
# 测试 is required: "两个脚本不会调用 sudo" is about the two installer scripts.
zh="$(grep -oE '(两|二|三|四|五|六)个测试脚本' README.zh-CN.md 2>/dev/null | sort -u || true)"
if [ -z "$zh" ]; then
    skip "README.zh-CN.md makes no claim about how many suites there are"
else
    case "$count" in
        2) want_zh="两" ;; 3) want_zh="三" ;; 4) want_zh="四" ;;
        5) want_zh="五" ;; 6) want_zh="六" ;; *) want_zh="" ;;
    esac
    while IFS= read -r stated; do
        if [ "${stated:0:1}" = "$want_zh" ]; then
            ok "README.zh-CN.md says $stated, and there are $count"
        else
            bad "README.zh-CN.md says $stated, but there are $count test suites"
        fi
    done <<<"$zh"
fi

# ------------------------------------------------- the failure tags cross a line
# onedrive-sync writes its failure hints into the log as "[tag] message", and the
# tray renders them by looking the tag up as a translation key, through a
# variable. The tray suite's check that every literal passed to t() is translated
# cannot see those, because the literal is the tag, not the message. A tag the
# tray has no text for shows raw English inside a Chinese UI.
title "the failure tags the wrapper writes and the tray renders"
wrapper_tags="$(grep -oE 'tag=[a-z]+' bin/onedrive-sync | sed 's/^tag=//' | sort -u)"
missing=0
for tag in $wrapper_tags; do
    if grep -qE "^        \"$tag\": " bin/onedrive-tray; then
        ok "the tray has text for the [$tag] tag"
    else
        bad "the wrapper writes [$tag] and the tray has no text for it"
        missing=$((missing + 1))
    fi
done
if [ -z "$wrapper_tags" ]; then
    bad "no tags were found in bin/onedrive-sync; the pattern or the wrapper moved"
fi

# ------------------------------------------------- the keys the settings window writes
# SETTINGS_DEFAULTS is the list of keys the tray's settings window writes. Every
# one of them has to be in the annotated config, or a reader of that file
# concludes the setting does not exist. This is how SHOW_ICON and
# NOTIFY_ON_SUCCESS were missing from it for two releases.
title "the keys the settings window writes are documented"
tray_keys="$(sed -n '/^SETTINGS_DEFAULTS = {/,/^}/p' bin/onedrive-tray |
    sed -n 's/^[[:space:]]*"\([A-Z_]*\)":.*/\1/p')"
if [ -z "$tray_keys" ]; then
    bad "could not read SETTINGS_DEFAULTS out of bin/onedrive-tray"
else
    for key in $tray_keys; do
        # The whole line, not just the key: a stray quote or a trailing token
        # makes the tray read a different value than the shell does, which is how
        # NOTIFY_ON_SUCCESS shipped as 1"" for two commits.
        check "config.example documents $key" \
            grep -qE "^$key=\"[^\"]*\"$" config/config.example
    done
fi

# --------------------------------------------- the one flag set three files write
# The wrapper has a built-in default for BISYNC_ARGS, config.example states it for
# the reader, and setup.sh writes it into every new config. Three copies of one
# string, and nothing compared them, so a flag added to one and not the others
# would change what a generated config does without changing what the wrapper
# defaults to.
title "the recovery flags are the same string everywhere"
wrapper_args="$(sed -n 's/^DEFAULT_BISYNC_ARGS="\(.*\)"$/\1/p' bin/onedrive-sync)"
example_args="$(sed -n 's/^BISYNC_ARGS="\(.*\)"$/\1/p' config/config.example)"
wizard_args="$(sed -n 's/^BISYNC_ARGS="\(.*\)"$/\1/p' setup.sh)"
if [ -z "$wrapper_args" ] || [ -z "$example_args" ] || [ -z "$wizard_args" ]; then
    bad "could not read the flag string out of one of the three files"
else
    check "config.example carries the wrapper's default" \
        test "$example_args" = "$wrapper_args"
    check "setup.sh writes the wrapper's default too" \
        test "$wizard_args" = "$wrapper_args"
fi

# ------------------------------------------- the failure patterns two files share
# onedrive-sync classifies rclone's output with these patterns and tags its own
# hint line "[tag] message"; onedrive-doctor reads the same log and carries a
# second copy of the same table, because a wrapper killed mid-run leaves raw
# rclone text and no tag. The copies were identical the day this was written and
# nothing kept them so: a class added to one would have the two disagree about the
# same failure, silently.
title "the failure patterns the wrapper and the doctor share"
wrapper_re="$(sed -n "s/^RE_\([A-Z_]*\)='\(.*\)'$/\1|\2/p" bin/onedrive-sync | sort)"
doctor_re="$(sed -n "s/^RE_\([A-Z_]*\)='\(.*\)'$/\1|\2/p" bin/onedrive-doctor | sort)"
if [ -z "$wrapper_re" ]; then
    bad "no RE_ patterns were found in bin/onedrive-sync"
else
    while IFS= read -r pair; do
        name="${pair%%|*}"
        if grep -qxF -- "$pair" <<<"$doctor_re"; then
            ok "both files classify RE_$name the same way"
        else
            bad "the wrapper and the doctor disagree about RE_$name"
        fi
    done <<<"$wrapper_re"
fi

# ---------------------------------------------------------------- installer drift
# A script that install.sh ships and uninstall.sh forgets is invisible until
# somebody removes the package and finds a stray binary in ~/.local/bin.
title "install.sh and uninstall.sh agree about bin/"
for path in bin/*; do
    [ -f "$path" ] || continue
    name="$(basename "$path")"
    check "install.sh installs $name" grep -q "bin/$name\"" install.sh
    # The real removal, not just a mention: the old pattern matched any line
    # naming the file, so deleting the rm left this check green.
    check "uninstall.sh removes $name" \
        grep -qE "rm[[:space:]]+-[rf]+.*\"[^\"]*BIN_DIR/$name\"" uninstall.sh
done

summary
