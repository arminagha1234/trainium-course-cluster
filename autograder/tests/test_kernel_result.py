"""
test_kernel_result.py — turn the kit harness's result.json into a Gradescope
score.

By the time these tests run, ./run_autograder has submitted the grading job to
the shared PCS cluster and copied the harness output back to
/autograder/source/result.json. These tests only READ that file — they do no
grading logic of their own, so the pass/fail signal is exactly the kit harness's
(harness/test_kernel.py + harness/result_writer.py). That single-source-of-truth
reuse is the whole point of the PCS autograder.

result.json schema fields we rely on (see harness/result_writer.py):
  correctness.passed      bool  — the grade signal
  correctness.notes       str   — why it failed (surfaced to the student)
  correctness.max_abs_diff / shape_match / dtype_match — extra diagnostics
  timing.student_ms_median float — present ONLY when correctness passed

Grading breakdown:
  correctness   70 pts  (pass/fail)
  performance   30 pts  (partial credit vs PERF_THRESHOLD_MS, only if correct)
  leaderboard   median_ms, ascending (informational; only if correct)
"""

import json
import unittest

from gradescope_utils.autograder_utils.decorators import (
    weight,
    number,
    partial_credit,
    leaderboard,
    hide_errors,  # available for operators who prefer a terse failure message; see note below
)


# Where run_autograder lands the harness result (mirrors RESULT_LOCAL there).
RESULT_PATH = "/autograder/source/result.json"

# Operator-tunable performance target, in milliseconds of student median wall
# time. Full performance credit at student_ms_median <= T; linear down to zero
# at >= 2*T (see the formula in test_performance). Tune this per assignment /
# per instance shape — a trn2.3xlarge and a trn2.48xlarge will land different
# medians for the same kernel.
PERF_THRESHOLD_MS = 5.0

# `hide_errors` is imported (per the autograder template convention) so an
# operator can wrap any test whose raw traceback they would rather not show
# students. We instead wrap the fragile perf/leaderboard bodies in try/except
# below, which lets us surface a tailored message AND keep the run alive.


def _load_result():
    """Load result.json once. Returns (result_dict, error_message).

    Exactly one of the two is truthy: on success (result, None); on any
    problem (None, "<why>"). Kept defensive because a malformed or missing
    result.json must degrade to a clean FAIL, never an import-time crash.
    """
    try:
        with open(RESULT_PATH) as f:
            return json.load(f), None
    except FileNotFoundError:
        return None, ("no result.json at {} — the grading job did not return a "
                      "result (see the autograder log)".format(RESULT_PATH))
    except (json.JSONDecodeError, OSError) as e:
        return None, "could not read result.json: {}: {}".format(type(e).__name__, e)


# Loaded once at import; the tests below read these module globals.
RESULT, RESULT_ERROR = _load_result()


class KernelResultTest(unittest.TestCase):
    """Grade a submission from the harness result.json."""

    def _require_result(self):
        """Fail the current test cleanly if result.json never loaded."""
        if RESULT is None:
            self.fail(RESULT_ERROR or "result.json unavailable")
        return RESULT

    def _correctness(self):
        return (self._require_result().get("correctness") or {})

    def _passed(self):
        return self._correctness().get("passed") is True

    @weight(70)
    @number("1")
    def test_correctness(self):
        """70 pts: the on-device kernel output matched the TA reference within
        tolerance (harness correctness.passed)."""
        correctness = self._correctness()
        passed = correctness.get("passed") is True
        if not passed:
            # Surface the harness's own explanation plus a couple of diagnostics
            # so the student sees WHY, not just that it failed.
            notes = correctness.get("notes") or "(harness gave no notes)"
            detail = "correctness FAILED: {}".format(notes)
            if correctness.get("shape_match") is False:
                detail += " [shape mismatch]"
            if correctness.get("dtype_match") is False:
                detail += " [dtype mismatch]"
            if "max_abs_diff" in correctness:
                detail += " [max_abs_diff={}]".format(correctness.get("max_abs_diff"))
            self.fail(detail)
        # Passed — nothing to assert further; full weight is awarded.

    @partial_credit(30)
    @number("2")
    def test_performance(self, set_score=None):
        """30 pts (partial): scaled by how the student's median latency compares
        to PERF_THRESHOLD_MS. Only graded when correctness passes — timing an
        incorrect kernel is meaningless (and the harness omits timing then)."""
        try:
            if not self._passed():
                set_score(0)
                print("performance graded only when correctness passes; awarding 0/30")
                return

            timing = (self._require_result().get("timing") or {})
            x = timing.get("student_ms_median")
            if x is None:
                # Correct but no timing recorded (unexpected) — do not punish
                # beyond zero perf credit, and say so.
                set_score(0)
                print("correctness passed but no timing.student_ms_median was "
                      "recorded; awarding 0/30 performance")
                return

            x = float(x)
            # Guard against an operator setting a non-positive threshold.
            t = PERF_THRESHOLD_MS if PERF_THRESHOLD_MS > 0 else 1e-9
            # Full credit at x <= t; linear to 0 at x >= 2t; clamped to [0, 1].
            fraction = max(0.0, min(1.0, 1.0 - max(0.0, (x - t)) / t))
            score = 30.0 * fraction
            set_score(score)
            print("performance: student_ms_median={:.4f} ms, threshold={:.4f} ms "
                  "-> {:.2f}/30".format(x, t, score))
        except Exception as e:  # noqa: BLE001 - a perf hiccup must not crash grading
            # Any unexpected shape in the timing block: award zero perf rather
            # than failing the whole run, and leave a breadcrumb.
            try:
                set_score(0)
            except Exception:
                pass
            print("performance scoring error ({}: {}); awarding 0/30".format(type(e).__name__, e))

    @leaderboard("median_ms", sort_order="asc")
    def test_leaderboard(self, set_leaderboard_value=None):
        """Publish the student's median latency to an ascending leaderboard
        (lower is better). Informational only — no points. Skipped (None) unless
        the submission was correct."""
        try:
            if not self._passed():
                set_leaderboard_value(None)
                return
            timing = (RESULT.get("timing") or {}) if RESULT else {}
            median = timing.get("student_ms_median")
            set_leaderboard_value(float(median) if median is not None else None)
        except Exception as e:  # noqa: BLE001 - leaderboard is cosmetic; never crash the run
            try:
                set_leaderboard_value(None)
            except Exception:
                pass
            print("leaderboard error ({}: {}); skipping".format(type(e).__name__, e))
