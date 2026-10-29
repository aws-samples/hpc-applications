"""Run the GROMACS shell suite from pytest.

apps/Gromacs/tests/run-tests.sh runs the CPU benchmark launchers
(x86/gromacs-benchmark.sbatch, Arm/gromacs-benchmark.sbatch) end to end with
stubbed Slurm, IMDS, MPI and GROMACS commands, so the assembled scripts really
execute, and checks every GROMACS script with `bash -n`. Unlike
test_gromacs_properties.py, which re-implements the shell logic in Python, this
runs the scripts themselves, so a single `pytest tests` covers them.

Run with:
    python -m pip install -r tests/requirements.txt
    python -m pytest tests/test_gromacs_launchers.py -q
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SHELL_SUITE = REPO / "apps" / "Gromacs" / "tests" / "run-tests.sh"

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")


def test_gromacs_shell_suite_passes():
    """apps/Gromacs/tests/run-tests.sh: every launcher test, and bash -n over the scripts."""
    result = subprocess.run(["bash", str(SHELL_SUITE)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout[-6000:] + result.stderr[-2000:]
