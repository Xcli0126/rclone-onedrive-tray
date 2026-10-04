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

# ------------------------------------------------- the menu rows the tray builds
# The READMEs draw the tray's menu as a fenced block. A "Diagnostics…" row was
# added to the tray and to neither diagram, because nothing tied the two
# together. This reads the rows _build_action_items creates and requires each
# label, and the Chinese text it is given, to appear in the matching diagram. It
# covers the action rows at the bottom of the menu, which are the ones written
# there. The status, quota and pause rows above them carry runtime values, so
# they are out of scope.
diagram_block() {  # diagram_block <file> <anchor>
    awk -v anchor="$2" '
        /^```/ {
            if (open) { if (hit) { printf "%s", buf; exit } open = 0; buf = ""; hit = 0 }
            else { open = 1; buf = ""; hit = 0 }
            next
        }
        open { buf = buf $0 "\n"; if (index($0, anchor) > 0) hit = 1 }
    ' "$1"
}
block_has() { grep -qF -- "$2" <<<"$1"; }
title "the menu rows in the READMEs"
action_labels="$(awk '/^    def _build_action_items/{f=1; next} f && /^    def /{exit} f' \
    bin/onedrive-tray |
    grep -oE 'self\.t\("[^"]*"\)' | sed 's/^self\.t("//; s/")$//' | sort -u)"
if [ -z "$action_labels" ]; then
    bad "could not read the action rows out of bin/onedrive-tray"
else
    en_menu="$(diagram_block README.md 'Start tray at login')"
    zh_menu="$(diagram_block README.zh-CN.md '开机自动启动托盘')"
    [ -n "$en_menu" ] || bad "README.md has no fenced menu block"
    [ -n "$zh_menu" ] || bad "README.zh-CN.md has no fenced menu block"
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        check "README.md shows the \"$label\" row" block_has "$en_menu" "$label"
        zh="$(grep -F "\"$label\": " bin/onedrive-tray | head -1 | cut -d'"' -f4)"
        if [ -z "$zh" ]; then
            bad "bin/onedrive-tray has no Chinese text for the \"$label\" row"
        else
            check "README.zh-CN.md shows the \"$zh\" row" block_has "$zh_menu" "$zh"
        fi
    done <<<"$action_labels"
fi

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
    if [ "$tag" = other ]; then
        # `other` is the wrapper's "unclassified" tag, and the tray shows the raw
        # log line for it in every language: there is no sentence to translate, so
        # there is no entry to require.
        ok "the [$tag] tag needs no text: the tray shows the raw line"
    elif grep -qE "^        \"$tag\": " bin/onedrive-tray; then
        ok "the tray has text for the [$tag] tag"
    else
        bad "the wrapper writes [$tag] and the tray has no text for it"
        missing=$((missing + 1))
    fi
done
if [ -z "$wrapper_tags" ]; then
    bad "no tags were found in bin/onedrive-sync; the pattern or the wrapper moved"
fi

# ------------------------------------------------- the run result line
# The wrapper states each run's outcome on one machine-readable line and the tray
# and the doctor read it. The field names are a contract between files written in
# different languages, and nothing else keeps them spelled the same way: a rename
# in one file leaves the readers silently falling back to the prose scan, which is
# exactly what the line exists to replace.
title "the run result line"
check "the wrapper writes it" \
    grep -q 'ONEDRIVE_RESULT v=1 state=' bin/onedrive-sync
# The format string itself, not the file around it: `tag=` and `when=` also stand
# in a docstring and in a "{when}" format call, so a search over the whole file
# reported a renamed field as parsed. Renaming `tag` to `kind` in RESULT_RE left
# this suite green while the tray stopped matching any marker at all.
tray_re="$(sed -n '/^RESULT_RE = re.compile($/,/^$/p' bin/onedrive-tray |
    tr -d ' \\\n')"
for field in state tag when msg; do
    check "the tray parses the $field field" grep -q "$field=" <<<"$tray_re"
done
check "the doctor reads the same line" grep -q 'ONEDRIVE_RESULT' bin/onedrive-doctor
# And requires the same four fields of it, in its own copy of the pattern.
doctor_re="$(grep 'ONEDRIVE_RESULT v=1 state=' bin/onedrive-doctor)"
for field in tag when msg; do
    check "the doctor requires the $field field" grep -q "$field=" <<<"$doctor_re"
done
check "and the tray accepts the version the wrapper writes" \
    grep -qF 'ONEDRIVE_RESULT v=\d+' bin/onedrive-tray

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
# setup.sh writes the value through config_quote/carry now, so the string it falls
# back to lives in DEFAULT_BISYNC_ARGS. Reading that constant is what this checks:
# the line it writes is not a literal any more.
wizard_args="$(sed -n 's/^DEFAULT_BISYNC_ARGS="\([^"]*\)"$/\1/p' setup.sh |
    tail -1)"
if [ -z "$wrapper_args" ] || [ -z "$example_args" ] || [ -z "$wizard_args" ]; then
    bad "could not read the flag string out of one of the three files"
else
    check "config.example carries the wrapper's default" \
        test "$example_args" = "$wrapper_args"
    check "setup.sh writes the wrapper's default too" \
        test "$wizard_args" = "$wrapper_args"
    # The READMEs carried a fourth copy of that string, one flag short, and
    # nothing read them. Any BISYNC_ARGS= sample a README shows has to be the
    # wrapper's default, or the live progress line the README promises stops
    # working for a config copied out of it.
    #
    # The sample is matched at any indentation, and a README that shows a config
    # but no BISYNC_ARGS line is a failure rather than a skip: indenting the line
    # used to take the sample out of the grep's sight, and the skip then hid the
    # lost check behind a passing count.
    for f in README.md README.zh-CN.md; do
        [ -f "$f" ] || continue
        samples="$(grep -E '^[[:space:]]*BISYNC_ARGS="' "$f")"
        if [ -z "$samples" ]; then
            if [ "$(grep -cE '^[[:space:]]*(REMOTE|LOCAL)="' "$f")" -gt 0 ]; then
                bad "$f shows a config sample but no BISYNC_ARGS line"
            else
                skip "$f carries no config sample"
            fi
            continue
        fi
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            sample="$(sed -n 's/^[[:space:]]*BISYNC_ARGS="\(.*\)"$/\1/p' <<<"$line")"
            check "$f quotes the wrapper's default BISYNC_ARGS" \
                test "$sample" = "$wrapper_args"
        done <<<"$samples"
    done
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

# ------------------------------------------------- the rules written twice
# Three more pieces of knowledge live in two files with nothing keeping them
# equal, and each has drifted or nearly so: the listing slug decides whether the
# doctor finds the baseline the wrapper wrote, the positive-integer key list
# decides which config values the doctor judges, and KNOWN_KEYS decides which keys
# the doctor calls unread. A drifted copy is silent until a user hits it.
title "the rules two files are supposed to share"
lists_agree() {  # lists_agree <label> <the lines only one side has>
    if [ -z "$2" ]; then
        ok "$1"
    else
        bad "$1"
        printf '%s\n' "$2" | sed 's/^/        /'
    fi
}
slug_of() {  # slug_of <file> -- the sed rule that turns a path into rclone's slug
    grep -oE "sed -e 's\|\^/\|\|' -e 's\|\[/: \]\|_\|g'" "$1" | head -1
}
if [ -z "$(slug_of bin/onedrive-sync)" ]; then
    bad "no listing-slug rule was found in bin/onedrive-sync"
else
    check "the doctor looks for the listing the wrapper writes" \
        test "$(slug_of bin/onedrive-sync)" = "$(slug_of bin/onedrive-doctor)"
fi

wrapper_ints="$(grep -oE '^require_positive_int [A-Z_]+' bin/onedrive-sync |
    sed 's/^require_positive_int //' | sort)"
doctor_ints="$(sed -n 's/^    for key in \(.*\); do$/\1/p' bin/onedrive-doctor |
    tr ' ' '\n' | sort -u)"
if [ -z "$wrapper_ints" ] || [ -z "$doctor_ints" ]; then
    bad "could not read the positive-integer key list out of one of the two files"
else
    lists_agree "the doctor judges the keys the wrapper refuses" \
        "$(comm -3 <(printf '%s\n' "$wrapper_ints") <(printf '%s\n' "$doctor_ints"))"
fi

known_keys="$(sed -n '/^KNOWN_KEYS="/,/"/p' bin/onedrive-doctor | tr -s ' \n' ' ' |
    sed -e 's/^KNOWN_KEYS="//' -e 's/" *$//' | tr ' ' '\n' |
    grep -E '^[A-Z_]+$' | sort)"
example_keys="$(grep -oE '^[A-Z_]+=' config/config.example | tr -d '=' | sort)"
if [ -z "$known_keys" ] || [ -z "$example_keys" ]; then
    bad "could not read the key list out of bin/onedrive-doctor or config/config.example"
else
    lists_agree "every key in config.example is one the doctor knows" \
        "$(comm -13 <(printf '%s\n' "$known_keys") <(printf '%s\n' "$example_keys"))"
    lists_agree "and every key the doctor knows is in config.example" \
        "$(comm -23 <(printf '%s\n' "$known_keys") <(printf '%s\n' "$example_keys"))"
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

# ------------------------------------------------- the installed scripts the docs list
# The update page compares the installed scripts against the checkout, and its
# loop stopped at five of the six install.sh ships, so a stale onedrive-doctor
# printed "same" with the rest. Both directions are checked: every script
# install.sh installs appears in that loop, and every name in the loop is one
# install.sh installs. It covers that one loop, not every prose list of scripts.
title "the installed script list in the docs"
installed_bins="$(grep -oE 'bin/onedrive-[a-z-]+"' install.sh | sed 's|^bin/||; s|"$||' | sort -u)"
listed_bins="$(sed -n 's/^for s in \(.*\); do$/\1/p' docs/UPDATING.md | tr ' ' '\n' | sort -u)"
if [ -z "$installed_bins" ] || [ -z "$listed_bins" ]; then
    bad "could not read the script list out of install.sh or docs/UPDATING.md"
else
    list_has() { grep -qxF -- "$2" <<<"$1"; }
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        check "docs/UPDATING.md compares $name" list_has "$listed_bins" "$name"
    done <<<"$installed_bins"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        check "docs/UPDATING.md's $name is one install.sh installs" \
            list_has "$installed_bins" "$name"
    done <<<"$listed_bins"
fi

# ------------------------------------------------- one entry per thing
# The two ledgers are meant to hold each thing once. docs/KNOWN-ISSUES.md had two
# "Smaller, and real" sections with three bullets in both, and two of those
# bullets described things that had since been fixed, which is the drift this
# catches: nothing here can tell whether an entry is still true, but it can tell
# whether the file says the same thing twice. A duplicated `##` section and a
# duplicate bullet outside the "## Open" range were both missed, so the whole
# file is compared now. CHANGELOG.md had two `### Added`
# and two `### Fixed` under one release, where the format allows one of each, so
# its headings are compared inside a release rather than across the file.
title "one entry per thing"
no_repeats() {  # no_repeats <label> <the repeated lines, if any>
    if [ -z "$2" ]; then
        ok "$1"
    else
        bad "$1"
        printf '%s\n' "$2" | sed 's/^/        /'
    fi
}
no_repeats "docs/KNOWN-ISSUES.md repeats no top-level heading" \
    "$(grep '^## ' docs/KNOWN-ISSUES.md | sort | uniq -d)"
no_repeats "docs/KNOWN-ISSUES.md repeats no sub-heading" \
    "$(grep '^### ' docs/KNOWN-ISSUES.md | sort | uniq -d)"
# Every bullet in the file is compared, not only the ones under "## Open", so a
# duplicate in another section is caught too. Only the opening line of each
# bullet is compared, so a bullet repeated with a changed second line still
# gets through. That is the shape the duplicate took.
no_repeats "docs/KNOWN-ISSUES.md repeats no bullet" \
    "$(grep '^- ' docs/KNOWN-ISSUES.md | sort | uniq -d)"
no_repeats "CHANGELOG.md repeats no heading inside one release" \
    "$(awk '/^## \[/{section = $0; next} /^### /{print section " | " $0}' CHANGELOG.md |
        sort | uniq -d)"

summary
