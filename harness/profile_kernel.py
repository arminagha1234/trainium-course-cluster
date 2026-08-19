#!/usr/bin/env python3
"""
Profile capture wrapper for a Trainium Course Cluster kernel assignment.

Runs the student kernel once under `neuron-profile capture` and copies the
resulting NEFF + NTFF pair into the job's profile directory. Students can
later inspect with `neuron-profile view --neff <path> --ntff <path>`.

Contract:
  assignment_dir/     same as test_kernel.py (student.py + inputs.py)
  profile_dir/        output directory; will contain <name>.neff, <name>.ntff,
                      and a small metadata.json.

Exit codes:
  0  profile captured
  2  fatal (missing tool, kernel error)

This wrapper deliberately keeps profiling off the correctness path — a
kernel that fails correctness is not profile-worthy.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


def _has(cmd: str) -> bool:
    return shutil.which(cmd) is not None


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {name} from {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--assignment-dir", required=True)
    ap.add_argument("--profile-dir", required=True)
    ap.add_argument("--session-name", default=None, help="Neuron profile session name (default: <assignment>-<pid>)")
    args = ap.parse_args()

    assignment_dir = Path(args.assignment_dir).resolve()
    profile_dir = Path(args.profile_dir).resolve()
    profile_dir.mkdir(parents=True, exist_ok=True)

    if not _has("neuron-profile"):
        print("neuron-profile not on PATH; skipping capture", file=sys.stderr)
        return 2

    session_name = args.session_name or f"{assignment_dir.name}-{os.getpid()}"

    # NEURON_PROFILE causes the runtime to emit trace files during kernel
    # execution. NEURON_FRAMEWORK_DEBUG helps if compilation is opaque.
    trace_root = profile_dir / "raw"
    trace_root.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["NEURON_PROFILE"] = str(trace_root)
    env["NEURON_RT_INSPECT_ENABLE"] = "1"

    # Import student + inputs modules
    try:
        stu = _load_module("student_mod", assignment_dir / "student.py")
    except Exception as e:  # noqa: BLE001
        print(f"cannot load student.py: {e}", file=sys.stderr)
        return 2

    if (assignment_dir / "inputs.py").exists():
        inp = _load_module("inputs_mod", assignment_dir / "inputs.py")
        _args, _kwargs = inp.make_inputs()
    else:
        # Match the default in test_kernel.py so students see identical shapes
        import torch  # noqa: E402
        _args = (torch.ones(128, 128, dtype=torch.float32),)
        _kwargs = {}

    # Rerun under the trace-capturing env
    os.environ.update({"NEURON_PROFILE": str(trace_root), "NEURON_RT_INSPECT_ENABLE": "1"})
    t0 = time.perf_counter()
    try:
        stu.kernel(*_args, **_kwargs)
    except Exception as e:  # noqa: BLE001
        print(f"student.kernel raised during profiling: {e}", file=sys.stderr)
        return 2
    t1 = time.perf_counter()

    # Collect the NEFF+NTFF pair(s) the runtime just wrote into trace_root.
    # neuron-profile capture usually deposits files under a run-id
    # subdirectory; we grab everything and re-package.
    collected = list(trace_root.rglob("*.neff")) + list(trace_root.rglob("*.ntff"))
    if not collected:
        # Fallback: try to explicitly capture via neuron-profile capture. This
        # path is stack-version-dependent, so we invoke it and don't require
        # success. See docs/open-questions-answered.md for context.
        proc = subprocess.run(
            ["neuron-profile", "capture", "--session-name", session_name, "--output-dir", str(trace_root)],
            capture_output=True, text=True, check=False,
        )
        print(proc.stdout, proc.stderr, file=sys.stderr)
        collected = list(trace_root.rglob("*.neff")) + list(trace_root.rglob("*.ntff"))

    metadata = {
        "assignment": assignment_dir.name,
        "session_name": session_name,
        "wall_seconds": t1 - t0,
        "files": [str(p.relative_to(profile_dir)) for p in collected],
        "hint": "View with: neuron-profile view --neff <neff> --ntff <ntff>",
    }
    (profile_dir / "metadata.json").write_text(json.dumps(metadata, indent=2))

    if not collected:
        print("WARN: no NEFF/NTFF files were captured. Check NEURON_PROFILE + neuron-profile version.", file=sys.stderr)
    else:
        print(f"captured {len(collected)} profile artifact(s) under {profile_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
