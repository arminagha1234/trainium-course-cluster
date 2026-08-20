"""
Self-contained runner for the worked `scale_by_two` NKI example.

It builds a random matrix, runs the kernel (see kernel.py) on a NeuronCore,
checks the device result against a plain-numpy reference, and reports a p99
latency. This is what the sbatch job (run.sh) invokes; you can also run it
directly on a compute node inside the shared Neuron venv:

    source /opt/aws_neuronx_venv_pytorch/bin/activate
    python run_example.py

It is intentionally standalone — it does NOT use the grading harness under
`../../../harness/`. The point is to show the whole flow in one readable file
before you meet the graded assignment.
"""
import numpy as np
import neuronxcc.nki as nki

from kernel import scale_by_two

# Seeded so every run compares against the same input — the output and the
# latency are then reproducible across submissions.
SEED = 20260814


def main() -> None:
    np.random.seed(SEED)
    x = np.random.rand(512, 512).astype(np.float32)

    # --- Run on the NeuronCore -------------------------------------------
    # nki.baremetal compiles the @nki.jit kernel with neuronx-cc and executes
    # it on the device, returning the result as a host array.
    out = np.asarray(nki.baremetal(scale_by_two)(x))

    # --- Correctness ------------------------------------------------------
    # Multiplying by 2.0 is exact in float32, so the device output should match
    # the numpy reference to within a tight tolerance.
    expected = x * 2.0
    passed = bool(np.allclose(out, expected, rtol=1e-4, atol=1e-6))
    print(f"Correctness passed? {passed}")
    assert passed, (
        "device output did not match x * 2.0 within tolerance. "
        "A common cause is running on an incomplete Neuron install "
        "(see README 'Requirements / validation status')."
    )

    # --- Latency ----------------------------------------------------------
    # nki.benchmark re-runs the kernel and records per-invocation device
    # latency. It is wrapped in try/except so a benchmark-API hiccup cannot fail
    # the correctness demo above — the timing here is informational.
    try:
        bench = nki.benchmark(scale_by_two, warmup=1, iters=10)
        bench(x)
        p99_us = bench.benchmark_result.nc_latency.get_latency_percentile(99)
        print(f"p99 latency: {p99_us} us")
    except Exception as exc:  # benchmarking is best-effort; keep the demo green
        print(f"Benchmarking unavailable ({exc}); the correctness result above still stands.")


if __name__ == "__main__":
    main()
