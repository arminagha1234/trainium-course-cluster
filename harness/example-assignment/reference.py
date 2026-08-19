"""
Reference implementation for the `scale_by_two` example assignment.

TA-facing. Not distributed to students. Runs on the CPU with plain torch; the
harness compares the student's NKI kernel output to this ground truth.
"""

import torch


def kernel(x: torch.Tensor) -> torch.Tensor:
    """Return x * 2.0, elementwise."""
    return torch.mul(x, 2.0)
