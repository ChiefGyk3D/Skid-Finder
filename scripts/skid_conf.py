"""Read KEY=value settings from config/interfaces.conf without executing it.

The shell side of the toolkit parses that file through lib.sh's
load_conf_file, which treats it as data (never 'source'd, since most scripts
run as root). The Python tools need the same keys with the same rules, so
the reader lives here once: a quoted value keeps its contents and drops
whatever follows the closing quote; an unquoted value is cut at the first
'#'. Only the keys a caller asks for are returned.
"""

import os
import re

QUOTED_RE = re.compile(r"""^"([^"]*)"|^'([^']*)'""")


def root_dir() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def conf_path() -> str:
    return os.path.join(root_dir(), "config", "interfaces.conf")


def read_conf(keys, path=None):
    """Return {KEY: value} for the requested keys present in the file."""
    wanted = set(keys)
    found = {}
    try:
        with open(path or conf_path(), encoding="utf-8") as handle:
            for raw in handle:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                key, sep, value = line.partition("=")
                key = key.strip()
                if not sep or key not in wanted:
                    continue
                value = value.strip()
                quoted = QUOTED_RE.match(value)
                if quoted:
                    value = quoted.group(1) or quoted.group(2) or ""
                else:
                    value = value.split("#", 1)[0].strip()
                found[key] = value
    except OSError:
        pass
    return found


def setting(name, conf, default=""):
    """Precedence: environment, then the config file, then the default."""
    value = os.environ.get(name)
    if value is None or value == "":
        value = conf.get(name, "")
    return value if value != "" else default


def version() -> str:
    try:
        with open(os.path.join(root_dir(), "VERSION"), encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return "unknown"
