"""
Student stub for the `scale_by_two` example assignment.

TASK
----
Given `x` of shape (M, N), return `x * 2.0`.

Replace the placeholder body with an NKI kernel that runs on the NeuronCore.
Rough shape (adapt to your assignment's API surface):

    import torch
    from neuronxcc import nki
    from neuronxcc.nki import language as nl

    @nki.jit
    def _scale_by_two_kernel(x_hbm):
        # Load a tile into SBUF, multiply by 2, store back.
        M, N = x_hbm.shape
        out_hbm = nl.ndarray((M, N), dtype=x_hbm.dtype, buffer=nl.hbm)
        for i in nl.affine_range((M + 127) // 128):
            r = nl.arange(128)[:, None] + i * 128
            tile = nl.load(x_hbm[r, :], mask=r < M)
            nl.store(out_hbm[r, :], tile * 2.0, mask=r < M)
        return out_hbm

    def kernel(x: torch.Tensor) -> torch.Tensor:
        return _scale_by_two_kernel(x)

The placeholder below returns zeros so the harness always reports a clean
FAIL until you replace it. That's your signal you have not started yet.
"""

import torch


def kernel(x: torch.Tensor) -> torch.Tensor:
    # TODO: replace with your NKI implementation.
    return torch.zeros_like(x)
