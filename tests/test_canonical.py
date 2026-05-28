"""
tests/test_canonical.py — Regression tests verifying all canonical examples pass pak check.

Each file in examples/canonical/ is a reference example that must:
  1. Parse without errors.
  2. Pass the typechecker and semantic checker (pak check exits 0).

If any canonical example breaks, it means a compiler change introduced a
regression or the example itself was edited incorrectly.
"""

import subprocess
from pathlib import Path
import pytest

# Drives the installed `pak` CLI; skipped cleanly if it is not on PATH.
pytestmark = pytest.mark.requires_pak

CANONICAL_DIR = Path(__file__).parent.parent / "examples" / "canonical"


def _canonical_files():
    """Collect all .pak files from examples/canonical/."""
    return [
        pytest.param(f, id=f.name)
        for f in sorted(CANONICAL_DIR.glob("*.pak"))
    ]


@pytest.mark.parametrize("pak_file", _canonical_files())
def test_canonical_example_passes(pak_file):
    """Every file in examples/canonical/ must pass `pak check` cleanly."""
    result = subprocess.run(
        ["pak", "check", str(pak_file)],
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, (
        f"{pak_file.name} failed pak check:\n"
        f"{(result.stderr + result.stdout).strip()}"
    )
