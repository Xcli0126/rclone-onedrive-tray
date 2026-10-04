#!/usr/bin/env bash
#
# What the two installers share: one implementation of the config file's format.
# install.sh and uninstall.sh both read the config with it, and neither defines its
# own copy.
#
# There are three readers of this file, not four any more. The tray parses it in
# Python (`load_config`), onedrive-sync sources it with `.`, because the shipped
# example writes values like `${XDG_CACHE_HOME:-$HOME/.cache}/...` that only a
# shell can expand, and this is the third, for the two shell scripts that cannot
# source it: install.sh runs before the config is trusted and uninstall.sh runs
# while it is being removed, and sourcing an arbitrary file in either place would
# execute whatever is in it.
#
# Everything here is a function definition and nothing runs on source, so a
# `set -euo pipefail` caller keeps its own options.
#
# What this reader does NOT do is expand `${VAR}`: it answers the value as written.
# The two installers read a binary name, a unit name, a number and a boolean, and
# none of those is a path a person writes with a variable in it. `onedrive-sync`
# sources the file and the tray expands the same forms, so a *path* key is still
# expanded everywhere it is used.
#
# The tray writes a value with \, ", $ and the backtick escaped inside the quotes
# (shell_quote_value), and the sed below undoes exactly that, left to right, which
# handles a backslash before a quote the way the shell does. Both installers once
# had their own copy of this function, and the copies are how they drifted apart
# before: the old one took everything up to the FIRST inner quote, so a value the
# tray wrote came back truncated with nothing said. That is the entry in
# docs/KNOWN-ISSUES.md about the parsers of one file format.

config_value() {  # config_value <KEY> [<file>] -> the value, or "" when absent
    local key="$1" file="${2:-$CONFIG_DIR/config}" line value
    line="$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}${key}=//p" \
        "$file" 2>/dev/null | tail -1)"
    [ -n "$line" ] || return 0
    case "$line" in
        \"*)
            value="$(printf '%s\n' "$line" |
                sed -n 's/^"\(.*\)"[[:space:]]*\(#.*\)\{0,1\}$/\1/p')"
            # The writer escapes exactly these four; undo them left to right, which
            # handles a backslash before a quote the way the shell does.
            printf '%s' "$value" | sed -e 's/\\\(["\\$`]\)/\1/g' ;;
        *)
            # Unquoted: a `#` that whitespace precedes starts a comment and the
            # value ends at the first space; the old form stripped from the first
            # `#` whatever stood before it, so `KEY=abc#def` came back as `abc`
            # where bash says `abc#def`.
            printf '%s\n' "$line" |
                sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]].*$//' | tr -d '\n' ;;
    esac
}
