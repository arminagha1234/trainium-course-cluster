"""
Worked NKI example — scale a matrix by 2.0, elementwise, on one NeuronCore.

A complete "hello, Trainium" reference to hand to students BEFORE the graded
assignment. It shows the core NKI data-movement loop:

    HBM --load--> SBUF  ->  compute  ->  SBUF --store--> HBM

Key hardware lesson: a NeuronCore's SBUF (on-chip memory) has a hard limit of
128 partitions, so a tensor's leading (partition) dimension can be at most 128
per tile. We therefore tile the row dimension M into chunks of 128 and use a
mask so the final partial tile writes only valid rows. This is the same tiling
pattern every larger NKI kernel builds on.
"""
import neuronxcc.nki as nki
import neuronxcc.nki.language as nl

PARTITION_LIMIT = 128  # SBUF partition-dimension hardware limit on a NeuronCore


@nki.jit
def scale_by_two(x_hbm):
    """Return x_hbm * 2.0, elementwise. x_hbm is an (M, N) tensor in HBM."""
    M, N = x_hbm.shape
    out_hbm = nl.ndarray((M, N), dtype=x_hbm.dtype, buffer=nl.hbm)
    # Walk the M dimension 128 partitions at a time.
    for i in nl.affine_range((M + PARTITION_LIMIT - 1) // PARTITION_LIMIT):
        rows = i * PARTITION_LIMIT + nl.arange(PARTITION_LIMIT)[:, None]  # (128, 1)
        mask = rows < M                       # guards the last partial tile
        tile = nl.load(x_hbm[rows, :], mask=mask)   # (<=128, N) into SBUF
        nl.store(out_hbm[rows, :], tile * 2.0, mask=mask)  # compute + write back
    return out_hbm
