#!/usr/bin/env python3
"""
Correctness + timing harness for a Trainium Course Cluster kernel assignment.

Contract (V0, keep simple):

  assignment_dir/
    reference.py        must expose `kernel(*args, **kwargs) -> Tensor`
    student.py          must expose `kernel(*args, **kwargs) -> Tensor`
    inputs.py           (optional) must expose `make_inputs() -> tuple[args, kwargs]`
    tolerance.json      (optional) {"rtol": 1e-3, "atol": 1e-5}; defaults below

Behaviour:
  1. Import reference + student modules from assignment_dir.
  2. Call inputs.make_inputs() (or use the default helper if inputs.py missing).
  3. Run reference.kernel and student.kernel on the same inputs; compare.
  4. Time both across N=5 warmup + N=10 measured runs (adjustable via env vars).
  5. Emit result.json to --output-dir via result_writer.write_result.

Exit codes:
  0  correctness pass
  1  correctness fail (shape/dtype mismatch or over-tolerance)
  2  fatal harness error (import failure, missing files, etc.)

The harness deliberately does NOT import torch or torch_neuronx at module
top-level - that way `python3 test_kernel.py --help` works on any machine.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import time
import traceback
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from result_writer import write_result, build_environment_dict  # noqa: E402


DEFAULT_TOLERANCE = {"rtol": 1e-3, "atol": 1e-5}
DEFAULT_WARMUP = int(os.environ.get("KERNEL_WARMUP", "5"))
DEFAULT_MEASURED = int(os.environ.get("KERNEL_MEASURED", "10"))


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {name} from {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def _default_inputs():
    """Fallback input generator: 128x128 fp32 tensor of ones.

    Used only when the assignment does not ship an inputs.py.
    """
    import torch  # local import so --help works without torch

    x = torch.ones(128, 128, dtype=torch.float32)
    return (x,), {}


def _time_calls(callable_, args, kwargs, warmup: int, measured: int) -> dict[str, float]:
    """Time `callable_(*args, **kwargs)` warmup + measured times.

    Returns min + median in milliseconds. Uses time.perf_counter for wall time;
    Neuron async execution means this includes the round trip, which is what
    students actually observe.
    """
    for _ in range(warmup):
        callable_(*args, **kwargs)

    times_ms: list[float] = []
    for _ in range(measured):
        t0 = time.perf_counter()
        callable_(*args, **kwargs)
        t1 = time.perf_counter()
        times_ms.append((t1 - t0) * 1000.0)
    times_ms.sort()
    return {
        "min": times_ms[0],
        "median": times_ms[len(times_ms) // 2],
        "all_ms": times_ms,
    }


def _compare_outputs(ref_out, stu_out, tol: dict) -> dict[str, Any]:
    """Compare student output to reference. Returns a correctness dict."""
    import torch

    correctness: dict[str, Any] = {
        "tolerance": tol,
        "shape_match": False,
        "dtype_match": False,
        "max_abs_diff": float("nan"),
        "max_rel_diff": float("nan"),
        "notes": "",
    }
    try:
        if not isinstance(stu_out, torch.Tensor):
            correctness["notes"] = f"student returned non-tensor: {type(stu_out).__name__}"
            correctness["passed"] = False
            return correctness

        correctness["shape_match"] = tuple(ref_out.shape) == tuple(stu_out.shape)
        correctness["dtype_match"] = ref_out.dtype == stu_out.dtype

        if not correctness["shape_match"]:
            correctness["notes"] = f"shape mismatch: ref={tuple(ref_out.shape)} student={tuple(stu_out.shape)}"
            correctness["passed"] = False
            return correctness

        # Cast to common dtype for numerical comparison so bf16 vs fp32 is
        # comparable. Report dtype_match separately so students see the type
        # gap even when values agree.
        ref_f = ref_out.detach().to(torch.float32).cpu()
        stu_f = stu_out.detach().to(torch.float32).cpu()

        diff = (ref_f - stu_f).abs()
        correctness["max_abs_diff"] = float(diff.max().item()) if diff.numel() else 0.0
        rel = diff / (ref_f.abs().clamp_min(1e-12))
        correctness["max_rel_diff"] = float(rel.max().item()) if rel.numel() else 0.0

        within = torch.allclose(ref_f, stu_f, rtol=tol["rtol"], atol=tol["atol"])
        correctness["passed"] = bool(within)
        if not within:
            correctness["notes"] = (
                f"tolerance violated: max_abs_diff={correctness['max_abs_diff']:.3e} "
                f"rtol={tol['rtol']} atol={tol['atol']}"
            )
    except Exception as e:  # noqa: BLE001 - report anything and continue
        correctness["passed"] = False
        correctness["notes"] = f"comparison raised {type(e).__name__}: {e}"
    return correctness


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--assignment-dir", required=True, help="Directory with reference.py + student.py")
    ap.add_argument("--output-dir", required=True, help="Where to write result.json")
    ap.add_argument("--warmup", type=int, default=DEFAULT_WARMUP)
    ap.add_argument("--measured", type=int, default=DEFAULT_MEASURED)
    args = ap.parse_args()

    assignment_dir = Path(args.assignment_dir).resolve()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    assignment_name = assignment_dir.name

    # Load tolerance override, fall back to defaults.
    tol_path = assignment_dir / "tolerance.json"
    if tol_path.exists():
        try:
            tol = {**DEFAULT_TOLERANCE, **json.loads(tol_path.read_text())}
        except json.JSONDecodeError as e:
            print(f"tolerance.json invalid: {e}", file=sys.stderr)
            tol = DEFAULT_TOLERANCE
    else:
        tol = DEFAULT_TOLERANCE

    # Load modules
    try:
        ref_mod = _load_module("reference_mod", assignment_dir / "reference.py")
        stu_mod = _load_module("student_mod", assignment_dir / "student.py")
    except Exception as e:
        traceback.print_exc()
        write_result(output_dir, {
            "assignment": assignment_name,
            "correctness": {"passed": False, "notes": f"module load failure: {type(e).__name__}: {e}"},
            "environment": build_environment_dict(),
        })
        return 2

    if not hasattr(ref_mod, "kernel") or not hasattr(stu_mod, "kernel"):
        write_result(output_dir, {
            "assignment": assignment_name,
            "correctness": {"passed": False, "notes": "reference.py and student.py must each define `kernel(...)`"},
            "environment": build_environment_dict(),
        })
        return 2

    # Inputs
    if (assignment_dir / "inputs.py").exists():
        try:
            inp_mod = _load_module("inputs_mod", assignment_dir / "inputs.py")
            _args, _kwargs = inp_mod.make_inputs()
        except Exception as e:
            traceback.print_exc()
            write_result(output_dir, {
                "assignment": assignment_name,
                "correctness": {"passed": False, "notes": f"inputs.make_inputs raised: {e}"},
                "environment": build_environment_dict(),
            })
            return 2
    else:
        _args, _kwargs = _default_inputs()

    # Run once for correctness
    try:
        ref_out = ref_mod.kernel(*_args, **_kwargs)
    except Exception as e:
        traceback.print_exc()
        write_result(output_dir, {
            "assignment": assignment_name,
            "correctness": {"passed": False, "notes": f"reference kernel raised: {e}"},
            "environment": build_environment_dict(),
        })
        return 2

    try:
        stu_out = stu_mod.kernel(*_args, **_kwargs)
    except Exception as e:
        traceback.print_exc()
        write_result(output_dir, {
            "assignment": assignment_name,
            "correctness": {"passed": False, "notes": f"student kernel raised: {e}"},
            "environment": build_environment_dict(),
        })
        return 1

    correctness = _compare_outputs(ref_out, stu_out, tol)

    # Timing (only if correctness passed; timing an incorrect kernel is a footgun)
    timing: dict[str, Any] = {"warmup_runs": args.warmup, "measured_runs": args.measured}
    if correctness.get("passed"):
        try:
            stu_t = _time_calls(stu_mod.kernel, _args, _kwargs, args.warmup, args.measured)
            ref_t = _time_calls(ref_mod.kernel, _args, _kwargs, args.warmup, args.measured)
            timing.update({
                "student_ms_min": stu_t["min"],
                "student_ms_median": stu_t["median"],
                "reference_ms_min": ref_t["min"],
                "reference_ms_median": ref_t["median"],
            })
        except Exception as e:
            timing["note"] = f"timing raised: {e}"

    write_result(output_dir, {
        "assignment": assignment_name,
        "correctness": correctness,
        "timing": timing,
        "environment": build_environment_dict(),
    })

    if correctness.get("passed"):
        print(f"PASS  max_abs_diff={correctness['max_abs_diff']:.3e}  student_median_ms={timing.get('student_ms_median', float('nan')):.3f}")
        return 0
    print(f"FAIL  {correctness.get('notes', '')}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
