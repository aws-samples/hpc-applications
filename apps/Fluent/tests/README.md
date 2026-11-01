# Fluent shell tests

Run everything:

```bash
apps/Fluent/tests/run-tests.sh
```

No Slurm, no EC2, no Fluent licence, no MPI, no AWS credentials and no network
access are required. The transcripts and the output file in `fixtures/` are
synthetic, and so is every value in them.

## What is covered

The `test-2026r1-*.sh` files run **`x86/Fluent-Benchmark.2026R1.sbatch`
itself**, so that the assembled script really executes. `helpers-2026r1.sh`
runs it in an empty environment whose `PATH` starts with stubs of `curl`,
`lscpu`, `scontrol`, `srun`, `module`, `mpirun`, `sudo` and `aws`, and with a
stub in place of Fluent's bundled Python, which the script starts with the 2026
R1 harness. The stubs touch nothing on the host: the cache drop and the THP
setting that the script starts through `srun` are not run, and the `aws` stub
refuses every call. The Python stub records the harness's command line and
writes a fixture where the 2026 R1 harness writes its transcript of the case,
`working/<tag>/transcript/<case>-<cores>.trn`. The recorder is a stub that logs
how the script called it, or this directory's recorder in `--dry-run`, which
prints the item it would store and writes nothing.

Each test file starts with a list of what it checks.
`FLUENT_2026R1_SBATCH=/path/to/a/copy` runs the tests on another copy of the
script.

The `test-launchers-*.sh` files run **the other launch scripts themselves**:
the classic benchmark scripts (`x86/Fluent-Benchmark.IMPI.sbatch`,
`x86/Fluent-Benchmark.OMPI.sbatch`, `Arm/Fluent-benchmark.sbatch`), the GPU
benchmark script (`gpu/Fluent-Benchmark-GPU.sbatch`) and the journal scripts
(`x86/Fluent.IMPI.sbatch`, `x86/Fluent.OMPI.sbatch`, `Arm/Fluent.sbatch`,
`gpu/Fluent-GPU.sbatch`, `gpu/Fluent-GPU.OMPI.sbatch`). `helpers-launchers.sh`
adds to the stubs above an `aws` that serves the case's archive from a local
directory and refuses every other call, and stubs of `fluentbench.pl`, of
Fluent and of the 2026 R1 harness, in one install tree. The `fluentbench.pl`
stub writes a fixture where `fluentbench.pl` writes its output of the case and
core count, `<case>-<cores>.out`: `fixtures/fluentbench-rated.out` has the
fields that this repository's parsers read from that file, with synthetic
values. A test can also have it write a session transcript where Fluent writes
its own, `fluent-<date>-<pid>.trn`. The Arm scripts name their install as
`/fsx/ansys_inc`, so they run from a copy that names the stub tree instead and
differs from the script in that line alone.

The `test-recorder-*.sh` files run **the recorder itself**,
`dynamodb/record-benchmark.sh`, in `--dry-run`, with the transcripts and output
files that a test puts in a run directory, and through the 2026 R1 launch
scripts. `helpers-recorder.sh` adds the functions they share to those of
`helpers-launchers.sh`. `fixtures/steady-cell-count.trn` is a transcript of
`sedan_4m` whose mesh's cell count differs from the size in the case's name.

## Adding a case

Drop a transcript in `fixtures/` and add a `run_2026r1` call (for the other
scripts, a `run_launcher` call) and its assertions to a `test-*.sh`.
`run-tests.sh` picks up any `test-*.sh`, and also runs `bash -n` over the
Fluent scripts, the recorder and the tests.
