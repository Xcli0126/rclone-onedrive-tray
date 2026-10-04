#!/usr/bin/env bash
#
# What the shell scripts that cannot source the config share: one implementation
# of the file's format. install.sh, uninstall.sh and setup.sh read the config with
# it, and none of them defines its own copy any more.
#
# Four readers of this file are left, and the reasons differ. The tray parses it in
# Python (`load_config`), because a config it did not write should not run.
# `onedrive-sync` and `onedrive-doctor` source it with `.`, because the shipped
# example writes values like `${XDG_CACHE_HOME:-$HOME/.cache}/...` that only a
# shell expands. This is the third, for the scripts that may not execute a config
# they are about to replace or remove: install.sh runs before the config is
# trusted, uninstall.sh runs while it is being removed, and setup.sh reads the
# snapshot it took before its own heredoc truncated the file. setup.sh carried a
# fourth copy until it was pointed at this one; that copy stripped at the first
# inner quote and at any `#`, the two bugs this reader had already lost, so a
# re-run of the wizard wrote a truncated path where the running install used the
# whole one.
#
# Everything here is a function definition and nothing runs on source, so a
# `set -euo pipefail` caller keeps its own options.
#
# What this reader does NOT do is expand `${VAR}`: it answers the value as written.
# The scripts here read a binary name, a unit name, a number and a boolean, and
# none of those is a path a person writes with a variable in it. `onedrive-sync`
# sources the file and the tray expands the same forms, so a *path* key is still
# expanded everywhere it is used.
#
# The tray writes a value with \, ", $ and the backtick escaped inside the quotes
# (shell_quote_value), and the sed below undoes exactly that, left to right, which
# handles a backslash before a quote the way the shell does. install.sh and
# uninstall.sh once had a copy each of this function, and the copies are how they
# drifted apart before: the old one took everything up to the FIRST inner quote, so
# a value the tray wrote came back truncated with nothing said. That is the entry in
# docs/KNOWN-ISSUES.md about the parsers of one file format.

config_value_from() {  # config_value_from <text> <KEY> -> the value, or "" when absent
    local text="$1" key="$2" line value
    line="$(printf '%s\n' "$text" |
        sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}${key}=//p" | tail -1)"
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

# The file, read into a shell variable first: setup.sh hands over a snapshot it
# took before its heredoc truncated the file, and that snapshot has to go through
# the same parsing as a file read here. One implementation, three callers.
config_value() {  # config_value <KEY> [<file>] -> the value, or "" when absent
    local key="$1" file="${2:-$CONFIG_DIR/config}"
    config_value_from "$(cat "$file" 2>/dev/null || true)" "$key"
}
