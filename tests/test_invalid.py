"""
tests/test_invalid.py — Verify that invalid Pak programs fail with the expected error codes.

Each .pk64 file in tests/invalid/ must contain a comment of the form:
    -- EXPECT: EXXX
where EXXX is the error code the compiler should emit.

The test runner verifies:
1. `pak check <file>` exits non-zero (compilation failed).
2. The expected error code appears in stderr output.
"""

import subprocess
import re
from pathlib import Path
import pytest

# Drives the installed `pak` CLI; skipped cleanly if it is not on PATH.
pytestmark = pytest.mark.requires_pak

INVALID_DIR = Path(__file__).parent / "invalid"
EXPECT_RE = re.compile(r"--\s*EXPECT:\s*(E\d+)")


def _pak_files():
    """Collect all .pk64 files from tests/invalid/ with their expected error code."""
    files = []
    for pak_file in sorted(INVALID_DIR.glob("*.pk64")):
        source = pak_file.read_text(encoding="utf-8")
        m = EXPECT_RE.search(source)
        if m:
            files.append(pytest.param(pak_file, m.group(1), id=pak_file.name))
    return files


@pytest.mark.parametrize("pak_file,expected_code", _pak_files())
def test_invalid_file_fails_with_expected_code(pak_file, expected_code):
    """Each tests/invalid/*.pk64 must fail and emit the annotated error code."""
    result = subprocess.run(
        ["pak", "check", str(pak_file)],
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0, (
        f"{pak_file.name}: expected compiler to fail with {expected_code}, "
        f"but it exited 0 (no error)"
    )

    combined = result.stdout + result.stderr
    assert expected_code in combined, (
        f"{pak_file.name}: expected error code {expected_code} in output, "
        f"but got:\n{combined.strip()[:400]}"
    )
