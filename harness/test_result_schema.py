"""
Property 12: result.json schema stability.

Validates Requirements 13.3, 13.4 (and, incidentally, 13.5/13.6).

This exercises the *real* harness end to end: it invokes ``test_kernel.py`` as a
subprocess (exactly as documented in ``example-assignment/README.md``), which in
turn writes ``result.json`` through ``result_writer.write_result``. Nothing here
reimplements the harness or the writer -- we only read back what they produce.

Both graded paths are exercised:

* FAIL path -- the shipped ``example-assignment`` whose ``student.py`` returns
  zeros, so correctness always fails.
* PASS path -- a copy of ``example-assignment`` in a temp dir whose ``student.py``
  equals the reference (``torch.mul(x, 2.0)``), so correctness always passes.

For each path we assert the stable ``result.json`` schema:

* ``schema_version == 1``
* the top-level ``correctness``, ``timing`` and ``environment`` keys are present
* ``correctness.passed`` is a boolean
* ``timing`` carries timing measurements iff ``correctness.passed`` is ``True``
  (Requirement 13.4 populates timing on pass; Requirement 13.5 leaves it
  present-but-without-measurements on fail)

The harness imports ``torch`` inside the reference/student modules, so these
tests skip when ``torch`` is not importable. The example-assignment uses plain
``torch.mul``, so a CPU torch build is sufficient -- no Neuron hardware required.
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HARNESS_DIR = Path(__file__).resolve().parent
TEST_KERNEL = HARNESS_DIR / "test_kernel.py"
EXAMPLE_ASSIGNMENT = HARNESS_DIR / "example-assignment"

# The measurement keys test_kernel.py adds to `timing` only on a passing run.
# Their presence is the observable signal that timing was "populated".
TIMING_MEASUREMENT_KEYS = (
    "student_ms_min",
    "student_ms_median",
    "reference_ms_min",
    "reference_ms_median",
)

# The harness subprocess (via reference.py / student.py) imports torch. Skip
# cleanly where it is unavailable rather than reporting a spurious failure.
pytestmark = pytest.mark.skipif(
    importlib.util.find_spec("torch") is None,
    reason="harness subprocess imports torch; install a CPU torch build to run",
)


def _run_harness(assignment_dir: Path, output_dir: Path) -> subprocess.CompletedProcess:
    """Run the real harness against ``assignment_dir`` and return the process.

    Uses the same interpreter running pytest so the child inherits this env's
    torch. Warmup/measured are kept small: the work is a trivial CPU multiply.
    """
    return subprocess.run(
        [
            sys.executable,
            str(TEST_KERNEL),
            "--assignment-dir",
            str(assignment_dir),
            "--output-dir",
            str(output_dir),
            "--warmup",
            "1",
            "--measured",
            "2",
        ],
        capture_output=True,
        text=True,
        cwd=str(HARNESS_DIR),
    )


def _load_result(output_dir: Path, proc: subprocess.CompletedProcess) -> dict:
    result_path = output_dir / "result.json"
    assert result_path.exists(), (
        f"harness wrote no result.json (returncode={proc.returncode})\n"
        f"--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}"
    )
    return json.loads(result_path.read_text())


def _timing_has_measurements(timing: dict) -> bool:
    return any(key in timing for key in TIMING_MEASUREMENT_KEYS)


def _assert_stable_schema(result: dict) -> None:
    """Assertions common to every result.json regardless of pass/fail."""
    assert result.get("schema_version") == 1, "schema_version must equal 1"
    for key in ("correctness", "timing", "environment"):
        assert key in result, f"missing required top-level key: {key!r}"
        assert isinstance(result[key], dict), f"{key!r} must be a JSON object"
    assert isinstance(
        result["correctness"].get("passed"), bool
    ), "correctness.passed must be a boolean"


def test_result_schema_failing_path(tmp_path):
    """The shipped zeros stub -> correctness FAIL, timing carries no measurements."""
    output_dir = tmp_path / "fail-out"
    proc = _run_harness(EXAMPLE_ASSIGNMENT, output_dir)
    result = _load_result(output_dir, proc)

    _assert_stable_schema(result)
    assert result["correctness"]["passed"] is False
    # Requirement 13.6: a graded correctness failure exits 1 (not a fatal 2).
    assert proc.returncode == 1, proc.stderr
    # Requirements 13.4/13.5: no timing measurements when correctness fails.
    assert not _timing_has_measurements(result["timing"])


def test_result_schema_passing_path(tmp_path):
    """A student equal to the reference -> correctness PASS, timing populated."""
    assignment = tmp_path / "passing-assignment"
    # Reuse the real reference.py / inputs.py / tolerance.json; only swap the
    # student stub for one whose output matches the reference exactly.
    shutil.copytree(EXAMPLE_ASSIGNMENT, assignment)
    (assignment / "student.py").write_text(
        "import torch\n\n\n"
        "def kernel(x: torch.Tensor) -> torch.Tensor:\n"
        "    return torch.mul(x, 2.0)\n"
    )

    output_dir = tmp_path / "pass-out"
    proc = _run_harness(assignment, output_dir)
    result = _load_result(output_dir, proc)

    _assert_stable_schema(result)
    assert result["correctness"]["passed"] is True, result["correctness"].get("notes")
    # Requirement 13.6: a passing correctness check exits 0.
    assert proc.returncode == 0, proc.stderr
    # Requirement 13.4: timing is populated with measurements on a pass.
    assert _timing_has_measurements(result["timing"])
    for key in TIMING_MEASUREMENT_KEYS:
        assert key in result["timing"], f"passing run missing timing key {key!r}"
        assert isinstance(result["timing"][key], (int, float))
