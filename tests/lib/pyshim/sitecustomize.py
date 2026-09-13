# Injected through PYTHONPATH to simulate a broken environment.
#
#   HIDE_MODULE=gi        make "import gi" fail, as if python3-gi were absent
#   HIDE_TYPELIB=Notify   make gi.require_version("Notify", ...) raise, as if
#                         the gir1.2-* package for it were absent. Accepts a
#                         comma-separated list, which is how the AppIndicator
#                         case is simulated: the tray falls back from Ayatana to
#                         AppIndicator3, so both have to be hidden at once.
#
# sitecustomize runs before the program does, which is the only way to make a
# typelib look missing without uninstalling it.
import os
import sys

_block = os.environ.get("HIDE_MODULE", "").strip()
if _block:
    class _Blocker:
        def find_spec(self, name, path=None, target=None):
            if name == _block or name.startswith(_block + "."):
                raise ImportError(f"No module named {name!r}")
            return None

    sys.meta_path.insert(0, _Blocker())

_hide = {n.strip() for n in os.environ.get("HIDE_TYPELIB", "").split(",") if n.strip()}
if _hide:
    import gi

    _real = gi.require_version

    def require_version(namespace, version):
        if namespace in _hide:
            raise ValueError(f"Namespace {namespace} not available")
        return _real(namespace, version)

    gi.require_version = require_version
