#!/usr/bin/env python3
"""Load a script as a module, and report how it went.

The tray is a script, not an importable module, but loading it is enough to
exercise its dependency guards without a display: a missing binding makes it call
SystemExit during import. Run as a program it prints LOADED when the module got
that far; the suites that need its functions import load() and report().
"""
import importlib.machinery
import importlib.util
import sys

# Loading a script from bin/ would otherwise drop a __pycache__ directory into
# the source tree. Tests should not leave anything behind, and a file that
# imports this one has to set the same flag first, before the import.
sys.dont_write_bytecode = True


def load(path, name="candidate"):
    """Return the module loaded from `path`. A guard's SystemExit propagates."""
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def report(problems):
    """Print one line per problem, then exit non-zero when there was one."""
    for problem in problems:
        print(problem)
    raise SystemExit(1 if problems else 0)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: load_module.py PATH", file=sys.stderr)
        raise SystemExit(2)
    load(sys.argv[1])
    print("LOADED")
