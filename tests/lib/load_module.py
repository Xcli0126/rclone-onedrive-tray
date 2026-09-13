#!/usr/bin/env python3
"""Load a script as a module and report how it went.

The tray is a script, not an importable module, but loading it is enough to
exercise its dependency guards without a display: a missing binding makes it
call SystemExit during import. Prints LOADED when the module got that far.
"""
import importlib.machinery
import importlib.util
import sys

# Loading a script from bin/ would otherwise drop a __pycache__ directory into
# the source tree. Tests should not leave anything behind.
sys.dont_write_bytecode = True

if len(sys.argv) != 2:
    print("usage: load_module.py PATH", file=sys.stderr)
    raise SystemExit(2)

loader = importlib.machinery.SourceFileLoader("candidate", sys.argv[1])
spec = importlib.util.spec_from_loader("candidate", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)          # SystemExit from the guards propagates
print("LOADED")
