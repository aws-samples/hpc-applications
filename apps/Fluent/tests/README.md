# Fluent shell tests

Run everything:

```bash
apps/Fluent/tests/run-tests.sh
```

No Slurm, no EC2, no Fluent licence, no MPI, no AWS credentials and no network
access are required. The transcripts in `fixtures/` are synthetic, and so is
every value in them.

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

## Adding a case

Drop a transcript in `fixtures/` and add a `run_2026r1` call and its
assertions to a `test-*.sh`. `run-tests.sh` picks up any `test-*.sh`, and also
runs `bash -n` over the Fluent scripts, the recorder and the tests.
