# Example Assignment: `scale_by_two`

A minimal reference implementation of the assignment contract the harness
expects. TAs copy this whole directory into `/shared/assignments/<name>/` as
a starting point.

Task (student-facing):

> Given a tensor `x` of shape `(M, N)` and dtype `float32`, return `x * 2.0`.
> The reference implementation uses `torch.mul`. Your job is to implement the
> same operation as an NKI kernel in `student.py`.

## Files

| File | Owner | Purpose |
|------|-------|---------|
| `README.md`        | TA      | Assignment description (this file) |
| `reference.py`     | TA      | The "correct" implementation. Not shown to students. |
| `student.py`       | Student | Where they write their NKI kernel. |
| `inputs.py`        | TA      | Generates the test input tensors. |
| `tolerance.json`   | TA      | Optional tolerance override; defaults to rtol=1e-3, atol=1e-5. |

## Contract

Both `reference.py` and `student.py` MUST expose a callable named `kernel`:

```python
def kernel(x: torch.Tensor) -> torch.Tensor:
    ...
```

The signature of `kernel` is whatever `inputs.py` returns. In this example:

```python
# inputs.py
def make_inputs() -> tuple[tuple, dict]:
    return (torch.randn(512, 512, dtype=torch.float32),), {}
```

## Running

From a compute node (via `sbatch $HOME/run.sh` on the head node) or from the
head node directly for a fast smoke test:

```
python3 ~/harness/test_kernel.py \
  --assignment-dir /shared/assignments/scale_by_two \
  --output-dir /tmp/out
cat /tmp/out/result.json
```

Expected:
```
"passed": true,
"max_abs_diff": ~0.0,
"student_ms_median": ...
```

## Grading

`result.json` has `correctness.passed` as the boolean grade signal. Timing is
informational for V0. In future assignments the timing may factor into a
performance bonus.
