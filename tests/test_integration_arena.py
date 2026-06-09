"""
tests/test_integration_arena.py
Integration test for the Arena bump allocator.

Pipeline:
  1. Run `pak explain tests/test_arena_integration.pk64` to get C output.
  2. Patch the C to compile on a host (strip libdragon headers, replace debugf).
  3. Compile with gcc (-std=gnu11).
  4. Run the binary and parse RESULT_* lines from stdout.
  5. Assert correctness of each result.
"""

import re
import subprocess
import tempfile
from pathlib import Path

import pytest

pytestmark = pytest.mark.requires_pak

PAK_FILE = Path(__file__).parent / "test_arena_integration.pk64"

# Standard C headers that replace the N64-specific libdragon headers
_HOST_HEADERS = """\
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
"""


def _get_c_output(pak_file: Path) -> str:
    """Run `pak explain <file>` and return the generated C source."""
    result = subprocess.run(
        ["pak", "explain", str(pak_file)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"pak explain failed:\n{(result.stderr + result.stdout).strip()}"
    )
    return result.stdout


def _patch_c_for_host(c_src: str) -> str:
    """
    Adapt Pak-generated C to compile on a POSIX host with gcc.

    Changes:
    - Replace `#include <libdragon.h>` with POSIX standard headers.
    - Strip all remaining N64-specific and pak-internal includes.
    - Deduplicate standard headers.
    - Remove the N64 timer-delta helper (uses TICKS_READ which is N64-only).
    - Replace `debugf(snprintf_expr)` with `printf(snprintf_expr)` and add
      a newline to each format string so each RESULT line is terminated.
    """
    # Swap libdragon.h for host headers
    c_src = c_src.replace("#include <libdragon.h>", _HOST_HEADERS)

    # Remove pak-internal includes
    c_src = re.sub(r'#include\s+"pak_\w+\.h"\s*\n', "", c_src)

    # Remove all non-standard angle-bracket includes (N64 module headers)
    _STANDARD_HDRS = frozenset([
        "<stdio.h>", "<stdint.h>", "<stdbool.h>",
        "<string.h>", "<math.h>", "<stdlib.h>",
    ])
    c_src = re.sub(
        r"#include\s+(<[^>]+>)\s*\n",
        lambda m: m.group(0) if m.group(1) in _STANDARD_HDRS else "",
        c_src,
    )

    # Deduplicate standard headers (keep first occurrence only)
    seen: set = set()
    deduped_lines = []
    for line in c_src.splitlines(keepends=True):
        m = re.match(r"(#include\s+<[^>]+>)", line)
        if m:
            hdr = m.group(1)
            if hdr in seen:
                continue
            seen.add(hdr)
        deduped_lines.append(line)
    c_src = "".join(deduped_lines)

    # Remove the N64 timer-delta helper block
    c_src = re.sub(
        r"static uint32_t _pak_last_tick.*?_pak_last_tick = now;\s*return dt;\s*\}\s*",
        "",
        c_src,
        flags=re.DOTALL,
    )

    # Replace debugf( with printf(
    c_src = c_src.replace("debugf(", "printf(")

    # Insert \n into each snprintf format string so output lines are terminated.
    c_src = re.sub(
        r'snprintf\((_pak_fmt_\d+),\s*256,\s*("RESULT_[^"]+)"',
        lambda m: f'snprintf({m.group(1)}, 256, {m.group(2)}\\n"',
        c_src,
    )

    return c_src


def _compile_and_run(c_src: str) -> str:
    """Write C to a temp file, compile with gcc, run, return stdout."""
    with tempfile.TemporaryDirectory() as tmpdir:
        src_path = Path(tmpdir) / "test.c"
        bin_path = Path(tmpdir) / "test_bin"
        src_path.write_text(c_src)

        compile_result = subprocess.run(
            ["gcc", "-std=gnu11", "-o", str(bin_path), str(src_path)],
            capture_output=True,
            text=True,
        )
        assert compile_result.returncode == 0, (
            f"gcc compilation failed:\n{compile_result.stderr}"
        )

        run_result = subprocess.run(
            [str(bin_path)],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert run_result.returncode == 0, (
            f"binary exited with {run_result.returncode}:\n{run_result.stderr}"
        )
        return run_result.stdout


def _parse_results(output: str) -> dict:
    """Parse RESULT_KEY=VALUE lines from program output into a dict."""
    results: dict = {}
    for line in output.splitlines():
        m = re.match(r"RESULT_(\w+)=(-?\d+)", line.strip())
        if m:
            results[m.group(1)] = int(m.group(2))
    return results


# ─────────────────────────────────────────────────────────────────────────────
# Shared fixture — run the full pipeline once per test session
# ─────────────────────────────────────────────────────────────────────────────

@pytest.fixture(scope="module")
def results():
    """Run pak explain → patch → compile → run; return parsed results dict."""
    c_src = _get_c_output(PAK_FILE)
    patched = _patch_c_for_host(c_src)
    output = _compile_and_run(patched)
    return _parse_results(output)


# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

class TestArenaIntegration:

    def test_pak_file_passes_check(self):
        """The Pak source must pass `pak check` cleanly."""
        result = subprocess.run(
            ["pak", "check", str(PAK_FILE)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"pak check failed:\n{(result.stderr + result.stdout).strip()}"
        )

    def test_pak_explain_has_arena_alloc(self):
        """pak explain must emit pak_arena_alloc calls."""
        c_src = _get_c_output(PAK_FILE)
        assert "pak_arena_alloc" in c_src, (
            "Expected pak_arena_alloc in generated C"
        )

    def test_pak_explain_has_arena_reset(self):
        """pak explain must emit pak_arena_reset call."""
        c_src = _get_c_output(PAK_FILE)
        assert "pak_arena_reset" in c_src

    def test_first_alloc_succeeds(self, results):
        """arena.alloc() on a fresh arena must return a non-null pointer."""
        assert results["ALLOC1_OK"] == 1

    def test_second_alloc_succeeds(self, results):
        """A second arena.alloc() must also succeed (arena has enough space)."""
        assert results["ALLOC2_OK"] == 1

    def test_write_and_read_first_alloc(self, results):
        """Writing 42 to the first allocation and reading it back must succeed."""
        assert results["VAL1"] == 42

    def test_write_and_read_second_alloc(self, results):
        """Writing 99 to the second allocation must not overwrite the first."""
        assert results["VAL2"] == 99

    def test_alloc_after_reset_succeeds(self, results):
        """After arena.reset(), allocations must succeed again from the start."""
        assert results["ALLOC3_AFTER_RESET"] == 1

    def test_write_after_reset(self, results):
        """After reset, writing 77 to a new allocation must work correctly."""
        assert results["VAL3"] == 77

    def test_arena_fills_to_capacity(self, results):
        """
        After reset, a 256-byte arena with 8-byte alignment holds exactly 32
        four-byte allocations.  We already used 1 after reset, so filling 31
        more should all succeed.
        """
        assert results["FILL_COUNT"] == 31

    def test_oom_returns_none(self, results):
        """
        Allocating from a full arena must return none (NULL), not crash.

        This verifies the capacity guard in pak_arena_alloc:
          if (a->ptr + sz > a->base + a->capacity) return NULL;
        """
        assert results["OOM"] == 1, (
            "Expected allocation past capacity to return none (NULL)"
        )
