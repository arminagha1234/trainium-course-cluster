"""
Shared helper for writing result.json in a stable schema.

Every kernel job produces a result.json in its output directory. The
schema below is intentionally small so grading tools can consume it
directly. Additional fields are allowed but must not remove existing keys.

Schema (v1):
{
  "schema_version": 1,
  "job_id": "<slurm job id, or 'local' when run outside slurm>",
  "assignment": "<basename of assignment dir>",
  "timestamp_utc": "<iso 8601>",
  "correctness": {
      "passed": true | false,
      "tolerance": {"rtol": 1e-3, "atol": 1e-5},
      "max_abs_diff": <float>,
      "max_rel_diff": <float>,
      "shape_match": true | false,
      "dtype_match": true | false,
      "notes": "<string>"
  },
  "timing": {
      "student_ms_median": <float>,
      "student_ms_min": <float>,
      "reference_ms_median": <float>,
      "reference_ms_min": <float>,
      "warmup_runs": <int>,
      "measured_runs": <int>
  },
  "environment": {
      "hostname": "<string>",
      "user": "<string>",
      "python": "<python -V>",
      "neuron_visible_cores": "<value of NEURON_RT_VISIBLE_CORES or ''>",
      "neuron_ls": "<first line of neuron-ls, or ''>"
  }
}
"""

from __future__ import annotations

import json
import os
import platform
import socket
import subprocess
import time
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1


def _get_neuron_ls_summary() -> str:
    try:
        proc = subprocess.run(
            ["neuron-ls"], capture_output=True, text=True, timeout=10, check=False
        )
        first = (proc.stdout.strip().splitlines() or [""])[0]
        return first
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""


def build_environment_dict() -> dict[str, str]:
    return {
        "hostname": socket.gethostname(),
        "user": os.environ.get("USER", ""),
        "python": platform.python_version(),
        "neuron_visible_cores": os.environ.get("NEURON_RT_VISIBLE_CORES", ""),
        "neuron_ls": _get_neuron_ls_summary(),
    }


def write_result(output_dir: str | os.PathLike, result: dict[str, Any]) -> Path:
    """Write result.json (schema v1) into output_dir. Fills any missing
    top-level fields with sensible defaults.
    """
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    payload: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "job_id": os.environ.get("SLURM_JOB_ID", "local"),
        "assignment": result.get("assignment", ""),
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "correctness": result.get("correctness", {}),
        "timing": result.get("timing", {}),
        "environment": result.get("environment") or build_environment_dict(),
    }
    # Allow arbitrary extras (grading tools can look at these).
    for k, v in result.items():
        if k not in payload:
            payload[k] = v
    path = out / "result.json"
    path.write_text(json.dumps(payload, indent=2, default=str))
    return path
