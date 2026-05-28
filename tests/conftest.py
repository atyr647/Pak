"""Shared pytest configuration for the Pak test suite.

Several test modules drive the compiler through its installed `pak` CLI
(``subprocess.run(["pak", ...])``). When the package has not been installed
(``pip install -e .``) the binary is missing, and every one of those tests
fails with an opaque FileNotFoundError — historically ~126 cryptic failures
that obscured the real cause (a setup gap, not a code regression).

To keep that signal clear, modules that need the CLI mark themselves with
``pytestmark = pytest.mark.requires_pak``. When `pak` is not on PATH those
tests are skipped with a single actionable reason instead of failing en masse.

This does NOT mask CI regressions: the CI workflow installs the package and
has a dedicated ``pak --version`` step, so in CI the binary is always present
and these tests run for real. The skip only engages in a local environment
that hasn't installed the compiler yet.
"""

import shutil

import pytest

PAK_AVAILABLE = shutil.which("pak") is not None


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "requires_pak: test drives the installed `pak` CLI; skipped if it is "
        "not on PATH (run `pip install -e .` to enable).",
    )


def pytest_collection_modifyitems(config, items):
    if PAK_AVAILABLE:
        return
    skip_pak = pytest.mark.skip(
        reason="`pak` CLI not found on PATH — install the compiler with "
        "`pip install -e .` to run CLI-backed tests."
    )
    for item in items:
        if "requires_pak" in item.keywords:
            item.add_marker(skip_pak)
