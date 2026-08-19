"""
Input generator for the `scale_by_two` example assignment.

The harness calls make_inputs() once and passes the returned (args, kwargs)
to BOTH the reference and student kernels. Same seed each time so the
comparison is deterministic and grading is reproducible.
"""

import torch


SEED = 20260814


def make_inputs() -> tuple[tuple, dict]:
    torch.manual_seed(SEED)
    x = torch.randn(512, 512, dtype=torch.float32)
    return (x,), {}
