"""
tests/test_integration_fixed_list.py
Integration test for FixedList container operations.

Pipeline:
  1. Run `pak explain tests/test_fixed_list_integration.pk64` to get C output.
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

PAK_FILE = Path(__file__).parent / "test_fixed_list_integration.pk64"

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
    # Pattern: snprintf(_pak_fmt_N, 256, "RESULT_X=...", ...)
    #  → snprintf(_pak_fmt_N, 256, "RESULT_X=...\n", ...)
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

class TestFixedListIntegration:

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

    def test_pak_explain_produces_fixedlist_typedef(self):
        """pak explain must emit the FixedList(i32, 64) typedef."""
        c_src = _get_c_output(PAK_FILE)
        assert "_PakList_int32_t_64" in c_src, (
            "Expected _PakList_int32_t_64 typedef in generated C"
        )

    def test_pak_explain_has_main(self):
        """pak explain must produce a main() function."""
        c_src = _get_c_output(PAK_FILE)
        assert "int main(" in c_src

    def test_empty_at_start(self, results):
        """FixedList.is_empty() returns true (1) for a freshly initialized list."""
        assert results["EMPTY"] == 1

    def test_len_after_push_ten_items(self, results):
        """After pushing 10 items, len() must return 10."""
        assert results["LEN"] == 10

    def test_sum_via_for_range_loop(self, results):
        """
        Iterating 0..10 and summing k*3 must produce 135.

        This validates the `for k in 0..n` loop generates correct C and that
        n is read from the FixedList's .len field.
        """
        assert results["SUM"] == 135, f"Expected 135 (sum 0+3+...+27), got {results.get('SUM')}"

    def test_not_empty_after_push(self, results):
        """is_empty() returns false (0) after items have been pushed."""
        assert results["NOT_EMPTY"] == 0

    def test_pop_returns_last_pushed_value(self, results):
        """pop() must return the most-recently pushed value (9*3 = 27)."""
        assert results["POP"] == 27

    def test_len_decrements_after_pop(self, results):
        """After popping one item from a 10-item list, len() must be 9."""
        assert results["LEN_AFTER_POP"] == 9

    def test_remove_decrements_len(self, results):
        """After remove(0) on a 9-item list, len() must be 8."""
        assert results["AFTER_REMOVE"] == 8

    def test_boundary_push_to_full_list(self, results):
        """
        Pushing past the capacity limit (64) must NOT increase len beyond 64.

        This verifies the FixedList capacity guard (`len < N` check in the
        generated push macro).
        """
        assert results["PUSH_FULL"] == 64, (
            f"Expected len to stay at 64 (capacity), got {results.get('PUSH_FULL')}"
        )
