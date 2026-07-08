"""Display-channel protocol between the helpers and Nova's TUI.

Nova's bash tool routes any stdout between the sentinel lines below to the
human display channel (rendered as a diff: ``+`` green, ``-`` red) and strips
it from the model-facing observation. The sentinels use ``\\x1e`` (ASCII
record separator) so real command output cannot collide with them.
"""

import sys

_BEGIN = "\x1enova:diff"
_END = "\x1enova:end"


def _raw_stdout():
    """stdout with newline translation off, so Windows never turns the
    sentinel protocol's ``\\n`` into ``\\r\\n``."""
    try:
        sys.stdout.reconfigure(newline="\n")
    except (AttributeError, ValueError):
        pass
    return sys.stdout


def emit_diff(text):
    """Write ``text`` to the display channel as a diff block."""
    out = _raw_stdout()
    out.write(_BEGIN + "\n")
    out.write(text)
    if not text.endswith("\n"):
        out.write("\n")
    out.write(_END + "\n")
    out.flush()
