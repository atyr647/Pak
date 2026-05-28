"""Shared Pak code-unit extraction and failure classification.

Both prepare_data.py and expand_dataset.py gate their output on `pak check`.
This module is the single definition of *what* gets validated and *how* a
result is judged, so the two pipelines can never drift apart.
"""

import re

# A raw output is Pak source if its first non-comment line opens a declaration.
_PAK_DECL_STARTS = (
    "use ", "fn ", "struct ", "enum ", "impl ", "const ", "static ",
    "asset ", "extern ", "variant ", "union ", "trait ", "module ", "entry", "@",
)
_FENCE_RE = re.compile(r"```pak\n(.*?)```", re.S)


def _first_code_line(text: str) -> str:
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("--") or s.startswith("//"):
            continue
        return s
    return ""


def code_units(output: str, category: str):
    """Yield ``(code, kind)`` units to validate from one dataset output.

    ``kind`` is one of:
      ``program``        — raw complete program; must fully pass ``pak check``
      ``fragment``       — raw decls-only snippet; must pass except a lone E103
      ``fenced_program`` — complete program inside a ```pak block; must parse

    Negative examples and isolated fenced fragments (syntax pieces shown in
    docs, e.g. a bare ``fn`` signature or a ``match`` arm) are never yielded:
    they are illustrative and do not stand alone as files.
    """
    if category == "negative":
        return
    if "```" in output:
        for block in _FENCE_RE.findall(output):
            if "entry {" in block:
                yield block, "fenced_program"
        return
    if not _first_code_line(output).startswith(_PAK_DECL_STARTS):
        return
    yield output, ("program" if "entry {" in output else "fragment")


def unit_failure(kind: str, returncode: int, errtext: str):
    """Return an error string if a checked unit is a real failure, else None."""
    if returncode == 0:
        return None
    codes = re.findall(r"error\[(E\d+)\]", errtext)
    crashed = "Traceback (most recent call last)" in errtext

    if kind == "fragment":
        # A decls-only snippet legitimately lacks an entry block.
        if not crashed and codes and all(c == "E103" for c in codes):
            return None
        return errtext

    if kind == "fenced_program":
        # Illustrative skeletons may call helpers defined elsewhere, so only
        # syntax errors (and compiler crashes) count as failures here.
        if crashed or any(c in ("E001", "E002") for c in codes):
            return errtext
        return None

    # 'program' — a raw, self-contained program must be fully clean.
    return errtext
