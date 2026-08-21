# Worked example: `scale_by_two` — your first NKI kernel

A complete, runnable "hello, Trainium" example. Run it first to see the whole
flow end to end — submit a job, watch it schedule onto a Trainium node, and read
a pass/fail plus a latency number — **before** you tackle the graded
`scale_by_two` assignment (which hands you a stub to fill in instead of a
finished kernel).

## What it does

The kernel takes a `(512, 512)` float32 matrix and returns `x * 2.0`,
elementwise, computed on one NeuronCore. That is deliberately trivial arithmetic
so the interesting part is the **data-movement pattern**, not the math:

```
HBM --load--> SBUF  ->  compute (* 2.0)  ->  SBUF --store--> HBM
```

- **HBM** is the NeuronCore's large off-chip memory, where your input and output
  tensors live.
- **SBUF** is the small, fast on-chip memory you have to stage data into before
  the engines can compute on it.
- You explicitly `nl.load` a tile from HBM into SBUF, compute, then `nl.store`
  the result back to HBM. NKI does not hide this movement — making it visible is
  the point of the exercise.

### The 128-partition tiling lesson

SBUF has a hard hardware limit: **128 partitions**. The leading (partition)
dimension of any tile you load can be at most 128. Our matrix has 512 rows, so
we cannot load it in one shot — we walk the row dimension `M` in chunks of 128:

```python
for i in nl.affine_range((M + 127) // 128):
    rows = i * 128 + nl.arange(128)[:, None]   # this tile's 128 row indices
    mask = rows < M                            # True only for valid rows
    tile = nl.load(x_hbm[rows, :], mask=mask)  # <=128 rows into SBUF
    nl.store(out_hbm[rows, :], tile * 2.0, mask=mask)
```

For 512 rows this is exactly 4 full tiles. The **`mask`** matters the moment `M`
is not a multiple of 128: on the last tile some of the 128 computed row indices
run past the real end of the tensor, and the mask stops `load`/`store` from
touching those out-of-range rows. This tile-and-mask pattern is the foundation
every larger NKI kernel builds on, so it is worth understanding here where the
arithmetic is a distraction-free `* 2.0`.

## Files

| File | Purpose |
|------|---------|
| `kernel.py`       | The worked NKI kernel (`scale_by_two`), heavily commented. |
| `run_example.py`  | Standalone runner: builds an input, runs on device, checks correctness, prints p99 latency. |
| `run.sh`          | The sbatch job you submit from the login node. |
| `README.md`       | This file. |

## How to run it (student workflow)

1. **SSH to the PCS login node** (the host your instructor gave you; PCS has no
   head node, so the login node is where you submit from):

   ```
   ssh <you>@<login-node>
   ```

2. **Go to this example** (copy it into your own space first if you want to
   edit it):

   ```
   cd pcs/examples/scale_by_two
   ```

3. **Submit the job:**

   ```
   sbatch run.sh
   ```

   `run.sh` selects a Trainium node with `--constraint=neuron` (on PCS you
   select whole nodes by feature — there is no per-core `--gres=neuroncore:N`;
   see [`../../docs/design.md`](../../docs/design.md) Phase 2), activates the
   shared Neuron venv, and runs `run_example.py`.

4. **Watch it schedule and run:**

   ```
   squeue --me
   ```

   The job is `scale-by-two`. It stays queued until a Trainium node is free,
   then runs (usually seconds).

5. **Read the output.** `run.sh` writes `scale-by-two-<jobid>.out` in the
   directory you submitted from. You should see:

   ```
   Correctness passed? True
   p99 latency: <some number> us
   ```

   `Correctness passed? True` means the on-device result matched the numpy
   reference `x * 2.0`. The p99 latency (in microseconds) is informational —
   it is the slowest 1% of benchmarked device invocations.

## Concepts, briefly

- **HBM vs SBUF** — HBM is the large off-chip store your tensors live in; SBUF
  is the small fast on-chip memory the engines compute from. You move data
  between them explicitly with `nl.load` / `nl.store`.
- **The 128-partition limit** — a tile's leading dimension is capped at 128
  partitions, so you tile larger dimensions into 128-row chunks.
- **Masking the last tile** — when a dimension is not a multiple of 128, the
  final tile is partial; a `mask` keeps `load`/`store` from reading or writing
  past the real end of the tensor.

## Requirements / validation status

Be aware of what has and has not been proven for this example:

- The kernel is written to the **exact NKI API surface that was confirmed to
  compile and execute on a live PCS `trn2` node this session** — `@nki.jit`,
  `nl.load` / `nl.store` / `nl.affine_range` / `nl.arange`, driven through
  `nki.baremetal` / `nki.benchmark`. Nothing here uses invented APIs.
- **A correct numeric result requires the compute node to run the validated
  Neuron SDK image** — the Neuron DLAMI venv at `/opt/aws_neuronx_venv_pytorch`,
  which includes `torch-neuronx` plus a matched runtime and `neuronx-cc`. On a
  from-scratch/partial Neuron install (no `torch-neuronx`), the same kernel
  **compiled and ran but returned all-zero output** — so it would print
  `Correctness passed? False` even though the code is correct. If you see
  all-zeros, suspect the node's Neuron environment, not the kernel. See
  [`../../docs/design.md`](../../docs/design.md) "Live validation" for the full
  write-up.

`run_example.py` does not import `torch`; it uses numpy for the reference and
runs the kernel via `nki.baremetal`. The venv still needs to be the full,
matched Neuron install for the device result to be correct.
